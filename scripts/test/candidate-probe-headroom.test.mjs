import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyCandidateProbeHeadroom } from '../candidate-probe-headroom.mjs';

// Inputs to this relation have already passed the separate candidate, sender and
// receiver replay gates. This fixture isolates temporal joining and rate policy.
function fixture() {
  const scope = {
    recordingID: 'r',
    matchID: 'm',
    broadcastGeneration: 1,
    publishingAttemptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    appliedProfileRevision: '1',
  };
  const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const snap = (at) => ({
    id,
    stage: 3,
    publishingGeneration: '1',
    bitRate: 12000000,
    startedAt: 10,
    leaseDeadline: at + 0.25,
    observedAt: at,
    lastAcceptedAt: at - 0.01,
    acceptedPayloadBytes: String(Math.round((at - 10) * 100) * 1316),
    reason: null,
  });
  const point = (at) => ({
    id,
    stage: 3,
    publishingGeneration: '1',
    bitRate: 12000000,
    observedAtNanoseconds: String(Math.round(at * 1e9)),
    deliveredMessages: String(Math.round(at * 1000)),
    lastDeliveredAtNanoseconds: String(Math.round((at - 0.01) * 1e9)),
    pendingPackets: 0,
  });
  const row = (start, end) => ({
    start: point(start),
    end: point(end),
    nativeProbeId: id,
    nativeProbeStage: 3,
    nativePublishingGeneration: '1',
    publication: { readerId: 'reader' },
    workerId: 'worker',
    workerEpoch: 'epoch',
    workerAttempt: 1,
    requestStartedAt: end + 0.01,
    responseReceivedAt: end + 0.03,
    evaluatedAt: end + 0.04,
    serverAgeUpperBoundMs: 20,
    nativeLeaseDeadline: end + 0.2,
    durationNanoseconds: String(Math.round((end - start) * 1e9)),
    deliveredPayloadBytesLowerBound: String(Math.round((end - start) * 1000) * 1316),
    payloadBitsPerSecondLowerBound: 10528000,
  });
  const mux = { transportBytes: 2000000, transportMessageCount: 1800 };
  return {
    candidate: {
      scope,
      profile: '540p30',
      frames: 121,
      sourceDuration: 4,
      submissionDuration: 4,
      transport: { ...mux },
    },
    candidateProof: {
      scope,
      measurement: {
        scope,
        startedAt: 10.51,
        endedAt: 15,
        transport: { publishingGeneration: '1', mux },
        encoding: { frames: [{ admittedAt: 10.52 }, { admittedAt: 14.52 }] },
      },
      probeBinding: { boundAt: 10.5, completedAt: 15.01, initial: snap(10.5), final: snap(15.01) },
    },
    accepted: {
      mode: 'staged',
      schedule: 'candidate-headroom-v1',
      publishingGeneration: '1',
      stages: [
        {
          stage: 3,
          id,
          bitRate: 12000000,
          startedAt: 10,
          retirementRequestedAt: 18,
          acceptedPayloadBytes: 10528000,
        },
      ],
    },
    nativeProof: {
      scope,
      events: [10.5, 15.01].map((at) => ({ observedAt: at, sample: snap(at) })),
    },
    intervals: { scope, intervals: [row(12, 13.5), row(13.5, 15.5), row(15.5, 17.5)] },
    intervalQualification: { coveredIntervalIndexes: [0, 1, 2] },
  };
}
test('joins fresh contiguous delivered load and includes exact per-message IPv4 overhead', () => {
  const r = qualifyCandidateProbeHeadroom(fixture());
  assert.equal(r.sufficient, true);
  assert.deepEqual(r.selectedIntervalIndexes, [0, 1]);
  assert.equal(r.candidateAccountedBitsPerSecond, (2000000 + 1800 * 44) * 2);
  assert.equal(r.requiredPaddingPayloadBitsPerSecond, (2000000 + 1800 * 44) * 2 * 1.25);
  assert.equal(r.minimumDeliveredPayloadBitsPerSecond, 10528000);
  assert.equal(r.upgradeAuthorized, false);
  assert.equal(r.mediaHealthQualified, false);
});
test('valid rate shortfall is insufficient evidence, not a capacity upper bound', () => {
  const f = fixture();
  for (const r of f.intervals.intervals) {
    r.deliveredPayloadBytesLowerBound = String(Number(r.deliveredPayloadBytesLowerBound) / 10);
    r.payloadBitsPerSecondLowerBound /= 10;
  }
  assert.equal(qualifyCandidateProbeHeadroom(f).sufficient, false);
});
const faults = {
  scope: (f) => {
    f.nativeProof.scope = { ...f.nativeProof.scope, recordingID: 'wrong' };
  },
  generation: (f) => {
    f.candidateProof.measurement.transport.publishingGeneration = '2';
  },
  probe: (f) => {
    f.candidateProof.probeBinding.final.id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  },
  retired: (f) => {
    f.accepted.stages[0].retirementRequestedAt = 15;
  },
  expired: (f) => {
    f.intervals.intervals[1].nativeLeaseDeadline = 15;
  },
  gap: (f) => {
    f.intervals.intervals[1].start.observedAtNanoseconds = '13600000000';
  },
  unbracketed: (f) => {
    f.intervalQualification.coveredIntervalIndexes = [1, 2];
  },
  staleCandidate: (f) => {
    f.candidateProof.measurement.endedAt = 11;
  },
  oldSnapshot: (f) => {
    f.candidateProof.measurement.endedAt = 15.51;
    const b = f.candidateProof.probeBinding;
    b.completedAt = 15.52;
    Object.assign(b.final, { observedAt: 15.52, leaseDeadline: 15.77, lastAcceptedAt: 15.51 });
    f.nativeProof.events[1] = { observedAt: 15.52, sample: { ...b.final } };
  },
  unalignedCounter: (f) => {
    const b = f.candidateProof.probeBinding;
    b.initial.acceptedPayloadBytes = String(Number(b.initial.acceptedPayloadBytes) + 1);
    f.nativeProof.events[0].sample.acceptedPayloadBytes = b.initial.acceptedPayloadBytes;
  },
  oldCoverage: (f) => {
    f.intervals.intervals[0].start.observedAtNanoseconds = '9000000000';
  },
  changedCost: (f) => {
    f.candidate.transport.transportBytes -= 188;
  },
  changedLease: (f) => {
    f.candidateProof.probeBinding.initial.leaseDeadline += 0.01;
  },
  duplicatedIndex: (f) => {
    f.intervalQualification.coveredIntervalIndexes = [1, 1];
  },
};
for (const [name, mutate] of Object.entries(faults))
  test(`rejects ${name}`, () => {
    const f = structuredClone(fixture());
    mutate(f);
    assert.throws(() => qualifyCandidateProbeHeadroom(f));
  });

