import assert from 'node:assert/strict';
import { indexOwnedMeasurementHistory } from './owned-measurement-history.mjs';
import { assertRecoveryProbeHistory } from './recovery-probe-observation.mjs';

const rates = [500000, 2000000, 12000000];
const reasons = new Set([
  'leaseExpired',
  'timeLimit',
  'byteLimit',
  'invalidClock',
  'unavailableStatistics',
  'transportPressure',
  'transportBackpressure',
  'transportFailed',
  'cancelled',
  'finished',
  'closed',
  'replaced',
]);
const check = (value, message) => assert.ok(value, `Owned native probes: ${message}`);
const time = (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 1e12;
const uuid = (v) =>
  typeof v === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(v);
function uint(v, max = 18446744073709551615n) {
  check(typeof v === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(v), 'noncanonical counter');
  const n = BigInt(v);
  check(n <= max, 'counter exceeds bound');
  return n;
}
function bytes(v) {
  const n = uint(v, 16777216n);
  check(n % 1316n === 0n, 'unaligned native payload');
  return n;
}

/** Replay actual returned native stages, including failed and late allocations.
 * The complete raw audit is indexed once; no campaign is sliced into a legacy
 * envelope. This proves native acceptance/retirement consistency only. Receiver
 * capacity, candidate cost, application and observed-health retry policy still
 * require independent whole-history joins by the complete route verifier.
 */
export function qualifyOwnedNativeProbes(raw, options = {}) {
  check(options && typeof options === 'object' && !Array.isArray(options), 'invalid options');
  check(
    Reflect.ownKeys(options).every((key) =>
      ['scope', 'publishingGeneration', 'timingProfile'].includes(key),
    ),
    'unknown option',
  );
  const { scope, publishingGeneration, timingProfile } = options;
  check(uint(publishingGeneration) > 0n, 'invalid native generation');
  const history = indexOwnedMeasurementHistory(raw, { scope, timingProfile }),
    attempts = [],
    identities = new Set(),
    observations = [];
  let lastTerminal = null,
    previousCampaign = 0n;
  for (const indexed of history.attempts) {
    const registration = raw.events[indexed.registeredEventIndex],
      receipt = registration.receipt;
    check(registration.policy === 'recovery-budget-v1', 'requires explicit recovery policy');
    check(
      registration.baselineProfile === '240p30' &&
        registration.baselineBitRate === 350000 &&
        registration.targetProfile === '360p30' &&
        registration.targetBitRate === 600000,
      'unexpected measured profile pair',
    );
    check(
      receipt?.publishingGeneration === publishingGeneration &&
        receipt.bitRate === 350000 &&
        uuid(receipt.configurationID) &&
        uuid(receipt.encoderSessionID),
      'invalid registered native receipt',
    );
    check(
      [
        receipt.acceptedAt,
        registration.healthySince,
        registration.healthyThrough,
        registration.readinessValidUntil,
      ].every(time) &&
        receipt.acceptedAt <= registration.coreRegisteredAt &&
        registration.healthySince < registration.healthyThrough &&
        registration.healthyThrough <= registration.coreRegisteredAt &&
        registration.coreRegisteredAt <= registration.readinessValidUntil,
      'invalid registration readiness chronology',
    );
    check(uint(registration.healthSequence) > 0n, 'invalid health watermark');
    const stages = [];
    let requestedContext = false,
      capturedContext = false,
      allocation,
      current,
      retirementRequested = false,
      binding;
    let campaign, origin, renewal;
    for (const eventIndex of indexed.eventIndices) {
      const event = raw.events[eventIndex];
      if (event.kind === 'contextRequested') {
        check(!requestedContext, 'duplicate context request');
        requestedContext = true;
      } else if (event.kind === 'contextCaptured') {
        check(requestedContext && !capturedContext, 'invalid context capture');
        assert.deepEqual(event.scope, scope, 'Owned native probes: captured foreign publication');
        assert.deepEqual(
          event.receipt,
          receipt,
          'Owned native probes: captured foreign configuration',
        );
        check(
          event.publishingGeneration === publishingGeneration,
          'captured foreign native generation',
        );
        capturedContext = true;
      } else if (event.kind === 'allocationRequested') {
        check(
          capturedContext && !binding && (!current || current.terminal) && !allocation && !renewal,
          'allocation crosses active ownership',
        );
        const expectedKind = stages.length ? 'replace' : lastTerminal ? 'restart' : 'begin';
        check(event.kindOfAllocation === expectedKind, 'wrong continuation kind');
        assert.deepEqual(
          event.predecessor,
          lastTerminal,
          'Owned native probes: foreign/missing predecessor',
        );
        check(
          stages.length < 3 && event.bitRate === rates[stages.length],
          'unexpected stage target',
        );
        allocation = {
          at: event.at,
          rate: event.bitRate,
          stage: stages.length + 1,
          cumulative: stages.length ? bytes(lastTerminal.totalAcceptedPayloadBytes) : 0n,
          eventIndex,
        };
        current = undefined;
        retirementRequested = false;
      } else if (event.kind === 'renewalRequested') {
        check(
          current && !current.terminal && !allocation && !renewal && !retirementRequested,
          'renewal outside live native stage',
        );
        assert.deepEqual(
          event.snapshot,
          current.sample,
          'Owned native probes: renewal selected a foreign snapshot',
        );
        renewal = { at: event.at, rejected: false };
      } else if (event.kind === 'renewalRejected') {
        check(
          renewal &&
            !renewal.rejected &&
            typeof event.reason === 'string' &&
            event.reason.length > 0,
          'renewal rejection without pending native call',
        );
        renewal.rejected = true;
        renewal.completedAt = event.at;
      } else if (event.kind === 'retirementRequested') {
        check(allocation || current, 'retirement without native operation');
        check(!retirementRequested, 'overlapping retirement request');
        if (event.snapshot != null && current) {
          check(
            uuid(event.snapshot.id) && event.snapshot.id.toLowerCase() === current.id,
            'retirement selected a foreign stage',
          );
          check(
            event.snapshot.publishingGeneration === publishingGeneration,
            'retirement selected a foreign generation',
          );
        }
        retirementRequested = true;
      } else if (event.kind === 'allocationRejected') {
        check(
          allocation &&
            !current &&
            !retirementRequested &&
            typeof event.reason === 'string' &&
            event.reason.length > 0,
          'allocation rejection lacks pending handle request',
        );
        allocation = undefined;
      } else if (['allocated', 'renewed', 'retired'].includes(event.kind)) {
        const snapshot = event.snapshot;
        if (event.kind === 'renewed')
          check(renewal && !renewal.rejected, 'renewal result without native request');
        if (event.kind === 'retired')
          check(!renewal || renewal.rejected, 'retirement before renewal completed');
        if (snapshot == null) {
          check(
            event.kind === 'retired' && allocation && !current && retirementRequested,
            'missing actual native snapshot',
          );
          // An opaque operation can join before native allocation occurred. No
          // stage or native continuation is manufactured from that empty join.
          allocation = undefined;
          retirementRequested = false;
          continue;
        }
        check(
          snapshot.policy === 'recovery-budget-v1' &&
            snapshot.publishingGeneration === publishingGeneration,
          'native generation/policy mismatch',
        );
        check(
          uuid(snapshot.id) && uint(snapshot.campaign, 4294967295n) > 0n,
          'invalid native identity',
        );
        check(
          [snapshot.startedAt, snapshot.campaignStartedAt, snapshot.leaseDeadline].every(time),
          'invalid native clock',
        );
        if (!current) {
          check(
            allocation && ['allocated', 'retired'].includes(event.kind),
            'native stage without its allocation',
          );
          check(
            snapshot.stage === allocation.stage && snapshot.bitRate === allocation.rate,
            'returned stage differs from request',
          );
          check(
            snapshot.startedAt >= allocation.at && snapshot.startedAt <= event.at,
            'native allocation outside request',
          );
          check(!identities.has(snapshot.id.toLowerCase()), 'reused native stage UUID');
          identities.add(snapshot.id.toLowerCase());
          if (campaign === undefined) {
            campaign = uint(snapshot.campaign);
            origin = snapshot.campaignStartedAt;
            check(
              campaign === previousCampaign + 1n && origin === snapshot.startedAt,
              'invalid fresh campaign ordinal/origin',
            );
          }
          current = {
            id: snapshot.id.toLowerCase(),
            stage: snapshot.stage,
            bitRate: snapshot.bitRate,
            startedAt: snapshot.startedAt,
            initialCumulative: allocation.cumulative,
            accepted: 0n,
            total: allocation.cumulative,
            sample: undefined,
            observedAt: allocation.at,
            allocationEventIndex: allocation.eventIndex,
            snapshotEventIndices: [],
            checkpoints: [],
            terminal: null,
          };
          stages.push(current);
          allocation = undefined;
          check(
            Math.abs(snapshot.leaseDeadline - snapshot.startedAt - 0.3) <= 1e-6,
            'unobserved allocation cannot renew its lease',
          );
          if (event.kind === 'allocated') {
            check(
              snapshot.reason === null &&
                bytes(snapshot.acceptedPayloadBytes) === 0n &&
                Math.abs(snapshot.leaseDeadline - snapshot.startedAt - 0.3) <= 1e-6,
              'new stage must begin empty with a 300ms lease',
            );
          }
        } else {
          check(event.kind !== 'allocated', 'duplicate allocation result');
          check(
            snapshot.id.toLowerCase() === current.id &&
              snapshot.stage === current.stage &&
              snapshot.bitRate === current.bitRate &&
              snapshot.startedAt === current.startedAt,
            'current native identity changed',
          );
        }
        check(
          uint(snapshot.campaign) === campaign && snapshot.campaignStartedAt === origin,
          'campaign changed within attempt',
        );
        check(
          snapshot.startedAt >= origin &&
            snapshot.startedAt < origin + 60 &&
            snapshot.leaseDeadline > snapshot.startedAt &&
            snapshot.leaseDeadline <= origin + 60.3 + 1e-6,
          'native clock exceeds campaign/lease limits',
        );
        const accepted = bytes(snapshot.acceptedPayloadBytes),
          total = bytes(snapshot.totalAcceptedPayloadBytes);
        check(
          accepted >= current.accepted &&
            total - current.initialCumulative === accepted &&
            total >= current.total,
          'native acceptance counters are inconsistent',
        );
        check(
          (accepted === 0n) === (snapshot.lastAcceptedAt === null),
          'acceptance timestamp/count mismatch',
        );
        if (accepted > 0n) {
          check(
            time(snapshot.lastAcceptedAt) &&
              snapshot.lastAcceptedAt >= snapshot.startedAt &&
              snapshot.lastAcceptedAt <= event.at &&
              snapshot.lastAcceptedAt < snapshot.leaseDeadline &&
              snapshot.lastAcceptedAt < origin + 60,
            'acceptance outside native ownership',
          );
          check(
            Number(accepted / 1316n) * 10880 <=
              (snapshot.lastAcceptedAt - snapshot.startedAt) * snapshot.bitRate + 1,
            'native acceptance exceeds paced budget',
          );
          if (accepted > current.accepted)
            for (const checkpoint of current.checkpoints) {
              check(
                snapshot.lastAcceptedAt >= checkpoint.at &&
                  Number((accepted - checkpoint.accepted) / 1316n) * 10880 <=
                    (snapshot.lastAcceptedAt - checkpoint.at) * snapshot.bitRate + 10881,
                'acceptance exceeds one-message token budget',
              );
            }
        }
        check(snapshot.reason === null || reasons.has(snapshot.reason), 'unknown terminal reason');
        if (snapshot.reason === 'leaseExpired')
          check(event.at >= snapshot.leaseDeadline, 'premature lease expiry');
        if (snapshot.reason === 'timeLimit')
          check(event.at >= origin + 60, 'premature campaign time limit');
        if (snapshot.reason === 'byteLimit')
          check(total + 1316n > 16777216n, 'premature campaign byte limit');
        if (snapshot.reason === null)
          check(event.at < snapshot.leaseDeadline, 'active snapshot outlived its lease');
        if (event.kind === 'retired') {
          check(
            retirementRequested && snapshot.reason !== null,
            'retirement did not prove terminal native owner',
          );
          retirementRequested = false;
          current.terminal = snapshot;
          lastTerminal = snapshot;
          previousCampaign = campaign;
        } else
          check(
            snapshot.reason === null && !current.terminal,
            'active operation returned terminal ownership',
          );
        if (current.sample) {
          if (current.sample.reason !== null)
            assert.deepEqual(
              snapshot,
              current.sample,
              'Owned native probes: changed joined terminal',
            );
          check(snapshot.leaseDeadline >= current.sample.leaseDeadline, 'lease regressed');
          if (event.kind === 'renewed' || snapshot.leaseDeadline !== current.sample.leaseDeadline) {
            const renewedAt = snapshot.leaseDeadline - 0.3;
            check(
              renewal &&
                (event.kind === 'renewed' || (event.kind === 'retired' && renewal.rejected)) &&
                renewedAt >= renewal.at - 1e-6 &&
                renewedAt <= (renewal.completedAt ?? event.at) + 1e-6 &&
                renewedAt < current.sample.leaseDeadline &&
                renewedAt < origin + 60,
              'renewal revived or forged lease',
            );
          }
          check(
            snapshot.lastAcceptedAt === null ||
              snapshot.lastAcceptedAt >= (current.sample.lastAcceptedAt ?? snapshot.startedAt),
            'acceptance clock regressed',
          );
        }
        observations.push({ sample: snapshot, observedAt: event.at });
        current.snapshotEventIndices.push(eventIndex);
        current.sample = snapshot;
        current.observedAt = event.at;
        current.accepted = accepted;
        current.total = total;
        current.checkpoints.push({
          at: Math.max(snapshot.leaseDeadline - 0.3, snapshot.lastAcceptedAt ?? snapshot.startedAt),
          accepted,
        });
        if (event.kind === 'renewed' || event.kind === 'retired') renewal = undefined;
      } else if (event.kind === 'candidateBound') {
        check(
          !binding &&
            current &&
            current.stage === 3 &&
            !current.terminal &&
            !allocation &&
            !retirementRequested &&
            !renewal,
          'candidate not bound to active final stage',
        );
        assert.deepEqual(
          event.snapshot,
          current.sample,
          'Owned native probes: candidate bound foreign snapshot',
        );
        check(
          time(event.boundAt) &&
            event.boundAt >= current.observedAt &&
            event.boundAt <= event.at &&
            event.boundAt < current.sample.leaseDeadline,
          'candidate binding outlived stage',
        );
        binding = { eventIndex, probeID: current.id, boundAt: event.boundAt };
      } else if (event.kind === 'cleanupJoined') {
        check(
          !allocation &&
            !renewal &&
            !retirementRequested &&
            stages.every((stage) => stage.terminal),
          'cleanup omitted native work',
        );
      }
    }
    attempts.push({
      ...indexed,
      binding,
      campaign: campaign?.toString() ?? null,
      campaignStartedAt: origin ?? null,
      acceptedPayloadBytes: stages.length ? Number(stages.at(-1).total) : 0,
      stages: stages.map((stage) => ({
        id: stage.id,
        stage: stage.stage,
        bitRate: stage.bitRate,
        startedAt: stage.startedAt,
        acceptedPayloadBytes: Number(stage.accepted),
        totalAcceptedPayloadBytes: Number(stage.total),
        allocationEventIndex: stage.allocationEventIndex,
        snapshotEventIndices: stage.snapshotEventIndices,
        terminal: structuredClone(stage.terminal),
      })),
    });
  }
  check(observations.length > 0, 'no actual native probe observations');
  if (observations.length) {
    assertRecoveryProbeHistory(observations, { policy: 'recovery-budget-v1' });
    // Failed terminals retain the last successful preflight. Do not rewrite
    // their actual reason to fit the historical success-only acceptance helper.
    const prior = new Map();
    for (const { sample } of observations) {
      const count = bytes(sample.acceptedPayloadBytes),
        previous = prior.get(sample.id.toLowerCase());
      const raw = sample.recoveryObservation;
      if (count === 0n)
        check(raw.checkedAt === sample.startedAt, 'empty stage changed admission check');
      else
        check(
          raw.checkedAt <= sample.lastAcceptedAt &&
            Number(count / 1316n) * 10880 <=
              (raw.checkedAt - sample.startedAt) * sample.bitRate + 1,
          'acceptance lacks native preflight pacing credit',
        );
      if (previous) {
        if (count === bytes(previous.acceptedPayloadBytes)) {
          check(
            sample.lastAcceptedAt === previous.lastAcceptedAt,
            'unchanged acceptance clock changed',
          );
          assert.deepEqual(
            raw,
            previous.recoveryObservation,
            'Owned native probes: preflight changed without acceptance',
          );
        } else
          check(
            raw.checkedAt > previous.recoveryObservation.checkedAt &&
              raw.checkedAt >= (previous.lastAcceptedAt ?? previous.startedAt),
            'new bytes lack newer preflight',
          );
      }
      prior.set(sample.id.toLowerCase(), sample);
    }
  }
  return {
    ...history,
    attempts,
    nativeProbeQualified: true,
    receiverCapacityQualified: false,
    retryPolicyQualified: false,
    mediaQualified: false,
  };
}
