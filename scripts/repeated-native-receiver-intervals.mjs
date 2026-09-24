import assert from 'node:assert/strict';
import { qualifyRepeatedNativeBandwidthProbe } from './repeated-native-bandwidth-probe.mjs';
import { qualifyRepeatedReceiverProbeEvidence } from './repeated-receiver-probe-evidence.mjs';
import { qualifyRepeatedProbeRetirements } from './repeated-probe-retirement.mjs';
import { qualifyWorkerPublicationEvidence } from './worker-publication-evidence.mjs';
import {
  validateReceiverProbeSnapshot,
  assertReceiverProbeProgress,
} from './receiver-probe-evidence.mjs';

function uint(value, maximum = 18446744073709551615n) {
  assert.ok(
    typeof value === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(value),
    'Malformed interval counter',
  );
  const n = BigInt(value);
  assert.ok(n <= maximum, 'Interval counter outside bound');
  return n;
}
const packets = (p) => uint(p.deliveredMessages) * 7n + BigInt(p.pendingPackets);
const checkpoint = (s) => Math.max(s.leaseDeadline - 0.3, s.lastAcceptedAt ?? s.startedAt);
/** Cross-check two already validated snapshots of the same native owner.
 * Callers must establish campaign/stage/identity before using this arithmetic. */
export function assertRepeatedNativeAcceptanceConsistent(a, b) {
  const na = uint(a.acceptedPayloadBytes),
    nb = uint(b.acceptedPayloadBytes);
  if (na === nb) {
    assert.equal(
      a.lastAcceptedAt,
      b.lastAcceptedAt,
      'Native acceptance timestamp changed without bytes',
    );
    return;
  }
  const [before, after, delta] = na < nb ? [a, b, nb - na] : [b, a, na - nb];
  assert.ok(
    after.lastAcceptedAt >= checkpoint(before) &&
      Number(delta / 1316n) * 10880 <=
        (after.lastAcceptedAt - checkpoint(before)) * before.bitRate + 10881,
    'Interpolated native acceptance exceeds one-message token allowance',
  );
}
function validateEndpoint(value, stage) {
  const p = validateReceiverProbeSnapshot(value);
  assert.equal(p.convention, 'mpegts-null-probe-v3');
  for (const key of ['id', 'campaign', 'stage', 'publishingGeneration', 'bitRate'])
    assert.equal(p[key], stage[key]);
  const delivered = Number(p.deliveredPayloadBytes);
  assert.equal(Number(p.campaignDeliveredPayloadBytes), stage.campaignBase + delivered);
  assert.equal(
    Number(p.totalDeliveredPayloadBytes),
    stage.publicationBase + stage.campaignBase + delivered,
  );
  assert.ok(
    delivered + (p.pendingPackets ? 1316 : 0) <= stage.acceptedPayloadBytes,
    'Endpoint exceeded native acceptance reservation',
  );
  return p;
}

/** Reconcile raw app intervals with independent authenticated HTTP polling and
 * native v3 ownership. Native uptime and the HTTP collector clock each require
 * their own single receiver-clock offset; neither is rebased between campaigns.
 * Unbracketed rows remain validated but never contribute covered delivered load. */
