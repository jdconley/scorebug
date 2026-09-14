import assert from 'node:assert/strict';
import test from 'node:test';
import { recordDecodedVideoEvidence } from '../native-streaming-fixture.mjs';

function status(sequence = 1) {
  return {
    gameId: 'game',
    generation: 3,
    workerId: 'worker',
    state: 'producing_output',
    decodedVideoAgeUpperBoundMs: 550,
    observation: {
      gameId: 'game',
      generation: 3,
      attempt: 2,
      state: 'producing_output',
      decodedVideo: {
        ended: false,
        invalidReason: null,
        completed: {
          sequence,
          durationMs: 5000,
          ageMs: 250,
          firstPTS: 0,
          lastPTS: 447000,
          freshFrames: 150,
          duplicateFrames: 0,
          reorderedFrames: 0,
          valid: true,
        },
      },
    },
  };
}

test('collector retains full remote identity and upgrades the first unbounded sample', () => {
  const samples = new Map();
  const first = status();
  delete first.decodedVideoAgeUpperBoundMs;
  recordDecodedVideoEvidence(samples, first);
  const later = status();
  later.observation.decodedVideo.completed.ageMs = 400;
  recordDecodedVideoEvidence(samples, later);
  assert.equal(samples.size, 1);
  const [sample] = samples.values();
  assert.equal(sample.gameId, 'game');
  assert.equal(sample.workerId, 'worker');
  assert.equal(sample.decodedVideoAgeUpperBoundMs, 550);
  assert.equal(sample.completed.ageMs, 400);
});

test('collector rejects immutable content changes and retains independent full scope keys', () => {
  const samples = new Map();
  recordDecodedVideoEvidence(samples, status());
  for (const field of ['gameId', 'workerId']) {
    const next = status();
    next[field] = 'other';
    if (field === 'gameId') next.observation.gameId = 'other';
    recordDecodedVideoEvidence(samples, next);
  }
  assert.equal(samples.size, 3);
  const changed = status();
  changed.observation.decodedVideo.completed.freshFrames++;
  assert.throws(() => recordDecodedVideoEvidence(samples, changed), /immutable/);
});

test('collector rejects later invalid same-window and nonproducing telemetry', () => {
  const samples = new Map();
  recordDecodedVideoEvidence(samples, status());
  for (const state of ['producing_output', 'stopping']) {
    const bad = status();
    bad.state = state;
    bad.observation.decodedVideo.invalidReason = 'numeric';
    assert.throws(() => recordDecodedVideoEvidence(samples, bad), /invalid decoder/);
  }
});

const { qualifyWorkerReportAge } = await import('../worker-report-age-qualification.mjs');
const duration = (seconds, attoseconds) => ({
  seconds: String(seconds),
  attoseconds: String(attoseconds),
});
function fixture(windowCount = 2) {
  const scope = {
    recordingID: 'recording',
    matchID: 'game',
    broadcastGeneration: 3,
    publishingAttemptID: '12345678-1234-4234-9234-123456789abc',
  };
  const decodedEvidence = Array.from({ length: windowCount }, (_, index) => index + 1).map(
    (sequence) => {
      const samples = new Map();
      recordDecodedVideoEvidence(samples, status(sequence));
      return [...samples.values()][0];
    },
  );
  const proofs = decodedEvidence.slice(-2).map((sample) => ({
    recordingID: scope.recordingID,
    publishingAttemptID: scope.publishingAttemptID,
    ...structuredClone(sample),
    evaluatedAt: 'pollControl',
    requestDuration: duration(0, 123000000000000000n),
    residenceDuration: duration(0, 789123456789n),
    helperAgeUpperBound: duration(0, 673000789123456789n),
  }));
  return { snapshot: { scope, workerReportAgeProofs: proofs }, decodedEvidence };
}

test('validates exact submillisecond helper arithmetic while independent poll ages differ', () => {
  const f = fixture();
  f.decodedEvidence[0].completed.ageMs = 350;
  f.decodedEvidence[0].decodedVideoAgeUpperBoundMs = 900;
  const result = qualifyWorkerReportAge(f);
  assert.equal(result.proofCount, 2);
  assert.equal(result.matchedWindowCount, 2);
  assert.equal(result.evidenceMeaning, 'historical helper execution at pollControl');
});

