import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyNativeReceiverIntervals } from '../native-receiver-intervals.mjs';
const id = '60000000-0000-4000-8000-00000000000d';
const attempt = '30000000-0000-4000-8000-00000000000c';
const publisherId = '40000000-0000-4000-8000-00000000000b';
const scope = {
  matchID: 'match',
  broadcastGeneration: 1,
  recordingID: 'archive',
  publishingAttemptID: attempt.toUpperCase(),
  appliedProfileRevision: '1',
};
const accepted = { mode: 'renew', id, publishingGeneration: '1', acceptedPayloadBytes: 150 * 1316 };
function snapshot(n) {
  return {
    convention: 'mpegts-null-probe-v1',
    id,
    publishingGeneration: '1',
    bitRate: 1000000,
    deliveredMessages: String(n),
    deliveredPayloadBytes: String(n * 1316),
    nextSequence: String(n),
    pendingPackets: 0,
    observedAtNanoseconds: String(n * 20000000),
    firstDeliveredAtNanoseconds: '100000000',
    lastDeliveredAtNanoseconds: String(n * 20000000 - 1000000),
  };
}
function fixture() {
  const records = [50, 100, 150].map((n) => ({
    publication: {
      publicationId: publisherId,
      publishingAttemptId: attempt,
      gameId: 'match',
      generation: 1,
      recordingId: 'archive',
    },
    probe: snapshot(n),
    request: { startedAtMilliseconds: n * 20 + 100, receivedAtMilliseconds: n * 20 + 110 },
  }));
  const row = {
    start: snapshot(55),
    end: snapshot(105),
    publication: {
      readerId: '20000000-0000-4000-8000-00000000000a',
      publisherId,
      publishingAttemptId: attempt,
      clock: { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '0' },
    },
    workerEpoch: '10000000-0000-4000-8000-00000000000e',
    workerId: 'mac',
    workerAttempt: 1,
    durationNanoseconds: '1000000000',
    deliveredMessages: '50',
    deliveredPayloadBytesLowerBound: '65800',
    payloadBitsPerSecondLowerBound: 526400,
    snapshotAgeUpperBoundMs: 28,
    lastDeliveryAgeUpperBoundMs: 29,
    acceptedPayloadBytes: String(105 * 1316),
    nativeProbeId: id,
    nativePublishingGeneration: '1',
    requestDurationMs: 20,
    residenceDurationMs: 3,
    serverAgeUpperBoundMs: 5,
    requestStartedAt: 102.09,
    responseReceivedAt: 102.11,
    nativeReadStartedAt: 102.11,
    nativeReadFinishedAt: 102.112,
    evaluatedAt: 102.113,
    nativeStartedAt: 100,
    nativeLeaseDeadline: 102.3,
    nativeLastAcceptedAt: 102.099,
  };
  const events = Array.from({ length: 31 }, (_, i) => ({
    phase: i ? 'renewed' : 'began',
    observedAt: 100 + i * 0.1,
    sample: {
      id,
      publishingGeneration: '1',
      bitRate: 1000000,
      startedAt: 100,
      leaseDeadline: 100 + i * 0.1 + 0.3,
      acceptedPayloadBytes: String(i * 5 * 1316),
      lastAcceptedAt: i ? 100 + i * 0.1 - 0.001 : null,
      reason: null,
    },
  }));
  events.push({
    phase: 'final',
    observedAt: 103.1,
    sample: { ...events.at(-1).sample, reason: 'cancelled' },
  });
  const nativeProof = {
    formatVersion: 1,
    isClosed: true,
    invalid: false,
    mode: 'renew',
    result: 'completed',
    scope,
    publishingGeneration: '1',
    events,
  };
  const workerRecords = [
    {
      gameId: 'match',
      generation: 1,
      recordingId: 'archive',
      workerId: row.workerId,
      workerEpoch: row.workerEpoch,
      attempt: row.workerAttempt,
      publication: structuredClone(row.publication),
      completedWindows: [1, 2],
    },
  ];
  return {
    records,
    nativeProof,
    workerRecords,
    proof: { formatVersion: 1, isClosed: true, invalid: false, scope, intervals: [row] },
  };
}
const qualify = (f) =>
  qualifyNativeReceiverIntervals(
    f.proof,
    f.records,
    scope,
    accepted,
    f.workerRecords,
    f.nativeProof,
  );