test('latest eligible contiguous pair controls the result even if an earlier pair passes', () => {
  const f = fixture();
  for (const [index, [start, end]] of [
    [12.5, 14],
    [14, 15.5],
    [15.5, 16.5],
  ].entries()) {
    const row = f.intervals.intervals[index];
    for (const [point, at] of [
      [row.start, start],
      [row.end, end],
    ]) {
      point.observedAtNanoseconds = String(at * 1e9);
      point.lastDeliveredAtNanoseconds = String(Math.round((at - 0.01) * 1e9));
      point.deliveredMessages = String(at * 1000);
    }
    Object.assign(row, {
      requestStartedAt: end + 0.01,
      responseReceivedAt: end + 0.03,
      evaluatedAt: end + 0.04,
      nativeLeaseDeadline: end + 0.2,
      durationNanoseconds: String((end - start) * 1e9),
      deliveredPayloadBytesLowerBound: String((end - start) * 1000 * 1316),
    });
  }
  const earlier = structuredClone(f);
  earlier.intervals.intervals.pop();
  earlier.intervalQualification.coveredIntervalIndexes = [0, 1];
  assert.equal(qualifyCandidateProbeHeadroom(earlier).sufficient, true);
  const last = f.intervals.intervals[2];
  last.deliveredPayloadBytesLowerBound = String(Number(last.deliveredPayloadBytesLowerBound) / 10);
  last.payloadBitsPerSecondLowerBound /= 10;
  const result = qualifyCandidateProbeHeadroom(f);
  assert.deepEqual(result.selectedIntervalIndexes, [1, 2]);
  assert.equal(result.sufficient, false);
});