for (const [name, mutate, message] of [
  ['missing proof', (f) => delete f.snapshot.workerReportAgeProofs, /two/],
  ['single proof', (f) => f.snapshot.workerReportAgeProofs.pop(), /two/],
  [
    'recording crossing',
    (f) => (f.snapshot.workerReportAgeProofs[1].recordingID = 'other'),
    /scope/,
  ],
  [
    'publishing attempt crossing',
    (f) => (f.snapshot.workerReportAgeProofs[1].publishingAttemptID = 'other'),
    /scope/,
  ],
  ['remote game crossing', (f) => (f.snapshot.workerReportAgeProofs[1].gameId = 'other'), /scope/],
  ['remote generation crossing', (f) => f.snapshot.workerReportAgeProofs[1].generation++, /scope/],
  [
    'remote worker crossing',
    (f) => (f.snapshot.workerReportAgeProofs[1].workerId = 'other'),
    /scope/,
  ],
  ['remote attempt crossing', (f) => f.snapshot.workerReportAgeProofs[1].attempt++, /scope/],
  ['rewound history', (f) => f.snapshot.workerReportAgeProofs.reverse(), /ordered/],
  [
    'duplicate history',
    (f) =>
      (f.snapshot.workerReportAgeProofs[1] = structuredClone(f.snapshot.workerReportAgeProofs[0])),
    /ordered/,
  ],
  [
    'changed immutable native content',
    (f) => f.snapshot.workerReportAgeProofs[1].completed.freshFrames++,
    /immutable/,
  ],
  [
    'omitted request',
    (f) => delete f.snapshot.workerReportAgeProofs[0].requestDuration,
    /duration/,
  ],
  [
    'omitted residence',
    (f) => delete f.snapshot.workerReportAgeProofs[0].residenceDuration,
    /duration/,
  ],
  [
    'one attosecond mismatch',
    (f) =>
      (f.snapshot.workerReportAgeProofs[0].helperAgeUpperBound.attoseconds = '673000789123456788'),
    /exact/,
  ],
  [
    'fractional server upper',
    (f) => (f.snapshot.workerReportAgeProofs[0].decodedVideoAgeUpperBoundMs = 550.5),
    /server upper/,
  ],
  [
    'negative server upper',
    (f) => (f.snapshot.workerReportAgeProofs[0].decodedVideoAgeUpperBoundMs = -1),
    /server upper/,
  ],
  [
    'server upper below lower',
    (f) => (f.snapshot.workerReportAgeProofs[0].completed.ageMs = 600),
    /lower/,
  ],
  [
    'invalid native decoder window',
    (f) => (f.snapshot.workerReportAgeProofs[1].completed.valid = false),
    /valid/,
  ],
  ['both unmatched', (f) => (f.decodedEvidence = []), /independent bounded/],
  [
    'both unbounded',
    (f) => f.decodedEvidence.forEach((s) => (s.decodedVideoAgeUpperBoundMs = null)),
    /independent bounded/,
  ],
  [
    'unsafe window integer',
    (f) => (f.snapshot.workerReportAgeProofs[0].completed.firstPTS = Number.MAX_SAFE_INTEGER + 1),
    /safe/,
  ],
  [
    'wrong evaluation claim',
    (f) => (f.snapshot.workerReportAgeProofs[0].evaluatedAt = 'export'),
    /pollControl/,
  ],
])
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifyWorkerReportAge(f), message);
  });

for (const components of [
  duration(-1, 0),
  duration('01', 0),
  duration(0, -1),
  duration(0, 1000000000000000000n),
  duration('9223372036854775808', 0),
  duration('1.0', 0),
  { seconds: 0, attoseconds: '0' },
  duration(0, '+1'),
  duration(9007199254740n, 992000000000000000n),
]) {
  test(`rejects malformed or overflowing duration ${JSON.stringify(components)}`, () => {
    const f = fixture();
    f.snapshot.workerReportAgeProofs[0].requestDuration = components;
    assert.throws(() => qualifyWorkerReportAge(f), /duration/);
  });
}

test('reports an unmatched latest boundary proof but requires the older independent match', () => {
  const f = fixture();
  f.decodedEvidence.pop();
  const result = qualifyWorkerReportAge(f);
  assert.equal(result.matchedWindowCount, 1);
  assert.equal(result.unmatchedProofs[0].sequence, 2);
  assert.equal(result.unmatchedProofs[0].position, 'latest');
  assert.match(result.unmatchedProofs[0].reason, /collector/);
});

test('rejects reused API identity with changed immutable content even with another matching window', () => {
  const f = fixture();
  const duplicate = structuredClone(f.decodedEvidence[0]);
  duplicate.completed.lastPTS++;
  f.decodedEvidence.push(duplicate);
  assert.throws(() => qualifyWorkerReportAge(f), /immutable/);
});

test('collector checks immutable reuse after stopping but retains only usable nonended samples', () => {
  const samples = new Map();
  recordDecodedVideoEvidence(samples, status());
  const ended = status(2);
  ended.observation.decodedVideo.ended = true;
  recordDecodedVideoEvidence(samples, ended);
  assert.equal(samples.size, 1);
  const stopping = status();
  stopping.state = 'stopping';
  stopping.observation.decodedVideo.completed.lastPTS++;
  assert.throws(() => recordDecodedVideoEvidence(samples, stopping), /immutable/);
});