test('qualifies actual native interval against independently sampled receiver history', () => {
  const result = qualify(fixture());
  assert.equal(result.intervalCount, 1);
  assert.equal(result.deliveredPayloadBytesLowerBound, 65800);
  assert.equal(result.receiverCapacityQualified, false);
});
const faults = {
  missing: (f) => {
    f.proof.intervals = [];
  },
  unclosed: (f) => {
    f.proof.isClosed = false;
  },
  quarantine: (f) => {
    f.proof.invalid = true;
  },
  scope: (f) => {
    f.proof.scope = { ...scope, recordingID: 'other' };
  },
  probe: (f) => {
    f.proof.intervals[0].nativeProbeId = publisherId;
  },
  generation: (f) => {
    f.proof.intervals[0].end.publishingGeneration = '2';
  },
  publication: (f) => {
    f.proof.intervals[0].publication.publisherId = id;
  },
  stale: (f) => {
    f.proof.intervals[0].lastDeliveryAgeUpperBoundMs = 1501;
  },
  age: (f) => {
    f.proof.intervals[0].lastDeliveryAgeUpperBoundMs = 10;
  },
  duration: (f) => {
    f.proof.intervals[0].durationNanoseconds = '900000000';
  },
  count: (f) => {
    f.proof.intervals[0].deliveredMessages = '99';
  },
  payload: (f) => {
    f.proof.intervals[0].deliveredPayloadBytesLowerBound = '131601';
  },
  rate: (f) => {
    f.proof.intervals[0].payloadBitsPerSecondLowerBound *= 2;
  },
  accepted: (f) => {
    f.proof.intervals[0].acceptedPayloadBytes = '1316';
  },
  overlap: (f) => {
    f.proof.intervals.push(structuredClone(f.proof.intervals[0]));
  },
  independentCounter: (f) => {
    f.proof.intervals[0].end = snapshot(290);
    f.proof.intervals[0].end.observedAtNanoseconds = '2100000000';
  },
  independentClock: (f) => {
    f.proof.intervals[0].start.observedAtNanoseconds = '0';
  },
  partial: (f) => {
    f.proof.intervals[0].start.pendingPackets = 1;
  },
};
for (const [name, fault] of Object.entries(faults))
  test(`rejects damaged native interval: ${name}`, () => {
    const f = fixture();
    fault(f);
    assert.throws(() => qualify(f));
  });

for (const [name, fault] of Object.entries({
  worker: (r) => {
    r.workerId = 'other';
  },
  reader: (r) => {
    r.publication.readerId = id;
  },
  epoch: (r) => {
    r.workerEpoch = id;
  },
  attempt: (r) => {
    r.workerAttempt = 2;
  },
  origin: (r) => {
    r.publication.clock.originPTS = '1';
  },
  fabricatedAge: (r) => {
    r.snapshotAgeUpperBoundMs = 0;
    r.lastDeliveryAgeUpperBoundMs = 1;
  },
  coordinatedAge: (r) => {
    r.requestStartedAt = 100.51;
    r.requestDurationMs = 0;
    r.snapshotAgeUpperBoundMs = 8;
    r.lastDeliveryAgeUpperBoundMs = 9;
  },
  nativeCount: (r) => {
    r.acceptedPayloadBytes = String(150 * 1316);
  },
  lease: (r) => {
    r.nativeLeaseDeadline = 103;
  },
  nativeTime: (r) => {
    r.nativeReadFinishedAt = 104;
  },
}))
  test(`rejects uncorrelated native evidence: ${name}`, () => {
    const f = fixture();
    fault(f.proof.intervals[0]);
    assert.throws(() => qualify(f));
  });
