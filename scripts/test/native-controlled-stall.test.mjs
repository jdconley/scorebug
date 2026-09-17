import assert from 'node:assert/strict';
import test from 'node:test';
import {
  nativeControlledStall,
  qualifyNativeControlledStall,
} from '../native-controlled-stall.mjs';
test('controlled stall requires the explicit fixed-minimum cadence fixture', () => {
  assert.equal(nativeControlledStall({ environment: {}, cadenceReports: false }), false);
  assert.equal(
    nativeControlledStall({
      environment: { SCOREBUG_TEST_DECODER_STALL: '1' },
      cadenceReports: true,
    }),
    true,
  );
  for (const x of [
    { environment: { SCOREBUG_TEST_DECODER_STALL: 'true' }, cadenceReports: true },
    { environment: { SCOREBUG_TEST_DECODER_STALL: '1' }, cadenceReports: false },
  ])
    assert.throws(() => nativeControlledStall(x));
});
function fixture() {
  const receipt = {
    generation: '1',
    encoderSessionID: 'encoder',
    configurationID: 'configuration',
    bitRate: 350000,
    acceptedAt: 99.99,
    lastSubmittedPTS: { value: '60', timescale: 30, epoch: '0', flags: 1 },
  };
  const scope = { publishingAttemptID: 'attempt', matchID: 'match', broadcastGeneration: 1 };
  const signal = {
    scopeID: 'scope',
    workerEpoch: 'epoch',
    workerID: 'mac',
    workerAttempt: 1,
    readerID: 'reader',
    publishingAttemptID: 'attempt',
    lastFreshPTS: '100',
    sequence: '1',
    revision: '0',
    observedAtLowerBound: 102,
  };
  const row = {
    expectedAttempt: 'attempt',
    evaluatedUptime: 102.11,
    sampleAgeSeconds: 0.11,
    observedStall: true,
    response: {
      status: {
        workerId: 'mac',
        workerEpoch: 'epoch',
        publication: { readerId: 'reader', publishingAttemptId: 'attempt' },
        observation: {
          attempt: 1,
          decoderCadence: {
            scopeID: 'scope',
            progress: { lastFreshPTS: 100, ageMs: 1000, stalled: true },
          },
        },
      },
    },
  };
  const resumed = structuredClone(row);
  resumed.evaluatedUptime = 103;
  resumed.observedStall = false;
  resumed.response.status.observation.decoderCadence.progress = {
    lastFreshPTS: 3100,
    ageMs: 10,
    stalled: false,
  };
  return {
    scope,
    audit: { closed: true, overflow: false, invalid: false, rows: [row, resumed] },
    fault: {
      closed: true,
      failed: false,
      identity: {
        worker: { pid: 10 },
        guardian: { pid: 11, ppid: 10 },
        decoder: { pid: 12, ppid: 11 },
      },
      pauseSentAt: 1000,
      resumeSentAt: 2810,
    },
    quality: {
      formatVersion: 4,
      overflow: false,
      events: [
        {
          kind: 'bootstrap',
          profileID: '240p30',
          revision: '0',
          acknowledgedAt: 100,
          receipt: { bitRate: 350000 },
        },
        {
          kind: 'decoderStall',
          profileID: '240p30',
          revision: '0',
          state: 'stalled',
          reasons: ['stalled', 'minimumProfileInsufficient'],
          evaluatedAt: 102.12,
          acknowledgedAt: 100,
          decoderStall: signal,
        },
        { kind: 'stopped', closed: true, profileID: '240p30', revision: '0' },
      ].map((event) => ({ ...event, receipt: structuredClone(receipt), acknowledgedAt: 100 })),
    },
  };
}
test('joins a real admitted stall to raw report and resumed progress', () => {
  const r = qualifyNativeControlledStall(fixture());
  assert.equal(r.minimumHoldDecisionQualified, true);
  assert.equal(r.higherProfileResetWriteQualified, false);
});
for (const [name, damage] of Object.entries({
  stale: (x) => (x.quality.events[1].evaluatedAt = 102.3),
  wrongScope: (x) => (x.quality.events[1].decoderStall.readerID = 'other'),
  preAck: (x) => (x.quality.events[1].acknowledgedAt = 101.01),
  unobserved: (x) => (x.audit.rows[0].observedStall = false),
  unresumed: (x) => x.audit.rows.pop(),
  failedPause: (x) => (x.fault.failed = true),
  shortPause: (x) => (x.fault.resumeSentAt = 1100),
  duplicate: (x) => x.quality.events.splice(2, 0, structuredClone(x.quality.events[1])),
  unexpectedWrite: (x) => x.quality.events.splice(2, 0, { kind: 'applied' }),
  fabricatedWindow: (x) => (x.quality.events[1].window = { captured: 0 }),
  receiptGeneration: (x) => (x.quality.events[1].receipt.generation = '999'),
  receiptEncoder: (x) => (x.quality.events[1].receipt.encoderSessionID = 'other'),
  receiptConfiguration: (x) => (x.quality.events[1].receipt.configurationID = 'other'),
  receiptRate: (x) => (x.quality.events[1].receipt.bitRate = 6000000),
  receiptPTS: (x) => (x.quality.events[1].receipt.lastSubmittedPTS.value = '90'),
  receiptTime: (x) => (x.quality.events[1].receipt.acceptedAt = 100.01),
  acknowledgment: (x) => (x.quality.events[1].acknowledgedAt = 100.01),
  stoppedReceipt: (x) => (x.quality.events.at(-1).receipt.generation = '999'),
  missingReceipt: (x) => delete x.quality.events[1].receipt,
  stoppedProfile: (x) => (x.quality.events.at(-1).profileID = '1080p30'),
  stoppedRevision: (x) => (x.quality.events.at(-1).revision = '1'),
  clockMix: (x) => (x.quality.events[1].decoderStall.observedAtLowerBound = 1002),
}))
  test(`rejects ${name}`, () => {
    const x = fixture();
    damage(x);
    assert.throws(() => qualifyNativeControlledStall(x));
  });

test('reset540 fault mode requires the same explicit cadence prerequisites', () => {
  assert.equal(
    nativeControlledStall({
      environment: { SCOREBUG_TEST_DECODER_STALL: 'reset540' },
      cadenceReports: true,
    }),
    true,
  );
  assert.throws(() =>
    nativeControlledStall({
      environment: { SCOREBUG_TEST_DECODER_STALL: 'reset540' },
      cadenceReports: false,
    }),
  );
});
