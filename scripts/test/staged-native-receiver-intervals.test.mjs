import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyNativeReceiverIntervals } from '../native-receiver-intervals.mjs';
import { stagedProbeEvidence } from './fixtures/staged-probe-evidence.mjs';
const qualify = (f) =>
  qualifyNativeReceiverIntervals(
    f.proof,
    f.records,
    f.scope,
    f.accepted,
    f.workerRecords,
    f.nativeProof,
  );
test('independently reconciles native intervals at every staged probe rate', () => {
  const result = qualify(stagedProbeEvidence());
  assert.equal(result.intervalCount, 3);
  assert.equal(result.receiverReadCoverageSeconds, 3);
  assert.equal(result.receiverCapacityQualified, false);
});
const faults = {
  omittedStage: (f) => {
    f.proof.intervals.splice(1, 1);
  },
  missingStageMetadata: (f) => {
    delete f.proof.intervals[1].nativeProbeStage;
  },
  substitutedNativeStage: (f) => {
    f.proof.intervals[1].nativeProbeStage = 1;
  },
  substitutedNativeId: (f) => {
    f.proof.intervals[1].nativeProbeId = f.accepted.stages[0].id;
  },
  crossStageWindow: (f) => {
    f.proof.intervals[1].start = structuredClone(f.proof.intervals[0].start);
  },
  endpointTotal: (f) => {
    f.proof.intervals[1].end.totalDeliveredPayloadBytes =
      f.proof.intervals[1].end.deliveredPayloadBytes;
  },
  fabricatedAcceptedSummary: (f) => {
    f.accepted.stages[1].retirementRequestedAt += 1;
  },
  unobservedLease: (f) => {
    f.proof.intervals[1].nativeLeaseDeadline += 0.01;
  },
  anotherStageLease: (f) => {
    f.proof.intervals[1].nativeLeaseDeadline = f.proof.intervals[2].nativeLeaseDeadline;
  },
  anotherStageStart: (f) => {
    f.proof.intervals[1].nativeStartedAt = f.proof.intervals[0].nativeStartedAt;
  },
  nativeByteOverflow: (f) => {
    f.proof.intervals[1].acceptedPayloadBytes = '16776536';
  },
  mixedVersion: (f) => {
    f.proof.intervals[1].end.convention = 'mpegts-null-probe-v1';
  },
  stageRegression: (f) => {
    f.proof.intervals.reverse();
  },
  noIndependentStageCoverage: (f) => {
    f.records = f.records.filter((r) => r.probe.stage !== 2);
  },
  crossStageClockShift: (f) => {
    for (const k of [
      'requestStartedAt',
      'responseReceivedAt',
      'nativeReadStartedAt',
      'nativeReadFinishedAt',
      'evaluatedAt',
    ])
      f.proof.intervals[1][k] += 0.05;
  },
  retirementCutoff: (f) => {
    // Still before the last observed lease; only the retirement cutoff excludes it.
    const r = f.proof.intervals[1];
    r.evaluatedAt = f.accepted.stages[1].retirementRequestedAt;
    r.residenceDurationMs = (r.evaluatedAt - r.responseReceivedAt) * 1000;
    r.snapshotAgeUpperBoundMs =
      r.serverAgeUpperBoundMs + r.requestDurationMs + r.residenceDurationMs;
    r.lastDeliveryAgeUpperBoundMs = r.snapshotAgeUpperBoundMs + 1;
    r.nativeLeaseDeadline = f.nativeProof.events
      .filter((e) => e.sample.stage === 2 && e.phase === 'renewed')
      .at(-1).sample.leaseDeadline;
    r.nativeReadFinishedAt = r.evaluatedAt;
  },
};
for (const [name, mutate] of Object.entries(faults))
  test(`rejects staged native interval ${name}`, () => {
    const f = stagedProbeEvidence();
    mutate(f);
    assert.throws(() => qualify(f));
  });