test('rejects total age overflow even when each duration alone is bounded', () => {
  const f = fixture();
  f.snapshot.workerReportAgeProofs[0].requestDuration = duration(
    9007199254740n,
    500000000000000000n,
  );
  assert.throws(() => qualifyWorkerReportAge(f), /duration age sum/);
});

test('independent bounded API readings must be individually valid', () => {
  const f = fixture();
  f.decodedEvidence[1].decodedVideoAgeUpperBoundMs = 100;
  assert.throws(() => qualifyWorkerReportAge(f), /lower/);
});

test('rejects missing local recording scope even when both proofs also omit it', () => {
  const f = fixture();
  delete f.snapshot.scope.recordingID;
  for (const proof of f.snapshot.workerReportAgeProofs) delete proof.recordingID;
  assert.throws(() => qualifyWorkerReportAge(f), /scope/);
});

test('keeps the collector qualification default at 64 windows', () => {
  assert.equal(qualifyWorkerReportAge(fixture(64)).matchedWindowCount, 2);
  assert.throws(() => qualifyWorkerReportAge(fixture(65)), /bounded collector/);
  assert.throws(
    () => qualifyWorkerReportAge({ ...fixture(65), decodedWindowLimit: 64 }),
    /bounded collector/,
  );
});

test('qualifies 128 independent windows only with a trusted explicit collector limit', () => {
  const f = fixture(128);
  assert.throws(() => qualifyWorkerReportAge(f), /bounded collector/);
  f.snapshot.decodedWindowLimit = 128;
  f.snapshot.completedWindowLimit = 128;
  f.decodedEvidence.decodedWindowLimit = 128;
  assert.throws(() => qualifyWorkerReportAge(f), /bounded collector/);
  const result = qualifyWorkerReportAge({ ...f, decodedWindowLimit: 128 });
  assert.equal(result.matchedWindowCount, 2);
  assert.deepEqual(
    result.matchedWindows.map((window) => window.sequence),
    [127, 128],
  );
  assert.throws(
    () => qualifyWorkerReportAge({ ...fixture(129), decodedWindowLimit: 128 }),
    /bounded collector/,
  );
});

for (const decodedWindowLimit of [
  0,
  8,
  63,
  65,
  127,
  129,
  Infinity,
  NaN,
  '128',
  null,
  [],
  {},
  true,
]) {
  test(`rejects unsupported trusted collector limit ${JSON.stringify(decodedWindowLimit)} before reading artifacts`, () => {
    const unreadable = new Proxy(
      {},
      {
        get() {
          throw new Error('Artifact must not be read');
        },
      },
    );
    assert.throws(
      () =>
        qualifyWorkerReportAge({
          snapshot: unreadable,
          decodedEvidence: unreadable,
          decodedWindowLimit,
        }),
      /Unsupported decoded window limit/,
    );
  });
}

for (const [name, mutate, message] of [
  [
    'invalid unmatched late telemetry',
    (f) => {
      f.decodedEvidence[125].invalidReason = 'numeric';
    },
    /validity/,
  ],
  [
    'invalid matched late telemetry',
    (f) => {
      f.decodedEvidence[127].completed.valid = false;
    },
    /validity/,
  ],
  [
    'changed matched immutable content',
    (f) => {
      f.decodedEvidence[127].completed.lastPTS++;
    },
    /immutable/,
  ],
  [
    'changed reused late API identity',
    (f) => {
      f.decodedEvidence[125] = structuredClone(f.decodedEvidence[124]);
      f.decodedEvidence[125].completed.lastPTS++;
    },
    /immutable/,
  ],
  [
    'invalid late API bound',
    (f) => {
      f.decodedEvidence[127].decodedVideoAgeUpperBoundMs = 100;
    },
    /lower/,
  ],
  [
    'unsafe late sequence',
    (f) => {
      f.decodedEvidence[125].completed.sequence = Number.MAX_SAFE_INTEGER + 1;
    },
    /safe/,
  ],
  [
    'crossed native scope',
    (f) => {
      f.snapshot.workerReportAgeProofs[1].generation++;
    },
    /scope/,
  ],
  [
    'crossed all matching API scope',
    (f) => {
      f.decodedEvidence[126].attempt++;
      f.decodedEvidence[127].attempt++;
    },
    /independent bounded/,
  ],
  [
    'corrupt helper arithmetic',
    (f) => {
      f.snapshot.workerReportAgeProofs[1].helperAgeUpperBound.attoseconds = '1';
    },
    /exact/,
  ],
]) {
  test(`explicit 128-window qualification still rejects ${name}`, () => {
    const f = { ...fixture(128), decodedWindowLimit: 128 };
    mutate(f);
    assert.throws(() => qualifyWorkerReportAge(f), message);
  });
}
