import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
const scalar = (n) => Number.isFinite(n) && n >= 0;
const count = (n) => Number.isSafeInteger(n) && n >= 0;
const packetBits = (1316 + 44) * 8;
/** Laboratory admission only. Neither this result nor an SRT gauge is usable video capacity. */
export class CapacityProbePolicy {
  #settings;
  #lastNow;
  #lastSender;
  #lastReceiver;
  #anchor;
  #terminal;
  #command;
  #stageStartedAt;
  get command() {
    return this.#command;
  }
  get stageStartedAt() {
    return this.#stageStartedAt;
  }
  constructor({
    baselineBps,
    targetBps,
    stepBps,
    startedAt,
    initialStage = 1,
    baselineTransport = { retransmittedBytes: 0, droppedPackets: 0 },
    baselineReceiver = { totalMissing: 0, totalDuplicates: 0 },
  }) {
    assert([baselineBps, targetBps, stepBps, initialStage].every(count));
    assert(baselineBps > 0 && targetBps > baselineBps && targetBps <= 12_000_000);
    assert(
      stepBps > 0 &&
        stepBps <= baselineBps / 10 &&
        Math.ceil((targetBps - baselineBps) / stepBps) <= 32,
    );
    assert(initialStage >= 1 && initialStage + Math.ceil((targetBps - baselineBps) / stepBps) < 64);
    assert(
      scalar(startedAt) &&
        count(baselineTransport.retransmittedBytes) &&
        count(baselineTransport.droppedPackets),
    );
    assert(count(baselineReceiver.totalMissing) && count(baselineReceiver.totalDuplicates));
    this.#settings = {
      baselineBps,
      targetBps,
      stepBps,
      startedAt,
      baselineTransport: { ...baselineTransport },
      baselineReceiver: { ...baselineReceiver },
    };
    this.#command = Object.freeze({
      stage: initialStage,
      baseBps: baselineBps,
      probeBps: Math.min(stepBps, targetBps - baselineBps),
    });
    this.#stageStartedAt = this.#lastNow = startedAt;
  }
  #finish(kind, reason, now, proof) {
    this.#terminal = {
      kind,
      reason,
      at: now,
      command: { stage: this.#command.stage + 1, baseBps: this.#settings.baselineBps, probeBps: 0 },
      ...proof,
    };
    return this.#terminal;
  }
  cancel(now) {
    return this.#terminal ?? this.#finish('cancelled', 'cancelled', now);
  }
  observe({ now, sender, receiver }) {
    if (this.#terminal) return this.#terminal;
    const refuse = (reason) => this.#finish('refused', reason, now);
    if (!scalar(now) || now < this.#lastNow) return refuse('invalid-feedback');
    this.#lastNow = now;
    if (now - this.#settings.startedAt > 60) return refuse('time-budget');
    if (!sender || !receiver)
      return now - this.#stageStartedAt > 2 ? refuse('missing-feedback') : null;
    if (
      ![sender.at, receiver.at, sender.rttMs, sender.bufferMs].every(scalar) ||
      ![
        sender.stage,
        receiver.stage,
        sender.retransmittedBytes,
        sender.droppedPackets,
        sender.probePayloadBytes,
        receiver.basePackets,
        receiver.probePackets,
        receiver.missing,
        receiver.duplicates,
        receiver.totalMissing,
        receiver.totalDuplicates,
      ].every(count) ||
      sender.at > now ||
      receiver.at > now ||
      sender.stage > this.#command.stage ||
      receiver.stage > this.#command.stage
    )
      return refuse('invalid-feedback');
    if (
      ['probeLeaseExpired', 'probeBudgetExhausted'].some(
        (k) => sender[k] !== undefined && typeof sender[k] !== 'boolean',
      )
    )
      return refuse('invalid-feedback');
    if (now - sender.at > 0.3 || now - receiver.at > 0.3) return refuse('stale-feedback');
    for (const [next, previous, keys] of [
      [sender, this.#lastSender, ['retransmittedBytes', 'droppedPackets', 'probePayloadBytes']],
      [
        receiver,
        this.#lastReceiver,
        ['basePackets', 'probePackets', 'missing', 'duplicates', 'totalMissing', 'totalDuplicates'],
      ],
    ]) {
      if (previous && next.at - previous.at > 0.3) return refuse('feedback-gap');
      if (
        previous &&
        (next.at < previous.at ||
          next.stage < previous.stage ||
          (next.at === previous.at && !isDeepStrictEqual(next, previous)) ||
          keys.some(
            (k) =>
              (next === sender || k.startsWith('total') || next.stage === previous.stage) &&
              next[k] < previous[k],
          ))
      )
        return refuse('invalid-feedback');
    }
    this.#lastSender = { ...sender };
    this.#lastReceiver = { ...receiver };
    if (
      sender.retransmittedBytes < this.#settings.baselineTransport.retransmittedBytes ||
      sender.droppedPackets < this.#settings.baselineTransport.droppedPackets
    )
      return refuse('invalid-feedback');
    if (sender.stage === this.#command.stage && sender.probeLeaseExpired === true)
      return refuse('probe-lease-expired');
    if (sender.probeBudgetExhausted === true || sender.probePayloadBytes >= 16 * 1024 * 1024)
      return refuse('byte-budget');
    if (
      sender.rttMs > 50 ||
      sender.bufferMs > 50 ||
      sender.retransmittedBytes > this.#settings.baselineTransport.retransmittedBytes ||
      sender.droppedPackets > this.#settings.baselineTransport.droppedPackets
    )
      return refuse('transport-pressure');
    if (
      receiver.totalMissing < this.#settings.baselineReceiver.totalMissing ||
      receiver.totalDuplicates < this.#settings.baselineReceiver.totalDuplicates ||
      receiver.missing > receiver.totalMissing ||
      receiver.duplicates > receiver.totalDuplicates
    )
      return refuse('invalid-feedback');
    if (
      receiver.totalMissing > this.#settings.baselineReceiver.totalMissing ||
      receiver.totalDuplicates > this.#settings.baselineReceiver.totalDuplicates
    )
      return refuse('receiver-discontinuity');
    const stageAge = now - this.#stageStartedAt;
    if (stageAge > 4) return refuse('delivery-shortfall');
    if (
      sender.stage !== this.#command.stage ||
      receiver.stage !== this.#command.stage ||
      stageAge < 0.5
    )
      return null;
    this.#anchor ??= { ...receiver };
    const duration = receiver.at - this.#anchor.at;
    if (duration < 1.5) return null;
    const baseBps = ((receiver.basePackets - this.#anchor.basePackets) * packetBits) / duration;
    const probeBps = ((receiver.probePackets - this.#anchor.probePackets) * packetBits) / duration;
    const offeredAccountedBps = this.#command.baseBps + this.#command.probeBps;
    if (
      baseBps < this.#command.baseBps * 0.97 ||
      probeBps < this.#command.probeBps * 0.97 ||
      baseBps + probeBps < offeredAccountedBps * 0.97
    )
      return null;
    const proof = {
      receiverStart: { ...this.#anchor },
      receiverEnd: { ...receiver },
      offeredAccountedBps,
      deliveredBaseBps: baseBps,
      deliveredProbeBps: probeBps,
      receiverCoverageSeconds: duration,
    };
    if (offeredAccountedBps >= this.#settings.targetBps)
      return this.#finish('qualified', 'delivered-load', now, proof);
    this.#command = Object.freeze({
      stage: this.#command.stage + 1,
      baseBps: this.#command.baseBps,
      probeBps: Math.min(
        this.#command.probeBps + this.#settings.stepBps,
        this.#settings.targetBps - this.#command.baseBps,
      ),
    });
    this.#stageStartedAt = now;
    this.#anchor = null;
    return { kind: 'set', at: now, command: { ...this.#command }, ...proof };
  }
}