test('rejects endpoint delivery regression inside a sparse independent polling bracket', () => {
  const f = stagedProbeEvidence();
  f.records.splice(1, 1);
  const row = f.proof.intervals[0];
  row.end.lastDeliveredAtNanoseconds = '1050000000';
  row.lastDeliveryAgeUpperBoundMs = row.snapshotAgeUpperBoundMs + 1050;
  assert.throws(() => qualify(f));
});
test('rejects newly delivered endpoint messages predating its start observation', () => {
  const f = stagedProbeEvidence();
  f.records.splice(1, 1);
  const row = f.proof.intervals[0];
  row.end.lastDeliveredAtNanoseconds = '1099500000';
  row.lastDeliveryAgeUpperBoundMs = row.snapshotAgeUpperBoundMs + 1000.5;
  assert.throws(() => qualify(f));
});
function boundaryFixture() {
  const f = stagedProbeEvidence();
  // Keep the original fully bracketed interval in each stage, and prepend a
  // coherent stage-1 interval whose start predates its first independent poll.
  const row = structuredClone(f.proof.intervals[0]);
  row.start.observedAtNanoseconds = '500000000';
  row.start.deliveredMessages = '20';
  row.start.deliveredPayloadBytes = '26320';
  row.start.totalDeliveredPayloadBytes = '26320';
  row.start.nextSequence = '20';
  row.start.lastDeliveredAtNanoseconds = '499000000';
  row.end.observedAtNanoseconds = '1500000000';
  row.end.deliveredMessages = '60';
  row.end.deliveredPayloadBytes = '78960';
  row.end.totalDeliveredPayloadBytes = '78960';
  row.end.nextSequence = '60';
  row.end.lastDeliveredAtNanoseconds = '1499000000';
  row.acceptedPayloadBytes = '78960';
  for (const key of [
    'requestStartedAt',
    'responseReceivedAt',
    'nativeReadStartedAt',
    'nativeReadFinishedAt',
    'evaluatedAt',
    'nativeLeaseDeadline',
    'nativeLastAcceptedAt',
  ])
    row[key] -= 0.6;
  // Shift the original stage-1 interval to a nonoverlapping 1.5..2.5s window.
  const next = f.proof.intervals[0];
  Object.assign(next.start, structuredClone(row.end));
  Object.assign(next.end, {
    observedAtNanoseconds: '2500000000',
    deliveredMessages: '100',
    deliveredPayloadBytes: '131600',
    totalDeliveredPayloadBytes: '131600',
    nextSequence: '100',
    lastDeliveredAtNanoseconds: '2499000000',
  });
  next.acceptedPayloadBytes = '131600';
  for (const key of [
    'requestStartedAt',
    'responseReceivedAt',
    'nativeReadStartedAt',
    'nativeReadFinishedAt',
    'evaluatedAt',
    'nativeLeaseDeadline',
    'nativeLastAcceptedAt',
  ])
    next[key] += 0.4;
  // Use the exact native arithmetic for lease timestamps.
  row.nativeLeaseDeadline = f.nativeProof.events[15].sample.leaseDeadline;
  next.nativeLeaseDeadline = f.nativeProof.events[25].sample.leaseDeadline;
  f.proof.intervals.unshift(row);
  return f;
}
test('qualifies only independently bracketed intervals and reports boundary omissions', () => {
  const f = boundaryFixture();
  const result = qualify(f);
  assert.equal(result.observedIntervalCount, 4);
  assert.equal(result.unbracketedIntervalCount, 1);
  assert.equal(result.intervalCount, 3);
  assert.equal(result.receiverReadCoverageSeconds, 3);
});
test('cannot qualify a stage represented only by an unbracketed interval', () => {
  const f = stagedProbeEvidence();
  f.records.splice(0, 1);
  assert.throws(() => qualify(f));
});

for (const fault of ['identity', 'history', 'lease'])
  test(`unbracketed boundary interval still rejects ${fault} corruption`, () => {
    const f = boundaryFixture(),
      r = f.proof.intervals[0];
    if (fault === 'identity') r.nativeProbeId = f.proof.intervals[2].nativeProbeId;
    if (fault === 'history') r.start.firstDeliveredAtNanoseconds = '25000000';
    if (fault === 'lease') r.nativeLeaseDeadline += 0.01;
    assert.throws(() => qualify(f));
  });

test('unbracketed tail cannot remain in the old stage after next-stage delivery begins', () => {
  const f = stagedProbeEvidence(),
    tail = f.proof.intervals[0];
  Object.assign(tail.start, {
    observedAtNanoseconds: '2005000000',
    deliveredMessages: '80',
    deliveredPayloadBytes: '105280',
    totalDeliveredPayloadBytes: '105280',
    nextSequence: '80',
    lastDeliveredAtNanoseconds: '1999000000',
  });
  Object.assign(tail.end, {
    observedAtNanoseconds: '3005000000',
    deliveredMessages: '120',
    deliveredPayloadBytes: '157920',
    totalDeliveredPayloadBytes: '157920',
    nextSequence: '120',
    lastDeliveredAtNanoseconds: '2999000000',
  });
  Object.assign(tail, {
    acceptedPayloadBytes: '157920',
    nativeLastAcceptedAt: 102.999,
    nativeLeaseDeadline: 103.3,
    requestStartedAt: 103.001,
    responseReceivedAt: 103.006,
    nativeReadStartedAt: 103.007,
    nativeReadFinishedAt: 103.0075,
    evaluatedAt: 103.008,
    requestDurationMs: 5,
    residenceDurationMs: 2,
    snapshotAgeUpperBoundMs: 12,
    lastDeliveryAgeUpperBoundMs: 18,
  });
  // Retain one covered stage-1 interval before the unbracketed tail. Both
  // evaluations precede retirement and all native counters remain unchanged.
  const head = structuredClone(tail);
  Object.assign(head.start, {
    observedAtNanoseconds: '1005000000',
    deliveredMessages: '40',
    deliveredPayloadBytes: '52640',
    totalDeliveredPayloadBytes: '52640',
    nextSequence: '40',
    lastDeliveredAtNanoseconds: '999000000',
  });
  head.end = structuredClone(tail.start);
  Object.assign(head, {
    acceptedPayloadBytes: '105280',
    nativeLastAcceptedAt: 101.999,
    nativeLeaseDeadline: 102.3,
    requestStartedAt: 102.001,
    responseReceivedAt: 102.006,
    nativeReadStartedAt: 102.007,
    nativeReadFinishedAt: 102.0075,
    evaluatedAt: 102.008,
  });
  f.proof.intervals.unshift(head);
  assert.equal(qualify(f).intervalCount, 3);
  assert.equal(qualify(f).unbracketedIntervalCount, 1);

  // Raw polling last saw stage 1 at 3 s, but its app endpoint still sees it
  // at 3.005 s. Starting stage-2 delivery at 3.002 s contradicts that endpoint.
  for (const snapshot of [
    ...f.records.map((record) => record.probe),
    ...f.proof.intervals.flatMap((row) => [row.start, row.end]),
  ])
    if (snapshot.stage === 2) snapshot.firstDeliveredAtNanoseconds = '3002000000';
  assert.throws(() => qualify(f));
});