export function qualifyRepeatedNativeReceiverIntervals({
  intervals: proof,
  records,
  scope,
  nativeProbe,
  workerRecords,
  lifecycle,
  quality,
  candidateProof,
}) {
  const native = qualifyRepeatedNativeBandwidthProbe(nativeProbe, {
    scope,
    publishingGeneration: nativeProbe?.publishingGeneration,
  });
  const receiver = qualifyRepeatedReceiverProbeEvidence(records, scope, nativeProbe);
  const retirements = qualifyRepeatedProbeRetirements(nativeProbe, {
    lifecycle,
    quality,
    candidateProof,
  });
  const workers = qualifyWorkerPublicationEvidence(workerRecords, scope);
  assert.equal(proof?.formatVersion, 1);
  assert.equal(proof.isClosed, true);
  assert.equal(proof.invalid, false);
  assert.deepEqual(proof.scope, scope);
  assert.ok(
    Array.isArray(proof.intervals) && proof.intervals.length > 0 && proof.intervals.length <= 128,
    'Missing bounded repeated receiver intervals',
  );
  let publicationBase = 0;
  const stages = native.campaigns.flatMap((campaign, index) => {
    let campaignBase = 0;
    const result = campaign.stages.map((s) => {
      const stage = {
        ...s,
        campaignBase,
        publicationBase,
        retirementRequestedAt:
          s.stage === 3
            ? retirements.campaigns[index].retirementRequestedAt
            : s.retirementRequestedAt,
        events: nativeProbe.campaigns[index].events.filter((e) => e.sample.stage === s.stage),
      };
      campaignBase += s.acceptedPayloadBytes;
      return stage;
    });
    publicationBase += campaign.acceptedPayloadBytes;
    return result;
  });
  const snapshots = records.map((r) => validateReceiverProbeSnapshot(r.probe));
  const combined = [...snapshots],
    nativeSamples = [];
  let prior,
    identity,
    offsetLower = -Infinity,
    offsetUpper = Infinity;
  let total = 0n,
    duration = 0n,
    minimumRate = Infinity;
  const coveredIntervalIndexes = [],
    seenStages = new Set();
  for (const [index, row] of proof.intervals.entries()) {
    const stageIndex = stages.findIndex(
      (s) => s.campaign === row.nativeProbeCampaign && s.stage === row.nativeProbeStage,
    );
    assert.ok(stageIndex >= 0, 'Unknown original native campaign/stage');
    const stage = stages[stageIndex],
      events = stage.events;
    assert.equal(row.nativeProbeId, stage.id);
    assert.equal(row.nativePublishingGeneration, native.publishingGeneration);
    assert.ok(
      row.evaluatedAt < stage.retirementRequestedAt,
      'Interval evaluated after retirement request',
    );
    if (prior) assert.ok(stageIndex >= prior.stageIndex, 'Native campaign/stage regressed');
    const worker = workers.find(
      (w) =>
        w.workerId === row.workerId &&
        w.workerEpoch === row.workerEpoch &&
        w.attempt === row.workerAttempt,
    );
    assert.ok(worker, 'Uncorrelated worker identity');
    assert.deepEqual(row.publication, worker.publication);
    assert.equal(row.publication.publisherId, receiver.publicationId);
    const nextIdentity = [row.publication, row.workerId, row.workerEpoch, row.workerAttempt];
    if (identity)
      assert.deepEqual(nextIdentity, identity, 'Worker identity or publication clock changed');
    else {
      qualifyWorkerPublicationEvidence([worker], scope);
      identity = nextIdentity;
    }
    for (const key of [
      'requestStartedAt',
      'responseReceivedAt',
      'nativeReadStartedAt',
      'nativeReadFinishedAt',
      'evaluatedAt',
      'nativeStartedAt',
      'nativeLeaseDeadline',
      'nativeLastAcceptedAt',
      'requestDurationMs',
      'residenceDurationMs',
      'serverAgeUpperBoundMs',
    ])
      assert.ok(Number.isFinite(row[key]) && row[key] >= 0, `Invalid ${key}`);
    assert.ok(
      row.requestStartedAt <= row.responseReceivedAt &&
        row.responseReceivedAt <= row.nativeReadStartedAt &&
        row.nativeReadStartedAt <= row.nativeReadFinishedAt &&
        row.nativeReadFinishedAt <= row.evaluatedAt,
      'Invalid native request chronology',
    );
    assert.ok(Number.isSafeInteger(row.serverAgeUpperBoundMs));
    assert.ok(
      row.requestDurationMs <= (row.responseReceivedAt - row.requestStartedAt) * 1000 + 0.001,
    );
    assert.ok(
      row.requestDurationMs + row.residenceDurationMs <=
        (row.evaluatedAt - row.requestStartedAt) * 1000 + 0.001,
    );
    assert.ok(
      (row.nativeReadFinishedAt - row.nativeReadStartedAt) * 1000 <=
        row.residenceDurationMs + 0.001,
    );
    assert.ok(
      Math.abs(
        row.snapshotAgeUpperBoundMs -
          row.serverAgeUpperBoundMs -
          row.requestDurationMs -
          row.residenceDurationMs,
      ) < 1e-6,
      'Understated snapshot age',
    );
    assert.equal(row.nativeStartedAt, stage.startedAt);
    assert.ok(
      row.nativeStartedAt <= row.nativeLastAcceptedAt &&
        row.nativeLastAcceptedAt <= row.nativeReadFinishedAt &&
        row.nativeLastAcceptedAt < row.nativeLeaseDeadline &&
        row.evaluatedAt < row.nativeLeaseDeadline,
      'Native observation outside active lease',
    );
    const nativeBytes = uint(row.acceptedPayloadBytes, BigInt(stage.acceptedPayloadBytes));
    assert.ok(nativeBytes > 0n && nativeBytes % 1316n === 0n);
    const sample = {
      startedAt: row.nativeStartedAt,
      leaseDeadline: row.nativeLeaseDeadline,
      lastAcceptedAt: row.nativeLastAcceptedAt,
      acceptedPayloadBytes: row.acceptedPayloadBytes,
      bitRate: stage.bitRate,
    };
    assert.ok(
      checkpoint(sample) <= row.nativeReadFinishedAt + 1e-6,
      'Native renewal is in the future',
    );
    assert.ok(
      Number(nativeBytes / 1316n) * 10880 <=
        (row.nativeLastAcceptedAt - stage.startedAt) * stage.bitRate + 1,
      'Native lifetime pacing exceeded',
    );
    const renewal = events.find(
      (e) => e.sample.leaseDeadline === row.nativeLeaseDeadline && e.sample.reason === null,
    );
    assert.ok(renewal, 'Unobserved native lease');
    assert.ok(
      nativeBytes >= uint(renewal.sample.acceptedPayloadBytes) &&
        row.nativeLastAcceptedAt >= (renewal.sample.lastAcceptedAt ?? stage.startedAt),
      'Native observation precedes its renewal',
    );
    for (const event of events) {
      assertRepeatedNativeAcceptanceConsistent(sample, event.sample);
      if (event.observedAt <= row.nativeReadStartedAt) {
        assert.equal(event.sample.reason, null, 'Interval sampled after native withdrawal');
        assert.ok(
          uint(event.sample.acceptedPayloadBytes) <= nativeBytes &&
            event.sample.leaseDeadline <= row.nativeLeaseDeadline,
          'Native observation regresses raw history',
        );
      }
    }
    for (const earlier of nativeSamples.filter((s) => s.stageIndex === stageIndex))
      assertRepeatedNativeAcceptanceConsistent(earlier.sample, sample);
    nativeSamples.push({ stageIndex, sample });
    const start = validateEndpoint(row.start, stage),
      end = validateEndpoint(row.end, stage);
    combined.push(start, end);
    const receiverMilliseconds = Number(uint(end.observedAtNanoseconds)) / 1e6;
    offsetLower = Math.max(
      offsetLower,
      row.requestStartedAt * 1000 - row.serverAgeUpperBoundMs - receiverMilliseconds,
    );
    offsetUpper = Math.min(offsetUpper, row.responseReceivedAt * 1000 - receiverMilliseconds);
    assert.ok(offsetLower <= offsetUpper, 'Native/receiver clocks cannot fit request bounds');
    let covered = true;
    const independent = snapshots.filter(
      (p) => p.campaign === stage.campaign && p.stage === stage.stage,
    );
    for (const p of [start, end]) {
      const at = uint(p.observedAtNanoseconds);
      const before = independent.findLast((s) => uint(s.observedAtNanoseconds) <= at);
      const after = independent.find((s) => uint(s.observedAtNanoseconds) >= at);
      if (!before || !after) {
        covered = false;
        continue;
      }
      assert.ok(
        packets(before) <= packets(p) && packets(p) <= packets(after),
        'Independent receiver counter mismatch',
      );
      if (before.firstDeliveredAtNanoseconds !== undefined)
        assert.equal(p.firstDeliveredAtNanoseconds, before.firstDeliveredAtNanoseconds);
      if (p.firstDeliveredAtNanoseconds !== undefined)
        assert.equal(p.firstDeliveredAtNanoseconds, after.firstDeliveredAtNanoseconds);
      if (p.deliveredMessages === before.deliveredMessages)
        assert.equal(p.lastDeliveredAtNanoseconds, before.lastDeliveredAtNanoseconds);
      else assert.ok(uint(p.lastDeliveredAtNanoseconds) >= uint(before.observedAtNanoseconds));
      if (p.deliveredMessages === after.deliveredMessages)
        assert.equal(p.lastDeliveredAtNanoseconds, after.lastDeliveredAtNanoseconds);
      else assert.ok(uint(after.lastDeliveredAtNanoseconds) >= at);
    }
    const count = uint(end.deliveredMessages) - uint(start.deliveredMessages);
    const elapsed = uint(end.observedAtNanoseconds) - uint(start.observedAtNanoseconds);
    assert.ok(elapsed >= 1000000000n && elapsed <= 5000000000n);
    assert.equal(uint(row.durationNanoseconds), elapsed);
    assert.equal(uint(row.deliveredMessages), count);
    const lowerBytes = count * 1316n - BigInt(start.pendingPackets) * 188n;
    assert.ok(lowerBytes > 0n);
    assert.equal(uint(row.deliveredPayloadBytesLowerBound), lowerBytes);
    const rate = (Number(lowerBytes) * 8e9) / Number(elapsed);
    assert.ok(
      Number.isFinite(row.payloadBitsPerSecondLowerBound) &&
        Math.abs(rate - row.payloadBitsPerSecondLowerBound) < 0.001,
    );
    assert.ok(
      (uint(end.deliveredMessages) + (end.pendingPackets ? 1n : 0n)) * 1316n <= nativeBytes,
      'Pending receiver message exceeds native acceptance',
    );
    for (const age of [row.snapshotAgeUpperBoundMs, row.lastDeliveryAgeUpperBoundMs])
      assert.ok(Number.isFinite(age) && age >= 0 && age <= 1500);
    const outerAge = row.serverAgeUpperBoundMs + (row.evaluatedAt - row.requestStartedAt) * 1000;
    assert.ok(outerAge <= 1500, 'Stale outer snapshot age');
    const deliveryAge =
      Number(uint(end.observedAtNanoseconds) - uint(end.lastDeliveredAtNanoseconds)) / 1e6;
    assert.ok(
      Math.abs(row.lastDeliveryAgeUpperBoundMs - row.snapshotAgeUpperBoundMs - deliveryAge) < 1e-6,
    );
    assert.ok(outerAge + deliveryAge <= 1500, 'Stale outer delivery age');
    if (prior) {
      assert.ok(
        uint(start.observedAtNanoseconds) >= uint(prior.row.end.observedAtNanoseconds),
        'Overlapping native intervals',
      );
      assert.ok(
        row.requestStartedAt >= prior.row.responseReceivedAt &&
          row.evaluatedAt >= prior.row.evaluatedAt,
        'Native interval requests regressed',
      );
      if (stageIndex === prior.stageIndex)
        assert.ok(
          nativeBytes >= uint(prior.row.acceptedPayloadBytes) &&
            row.nativeLeaseDeadline >= prior.row.nativeLeaseDeadline &&
            row.nativeLastAcceptedAt >= prior.row.nativeLastAcceptedAt,
        );
    }
    prior = { row, stageIndex };
    if (covered) {
      coveredIntervalIndexes.push(index);
      seenStages.add(stageIndex);
      total += lowerBytes;
      duration += elapsed;
      minimumRate = Math.min(minimumRate, rate);
    }
  }
  combined.sort((a, b) =>
    Number(BigInt(a.observedAtNanoseconds) - BigInt(b.observedAtNanoseconds)),
  );
  for (let i = 1; i < combined.length; i++)
    assertReceiverProbeProgress(combined[i], combined[i - 1]);
  assert.deepEqual([...seenStages], [0, 1, 2, 3, 4, 5], 'Missing covered original native stage');
  return {
    mode: 'repeated',
    scope: structuredClone(scope),
    publishingGeneration: native.publishingGeneration,
    coveredIntervalIndexes,
    observedIntervalCount: proof.intervals.length,
    unbracketedIntervalCount: proof.intervals.length - coveredIntervalIndexes.length,
    intervalCount: coveredIntervalIndexes.length,
    deliveredPayloadBytesLowerBound: Number(total),
    receiverReadCoverageSeconds: Number(duration) / 1e9,
    minimumPayloadBitsPerSecondLowerBound: minimumRate,
    clockOffsetBoundMilliseconds: [offsetLower, offsetUpper],
    independentReceiverClockOffsetBoundMilliseconds: receiver.clockOffsetBoundMilliseconds,
    campaigns: native.campaigns.map((campaign) => ({
      campaign: campaign.campaign,
      appliedRevision: campaign.context.appliedRevision,
      coveredIntervalIndexes: coveredIntervalIndexes.filter(
        (i) => proof.intervals[i].nativeProbeCampaign === campaign.campaign,
      ),
      stages: campaign.stages.map((s) => ({ stage: s.stage, id: s.id, bitRate: s.bitRate })),
    })),
    receiverCapacityQualified: false,
    admissionQualified: false,
    repeatedPolicyQualified: false,
    upgradeAuthorized: false,
  };
}
