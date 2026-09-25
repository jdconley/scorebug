import test from 'node:test';
import assert from 'node:assert/strict';
import {
  nativeProfileTransitions,
  nativeAdaptiveProfiles,
  qualifyNativeProfileTransitions,
} from '../native-profile-transitions.mjs';
const options = {
  environment: {
    SCOREBUG_TEST_PROFILE_TRANSITIONS: '1',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
    SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
  },
  streaming: true,
  requireProcessing: true,
  requirePublication: true,
  holdSeconds: 90,
};
test('transition experiment requires exclusive explicit full-pipeline prerequisites', () => {
  assert.equal(nativeProfileTransitions(options), true);
  assert.equal(nativeProfileTransitions({ environment: {} }), false);
  for (const [key, value] of Object.entries({
    SCOREBUG_TEST_PROFILE_TRANSITIONS: '',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '0',
    SCOREBUG_TEST_MOTION_FIXTURE: '1',
    SCOREBUG_TEST_NATIVE_QUALITY: '1',
    SCOREBUG_TEST_NATIVE_CONFIRMATION: '1',
    SCOREBUG_TEST_LIVE_PROFILE: '540p30',
    SCOREBUG_TEST_UPLINK_PROFILE: 'rate4m',
  }))
    assert.throws(() =>
      nativeProfileTransitions({
        ...options,
        environment: { ...options.environment, [key]: value },
      }),
    );
  for (const patch of [
    { streaming: false },
    { requireProcessing: false },
    { requirePublication: false },
    { holdSeconds: 89 },
    { holdSeconds: 601 },
  ]) {
    assert.throws(() => nativeProfileTransitions({ ...options, ...patch }));
  }
});
const pts = (n) => ({ value: String(7395 + 2 * n), timescale: 60, epoch: '0', flags: 1 });
const ids = [
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
];
function fixture(phaseCount = 3, adaptive = false) {
  const scope = {
    recordingID: 'recording',
    matchID: 'match',
    broadcastGeneration: 1,
    publishingAttemptID: 'attempt',
    appliedProfileRevision: '1',
  };
  const indices = Array.from({ length: phaseCount }, (_, n) => n);
  const sessionIDs = indices.map(
    (n) => ids[n] ?? `${String(n + 1).padStart(8, '0')}-4444-4444-8444-444444444444`,
  );
  const phases = indices.map((n) => ({
    width: n % 2 ? 960 : 1920,
    height: n % 2 ? 540 : 1080,
    frames: 900,
    firstSourcePTS: pts(n * 900),
    lastSourcePTS: pts(n * 900 + 899),
    maximumSourceGapSeconds: 1 / 30,
    firstObservedAt: 100.01 + n * 30,
    lastObservedAt: 100.01 + n * 30 + 899 / 30,
    maximumObservationGapSeconds: 1 / 30,
  }));
  const format = {
    formatVersion: adaptive ? 3 : 2,
    scope,
    isClosed: true,
    invalid: false,
    frames: 900 * phaseCount,
    publishingGeneration: '2',
    phases,
    encoderSessions: phases.map((p, n) => ({
      encoderSessionID: sessionIDs[n],
      frames: p.frames,
      firstSourcePTS: p.firstSourcePTS,
      lastSourcePTS: p.lastSourcePTS,
      firstCompletedAt: 100 + n * 30,
      lastCompletedAt: 100 + n * 30 + 899 / 30,
      maximumCompletionGapSeconds: 1 / 30,
      maximumEncodeLatencySeconds: 0.2,
    })),
    receipts: indices.slice(1).map((n) => ({
      profile: n % 2 ? '540p30' : '1080p30',
      publishingGeneration: '2',
      previousEncoderSessionID: sessionIDs[n - 1],
      encoderSessionID: sessionIDs[n],
      lastOldSourcePTS: pts(n * 900 - 1),
      firstNewSourcePTS: pts(n * 900),
      width: phases[n].width,
      height: phases[n].height,
      rawVideoFramesDropped: '0',
      acknowledgedAt: 100 + n * 30 + 0.1,
    })),
  };
  const snapshot = {
    scope,
    isClosed: true,
    monotonicAnchor: 99,
    captureDetachedAt: 101 + 30 * phaseCount,
    omittedCompletedWindowCount: '0',
    publishingClockObservation: { publishingGeneration: '2' },
    completed: [
      {
        encodedVideo: {
          callbackCount: String(900 * phaseCount),
          firstSourcePTS: pts(0),
          lastSourcePTS: pts(900 * phaseCount - 1),
        },
      },
    ],
    current: { encodedVideo: { callbackCount: '0' } },
  };
  return {
    format,
    snapshot,
    liveIDs: Array.from({ length: 900 * phaseCount - 30 }, (_, n) => n + 30),
  };
}
test('adaptive profile fixture requires explicit isolated pressure and recovery prerequisites', () => {
  const o = {
    ...options,
    holdSeconds: 240,
    environment: {
      SCOREBUG_TEST_ADAPTIVE_PROFILES: '1',
      SCOREBUG_TEST_NATIVE_QUALITY: '1',
      SCOREBUG_TEST_NATIVE_CONFIRMATION: '1',
      SCOREBUG_TEST_UPLINK_PROFILE: 'rate4m',
      SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
      SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
    },
  };
  assert.equal(nativeAdaptiveProfiles(o), true);
  assert.equal(nativeAdaptiveProfiles({ environment: {} }), false);
  for (const [k, v] of Object.entries({
    SCOREBUG_TEST_ADAPTIVE_PROFILES: '',
    SCOREBUG_TEST_NATIVE_QUALITY: '0',
    SCOREBUG_TEST_NATIVE_CONFIRMATION: '0',
    SCOREBUG_TEST_UPLINK_PROFILE: 'passthrough',
    SCOREBUG_TEST_MOTION_FIXTURE: '1',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '0',
    SCOREBUG_TEST_PROFILE_TRANSITIONS: '1',
    SCOREBUG_TEST_LIVE_PROFILE: '540p30',
  })) {
    assert.throws(() =>
      nativeAdaptiveProfiles({ ...o, environment: { ...o.environment, [k]: v } }),
    );
  }
  for (const patch of [
    { streaming: false },
    { requireProcessing: false },
    { requirePublication: false },
    { holdSeconds: 239 },
    { holdSeconds: 601 },
  ]) {
    assert.throws(() => nativeAdaptiveProfiles({ ...o, ...patch }));
  }
});
test('adaptive evidence supports bounded rollback and recovery phases without weakening fixed mode', () => {
  for (const n of [3, 5, 17]) {
    const f = fixture(n, true);
    assert.equal(
      qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, { adaptive: true }).phases
        .length,
      n,
    );
    assert.throws(() => qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs));
  }
  for (const n of [1, 2, 4, 19]) {
    const f = fixture(n, true);
    assert.throws(() =>
      qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, { adaptive: true }),
    );
  }
  const f = fixture(5, true);
  f.format.receipts[3].encoderSessionID = ids[0];
  assert.throws(() =>
    qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, { adaptive: true }),
  );
});
test('requires real phone phases, exact receipts and decoded coverage across both changes', () => {
  const { format, snapshot, liveIDs } = fixture();
  const result = qualifyNativeProfileTransitions(format, snapshot, liveIDs);
  assert.equal(result.phases.length, 3);
  assert.equal(result.phases[1].decodedFrames, 900);
  assert.equal(result.phases[2].freshFps, 30);
});
test('rejects mismatched phase, source, identity, closure or downstream evidence', () => {
  const corruptions = [
    (f) => {
      f.format.isClosed = false;
    },
    (f) => {
      f.format.invalid = true;
    },
    (f) => {
      f.format.scope = { ...f.format.scope, recordingID: 'other' };
    },
    (f) => {
      f.format.frames--;
    },
    (f) => {
      f.format.phases[1].width = 1920;
    },
    (f) => {
      f.format.phases[1].firstSourcePTS = pts(901);
    },
    (f) => {
      f.format.receipts[1].encoderSessionID = ids[0];
    },
    (f) => {
      f.format.receipts[0].publishingGeneration = '3';
    },
    (f) => {
      f.format.receipts[0].lastOldSourcePTS = pts(898);
    },
    (f) => {
      f.format.receipts[1].acknowledgedAt = 20;
    },
    (f) => {
      f.liveIDs.splice(880, 100);
    },
    (f) => {
      f.format.phases[1].maximumSourceGapSeconds = 0.8;
    },
    (f) => {
      f.format.receipts.push(f.format.receipts[0]);
    },
  ];
  for (const corrupt of corruptions) {
    const f = fixture();
    corrupt(f);
    assert.throws(() => qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs));
  }
});

test('receipt UUIDs and acknowledgment must agree with independent native callbacks', () => {
  for (const corrupt of [
    (f) => {
      f.format.receipts[0].previousEncoderSessionID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
    },
    (f) => {
      f.format.receipts[0].acknowledgedAt = 1;
      f.format.receipts[1].acknowledgedAt = 2;
    },
    (f) => {
      f.format.encoderSessions[1].frames--;
    },
  ]) {
    const f = fixture();
    corrupt(f);
    assert.throws(() => qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs));
  }
});

test('acknowledgment follows completion and compressed observation within the owner clock', () => {
  for (const delta of [-0.001, 0.005]) {
    const f = fixture();
    f.format.receipts[0].acknowledgedAt = f.format.encoderSessions[1].firstCompletedAt + delta;
    assert.throws(
      () => qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs),
      delta < 0 ? /precedes native completion/ : /precedes compressed output/,
    );
  }
});

test('new native runs cannot silently qualify legacy evidence without compressed frames', () => {
  const { format, snapshot, liveIDs } = fixture();
  assert.throws(() =>
    qualifyNativeProfileTransitions(format, snapshot, liveIDs, { requireFrameEvidence: true }),
  );
  format.formatVersion = 4;
  assert.throws(() => qualifyNativeProfileTransitions(format, snapshot, liveIDs));
});

test('current full profile evidence requires and returns independently reconciled compressed frames', () => {
  for (const adaptive of [false, true]) {
    const f = fixture(3, adaptive);
    f.format.formatVersion = adaptive ? 5 : 4;
    f.format.compressedFrames = f.format.phases.flatMap((p, phase) =>
      Array.from({ length: p.frames }, (_, n) => ({
        sourcePTS: pts(phase * 900 + n),
        observedAt: p.firstObservedAt + n / 30,
        byteCount: n % 60 === 0 ? 4000 : 1000,
        isSync: n % 60 === 0,
      })),
    );
    const result = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
      adaptive,
      requireFrameEvidence: true,
    });
    assert.equal(result.compressedFrames.frames, 2700);
    f.format.compressedFrames[100].byteCount = 0;
    assert.throws(() =>
      qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
        adaptive,
        requireFrameEvidence: true,
      }),
    );
  }
});

test('minimum transition mode requires the same exclusive full pipeline', () => {
  const minimum = {
    ...options,
    environment: { ...options.environment, SCOREBUG_TEST_PROFILE_TRANSITIONS: 'low240' },
  };
  assert.equal(nativeProfileTransitions(minimum), true);
  for (const flag of ['low360', '240p30', 'low240 '])
    assert.throws(() =>
      nativeProfileTransitions({
        ...minimum,
        environment: { ...minimum.environment, SCOREBUG_TEST_PROFILE_TRANSITIONS: flag },
      }),
    );
  for (const key of [
    'SCOREBUG_TEST_NATIVE_QUALITY',
    'SCOREBUG_TEST_ADAPTIVE_PROFILES',
    'SCOREBUG_TEST_UPLINK_PROFILE',
    'SCOREBUG_TEST_LIVE_PROFILE',
  ])
    assert.throws(() =>
      nativeProfileTransitions({ ...minimum, environment: { ...minimum.environment, [key]: '1' } }),
    );
  assert.throws(() => nativeProfileTransitions({ ...minimum, holdSeconds: 89 }));
});

function minimumFixture() {
  const f = fixture();
  f.format.formatVersion = 6;
  f.format.sequence = 'low240';
  for (const n of [0, 2]) Object.assign(f.format.phases[n], { width: 426, height: 240 });
  Object.assign(f.format.receipts[1], { profile: '240p30', width: 426, height: 240 });
  f.format.compressedFrames = f.format.phases.flatMap((p, phase) =>
    Array.from({ length: p.frames }, (_, n) => ({
      sourcePTS: pts(phase * 900 + n),
      observedAt: p.firstObservedAt + n / 30,
      byteCount: n % 60 === 0 ? 4000 : 1000,
      isSync: n % 60 === 0,
    })),
  );
  return f;
}

test('minimum qualification binds actual startup and return geometry to caller sequence', () => {
  const f = minimumFixture();
  const result = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
    sequence: 'low240',
    requireFrameEvidence: true,
  });
  assert.equal(result.sequence, 'low240');
  assert.deepEqual(
    result.phases.map((p) => [p.width, p.height]),
    [
      [426, 240],
      [960, 540],
      [426, 240],
    ],
  );
  assert.equal(result.compressedFrames.frames, 2700);
  assert.throws(() => qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs));
  assert.throws(() =>
    qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
      sequence: 'low240',
      adaptive: true,
    }),
  );
});

test('minimum qualification rejects mismatched or incomplete proof', () => {
  for (const damage of [
    (f) => {
      f.format.sequence = '1';
    },
    (f) => {
      delete f.format.sequence;
    },
    (f) => {
      f.format.formatVersion = 4;
    },
    (f) => {
      delete f.format.compressedFrames;
    },
    (f) => {
      f.format.phases[0].width = 1920;
    },
    (f) => {
      f.format.phases[2].height = 1080;
    },
    (f) => {
      f.format.receipts[1].profile = '1080p30';
    },
    (f) => {
      f.format.compressedFrames[900].isSync = false;
    },
    (f) => {
      f.liveIDs.splice(900, 20);
    },
  ]) {
    const f = minimumFixture();
    damage(f);
    assert.throws(() =>
      qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, { sequence: 'low240' }),
    );
  }
});

test('stall reset requires exactly two actual native phases 540p then minimum', () => {
  const f = fixture(2);
  f.format.formatVersion = 7;
  f.format.sequence = 'stall540';
  for (const [i, p] of f.format.phases.entries()) {
    p.width = i ? 426 : 960;
    p.height = i ? 240 : 540;
  }
  Object.assign(f.format.receipts[0], { profile: '240p30', width: 426, height: 240 });
  f.format.compressedFrames = f.format.phases.flatMap((p, phase) =>
    Array.from({ length: p.frames }, (_, n) => ({
      sourcePTS: pts(phase * 900 + n),
      observedAt: p.firstObservedAt + n / 30,
      byteCount: 1000,
      isSync: n % 60 === 0,
    })),
  );
  const options = { sequence: 'stall540', requireFrameEvidence: true };
  const result = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, options);
  assert.equal(result.phases.length, 2);
  assert.equal(result.receipts[0].profile, '240p30');
  for (const damage of [
    (x) => (x.format.phases[0].width = 1920),
    (x) => (x.format.phases[1].height = 540),
    (x) => (x.format.receipts[0].profile = '540p30'),
    (x) => (x.format.compressedFrames[900].isSync = false),
    (x) => x.format.phases.push({ ...x.format.phases[1] }),
  ]) {
    const bad = structuredClone(f);
    damage(bad);
    assert.throws(() =>
      qualifyNativeProfileTransitions(bad.format, bad.snapshot, bad.liveIDs, options),
    );
  }
  assert.throws(() => qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs));
});

async function resetProof() {
  const { qualifyNativeStallReset } = await import('../native-stall-reset.mjs');
  const f = fixture(2);
  f.format.formatVersion = 7;
  f.format.sequence = 'stall540';
  f.format.phases.forEach((p, i) =>
    Object.assign(p, { width: i ? 426 : 960, height: i ? 240 : 540 }),
  );
  Object.assign(f.format.receipts[0], {
    profile: '240p30',
    width: 426,
    height: 240,
    acknowledgedAt: 130.02,
  });
  f.format.compressedFrames = f.format.phases.flatMap((p, i) =>
    Array.from({ length: p.frames }, (_, n) => ({
      sourcePTS: pts(i * 900 + n),
      observedAt: p.firstObservedAt + n / 30,
      byteCount: 1000,
      isSync: n % 60 === 0,
    })),
  );
  const oldReceipt = {
    generation: '2',
    encoderSessionID: ids[0],
    configurationID: ids[2],
    bitRate: 1500000,
    acceptedAt: 100.1,
    lastSubmittedPTS: pts(5),
  };
  const newReceipt = {
    ...oldReceipt,
    encoderSessionID: ids[1],
    configurationID: '44444444-4444-4444-8444-444444444444',
    bitRate: 350000,
    acceptedAt: 130.03,
    lastSubmittedPTS: pts(900),
  };
  const signal = {
    scopeID: 'decoder',
    workerID: 'mac',
    workerEpoch: 'epoch',
    workerAttempt: 1,
    readerID: 'reader',
    publishingAttemptID: 'attempt',
    lastFreshPTS: '100',
    sequence: '4',
    revision: '0',
    observedAtLowerBound: 129.5,
  };
  const before = { profileID: '540p30', revision: '0', receipt: oldReceipt, acknowledgedAt: 100.2 };
  const after = {
    profileID: '240p30',
    revision: '1',
    receipt: newReceipt,
    acknowledgedAt: 130.04,
    profileReceipt: f.format.receipts[0],
  };
  const quality = {
    formatVersion: 4,
    overflow: false,
    events: [
      { ...before, kind: 'bootstrap' },
      {
        ...before,
        kind: 'decoderStall',
        state: 'stalled',
        reasons: ['stalled'],
        evaluatedAt: 129.7,
        decoderStall: signal,
      },
      {
        ...after,
        kind: 'applied',
        action: {
          kind: 'reset',
          profileID: '240p30',
          bitRate: 350000,
          fromRevision: '0',
          validUntil: 130.2,
        },
        application: {
          id: ids[2],
          admittedAt: 129.71,
          completionDeadline: 131.71,
          attemptID: 'attempt',
          fromRevision: '0',
          windowSequence: '4',
        },
      },
      { ...after, kind: 'stopped', closed: true },
    ],
  };
  const row = {
    expectedAttempt: 'attempt',
    evaluatedUptime: 129.69,
    sampleAgeSeconds: 0.19,
    observedStall: true,
    response: {
      status: {
        workerId: 'mac',
        workerEpoch: 'epoch',
        publication: { readerId: 'reader', publishingAttemptId: 'attempt' },
        observation: {
          attempt: 1,
          decoderCadence: {
            scopeID: 'decoder',
            progress: { lastFreshPTS: 100, ageMs: 1100, stalled: true },
          },
        },
      },
    },
  };
  const resumed = structuredClone(row);
  resumed.evaluatedUptime = 130.5;
  resumed.observedStall = false;
  resumed.response.status.observation.decoderCadence.progress = {
    lastFreshPTS: 3100,
    ageMs: 20,
    stalled: false,
  };
  const audit = { closed: true, overflow: false, invalid: false, rows: [row, resumed] };
  const fault = {
    closed: true,
    failed: false,
    pauseSentAt: 1,
    resumeSentAt: 1801,
    identity: {
      worker: { pid: 10 },
      guardian: { pid: 11, ppid: 10 },
      decoder: { pid: 12, ppid: 11 },
    },
  };
  return {
    verify: qualifyNativeStallReset,
    input: {
      quality,
      audit,
      fault,
      scope: f.snapshot.scope,
      format: f.format,
      snapshot: f.snapshot,
      liveIDs: f.liveIDs,
    },
  };
}
test('real reset proof binds raw stall, native write deadline and both media phases', async () => {
  const { verify, input } = await resetProof();
  const result = verify(input);
  assert.equal(result.higherProfileResetWriteQualified, true);
  assert(Math.abs(result.nativeApplicationSeconds - 0.33) < 1e-9);
});
for (const [name, damage] of Object.entries({
  wrongOldEncoder: (x) => (x.quality.events[0].receipt.encoderSessionID = ids[2]),
  wrongNewEncoder: (x) => (x.quality.events[2].receipt.encoderSessionID = ids[0]),
  wrongProfileReceipt: (x) =>
    (x.quality.events[2].profileReceipt = { ...x.quality.events[2].profileReceipt, width: 960 }),
  beforeDecision: (x) => (x.quality.events[2].application.admittedAt = 129.6),
  alreadyCompleted: (x) => (x.quality.events[2].application.admittedAt = 130.005),
  futureReceiptPTS: (x) => (x.quality.events[2].receipt.lastSubmittedPTS = pts(60000)),
  lateAck: (x) => (x.quality.events[2].acknowledgedAt = 132),
  wrongGeneration: (x) => (x.quality.events[2].receipt.generation = '3'),
  wrongRate: (x) => (x.quality.events[2].receipt.bitRate = 1500000),
  wrongOrdinal: (x) => (x.quality.events[2].application.windowSequence = '3'),
  wrongAttempt: (x) => (x.quality.events[2].application.attemptID = 'other'),
  noReset: (x) => (x.quality.events[2].action.kind = 'decrease'),
  oldReceiptAfterReset: (x) =>
    (x.quality.events.at(-1).receipt = structuredClone(x.quality.events[0].receipt)),
  stale: (x) => (x.quality.events[1].evaluatedAt = 129.8),
  fabricatedWindow: (x) => (x.quality.events[1].window = {}),
  secondWrite: (x) => x.quality.events.splice(3, 0, structuredClone(x.quality.events[2])),
}))
  test(`reset proof rejects ${name}`, async () => {
    const { verify, input } = await resetProof();
    damage(input);
    assert.throws(() => verify(input));
  });

function measuredFixture(phaseCount = 3) {
  const f = fixture(phaseCount);
  f.format.formatVersion = 8;
  f.format.sequence = 'measured240';
  for (const [i, phase] of f.format.phases.entries()) {
    phase.width = i === 1 ? 640 : 426;
    phase.height = i === 1 ? 360 : 240;
  }
  f.format.receipts.forEach((r, i) => {
    r.profile = i === 0 ? '360p30' : '240p30';
    r.width = f.format.phases[i + 1].width;
    r.height = f.format.phases[i + 1].height;
  });
  f.format.compressedFrames = f.format.phases.flatMap((p, phase) =>
    Array.from({ length: p.frames }, (_, n) => ({
      sourcePTS: pts(phase * 900 + n),
      observedAt: p.firstObservedAt + n / 30,
      byteCount: n % 60 === 0 ? 4000 : 1000,
      isSync: n % 60 === 0,
    })),
  );
  return f;
}
const measuredOptions = { sequence: 'measured240', requireFrameEvidence: true };
test('measured format evidence distinguishes unchanged, upgraded and reset without trial permission', () => {
  for (const count of [1, 2, 3]) {
    const f = measuredFixture(count);
    const result = qualifyNativeProfileTransitions(
      f.format,
      f.snapshot,
      f.liveIDs,
      measuredOptions,
    );
    assert.deepEqual(
      result.phases.map((p) => p.height),
      [240, 360, 240].slice(0, count),
    );
    assert.equal(result.trialConfirmed, false);
    assert.equal(result.upgradeAuthorized, false);
    assert.throws(() => qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs));
    assert.throws(() =>
      qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
        ...measuredOptions,
        adaptive: true,
      }),
    );
  }
});
test('measured sequence requires exact complete native format and receipt evidence', () => {
  for (const corrupt of [
    (f) => {
      f.format.formatVersion = 6;
    },
    (f) => {
      f.format.sequence = 'low240';
    },
    (f) => {
      f.format.phases[1].height = 540;
    },
    (f) => {
      f.format.phases[0].width = 640;
    },
    (f) => {
      f.format.receipts[0].profile = '540p30';
    },
    (f) => {
      f.format.receipts.pop();
    },
    (f) => {
      f.format.compressedFrames.shift();
    },
    (f) => {
      f.format.compressedFrames[900].isSync = false;
    },
    (f) => {
      f.format.encoderSessions[1].encoderSessionID = f.format.encoderSessions[0].encoderSessionID;
    },
    (f) => {
      f.liveIDs.splice(f.liveIDs.indexOf(900), 1);
    },
  ]) {
    const f = measuredFixture();
    corrupt(f);
    assert.throws(() =>
      qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, measuredOptions),
    );
  }
  const f = measuredFixture(4);
  assert.throws(() =>
    qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, measuredOptions),
  );
});

test('measured unchanged baseline still requires a valid native encoder identity', () => {
  const f = measuredFixture(1);
  f.format.encoderSessions[0].encoderSessionID = 'unknown';
  assert.throws(() =>
    qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, measuredOptions),
  );
});
test('short measured rollback phase is observable but cannot claim ten-second confirmation', () => {
  const f = measuredFixture(2);
  const p = f.format.phases[1],
    e = f.format.encoderSessions[1];
  p.frames = e.frames = 150;
  p.lastSourcePTS = e.lastSourcePTS = pts(1049);
  p.lastObservedAt = p.firstObservedAt + 149 / 30;
  e.lastCompletedAt = e.firstCompletedAt + 149 / 30;
  f.format.frames = 1050;
  f.format.compressedFrames = f.format.compressedFrames.slice(0, 1050);
  f.snapshot.completed[0].encodedVideo.callbackCount = '1050';
  f.snapshot.completed[0].encodedVideo.lastSourcePTS = pts(1049);
  f.liveIDs = f.liveIDs.filter((id) => id <= 1049);
  const result = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, measuredOptions);
  assert.equal(result.phases[1].nativeFrames, 150);
  assert.equal(result.trialConfirmed, false);
  assert.equal(result.upgradeAuthorized, false);
});

function singleFrameTrialFixture() {
  const f = measuredFixture(3);
  const trial = f.format.phases[1],
    encoder = f.format.encoderSessions[1];
  trial.frames = encoder.frames = 1;
  trial.lastSourcePTS = encoder.lastSourcePTS = pts(900);
  trial.lastObservedAt = trial.firstObservedAt;
  encoder.lastCompletedAt = encoder.firstCompletedAt;
  trial.maximumSourceGapSeconds =
    trial.maximumObservationGapSeconds =
    encoder.maximumCompletionGapSeconds =
      0;
  const tail = f.format.phases[2],
    tailEncoder = f.format.encoderSessions[2];
  tail.firstSourcePTS = tailEncoder.firstSourcePTS = pts(901);
  tail.lastSourcePTS = tailEncoder.lastSourcePTS = pts(1800);
  tail.firstObservedAt = 100.01 + 901 / 30;
  tail.lastObservedAt = tail.firstObservedAt + 899 / 30;
  tailEncoder.firstCompletedAt = 100 + 901 / 30;
  tailEncoder.lastCompletedAt = 100 + 1800 / 30;
  f.format.receipts[0].acknowledgedAt = 130.02;
  Object.assign(f.format.receipts[1], {
    lastOldSourcePTS: pts(900),
    firstNewSourcePTS: pts(901),
    acknowledgedAt: tail.firstObservedAt + 0.01,
  });
  f.format.compressedFrames = f.format.compressedFrames.slice(0, 901).concat(
    Array.from({ length: 900 }, (_, n) => ({
      sourcePTS: pts(901 + n),
      observedAt: tail.firstObservedAt + n / 30,
      byteCount: 1000,
      isSync: n % 60 === 0,
    })),
  );
  f.format.frames = 1801;
  f.snapshot.completed[0].encodedVideo.callbackCount = '1801';
  f.snapshot.completed[0].encodedVideo.lastSourcePTS = pts(1800);
  f.liveIDs = f.liveIDs.filter((id) => id <= 1800);
  return f;
}
test('single-frame measured trial followed by reset remains format-only evidence', () => {
  const f = singleFrameTrialFixture();
  const result = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, measuredOptions);
  assert.deepEqual(
    result.phases.map((p) => p.nativeFrames),
    [900, 1, 900],
  );
  assert.equal(result.trialConfirmed, false);
  assert.equal(result.mediaHealthQualified, false);
  assert.equal(result.upgradeAuthorized, false);
  f.format.compressedFrames[900].isSync = false;
  assert.throws(() =>
    qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, measuredOptions),
  );
});
test('measured sequence cannot invoke scheduled transition CLI route', () => {
  assert.throws(() =>
    nativeProfileTransitions({
      ...options,
      environment: { ...options.environment, SCOREBUG_TEST_PROFILE_TRANSITIONS: 'measured240' },
    }),
  );
});

function repeatedMeasuredFixture() {
  const f = measuredFixture(5);
  f.format.formatVersion = 9;
  f.format.sequence = 'repeated240';
  f.format.phases.forEach((phase, i) => {
    phase.width = i % 2 ? 640 : 426;
    phase.height = i % 2 ? 360 : 240;
  });
  f.format.receipts.forEach((receipt, i) => {
    receipt.profile = i % 2 ? '240p30' : '360p30';
    receipt.width = f.format.phases[i + 1].width;
    receipt.height = f.format.phases[i + 1].height;
  });
  return f;
}
const repeatedMeasuredOptions = { sequence: 'repeated240', requireFrameEvidence: true };
test('repeated measured media proves all five original phases without policy permission', () => {
  const f = repeatedMeasuredFixture();
  const result = qualifyNativeProfileTransitions(
    f.format,
    f.snapshot,
    f.liveIDs,
    repeatedMeasuredOptions,
  );
  assert.deepEqual(
    result.phases.map((p) => p.height),
    [240, 360, 240, 360, 240],
  );
  assert.equal(result.compressedFrames.frames, 4500);
  assert.equal(result.trialConfirmed, false);
  assert.equal(result.upgradeAuthorized, false);
  assert.throws(() =>
    qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, measuredOptions),
  );
  assert.throws(() =>
    qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
      ...repeatedMeasuredOptions,
      adaptive: true,
    }),
  );
});
for (const [name, damage] of [
  ['old version', (f) => (f.format.formatVersion = 8)],
  ['old sequence', (f) => (f.format.sequence = 'measured240')],
  ['missing final phase', (f) => f.format.phases.pop()],
  ['sixth phase', (f) => f.format.phases.push({ ...f.format.phases.at(-1) })],
  ['second upgrade dimensions', (f) => (f.format.phases[3].width = 426)],
  ['second upgrade receipt', (f) => (f.format.receipts[2].profile = '240p30')],
  ['reset receipt ownership', (f) => (f.format.receipts[3].previousEncoderSessionID = ids[0])],
  ['reused encoder', (f) => (f.format.encoderSessions[3].encoderSessionID = ids[1])],
  ['missing second sync', (f) => (f.format.compressedFrames[2700].isSync = false)],
  ['missing second decoded boundary', (f) => f.liveIDs.splice(f.liveIDs.indexOf(2700), 1)],
  ['missing final decoded tail', (f) => f.liveIDs.pop()],
])
  test(`repeated measured media rejects ${name}`, () => {
    const f = repeatedMeasuredFixture();
    damage(f);
    assert.throws(() =>
      qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, repeatedMeasuredOptions),
    );
  });

function ownedMeasuredFixture() {
  const f = measuredFixture(4);
  f.format.formatVersion = 10;
  f.format.sequence = 'owned240';
  f.format.phases.forEach((phase, i) => {
    phase.width = i % 2 ? 640 : 426;
    phase.height = i % 2 ? 360 : 240;
  });
  f.format.receipts.forEach((receipt, i) => {
    receipt.profile = i % 2 ? '240p30' : '360p30';
    receipt.width = f.format.phases[i + 1].width;
    receipt.height = f.format.phases[i + 1].height;
  });
  return f;
}
const ownedMeasuredOptions = { sequence: 'owned240', requireFrameEvidence: true };
test('owned recovery requires the whole four-phase media history without claiming policy success', () => {
  const f = ownedMeasuredFixture();
  const result = qualifyNativeProfileTransitions(
    f.format,
    f.snapshot,
    f.liveIDs,
    ownedMeasuredOptions,
  );
  assert.deepEqual(
    result.phases.map((p) => p.height),
    [240, 360, 240, 360],
  );
  assert.equal(result.compressedFrames.frames, 3600);
  assert.equal(result.trialConfirmed, false);
  assert.equal(result.upgradeAuthorized, false);
  for (const options of [
    measuredOptions,
    repeatedMeasuredOptions,
    { ...ownedMeasuredOptions, adaptive: true },
  ])
    assert.throws(() => qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, options));
});
for (const [name, damage] of [
  [
    'historical version',
    (f) => {
      f.format.formatVersion = 8;
    },
  ],
  [
    'historical sequence',
    (f) => {
      f.format.sequence = 'measured240';
    },
  ],
  [
    'missing recovery phase',
    (f) => {
      f.format.phases.pop();
    },
  ],
  [
    'extra reset',
    (f) => {
      f.format.phases.push({ ...f.format.phases.at(-1) });
    },
  ],
  [
    'wrong recovery dimensions',
    (f) => {
      f.format.phases[3].width = 426;
    },
  ],
  [
    'wrong recovery receipt',
    (f) => {
      f.format.receipts[2].profile = '240p30';
    },
  ],
  [
    'reused native encoder',
    (f) => {
      f.format.encoderSessions[3].encoderSessionID = ids[1];
    },
  ],
  [
    'missing recovery sync',
    (f) => {
      f.format.compressedFrames[2700].isSync = false;
    },
  ],
  [
    'missing recovery frame',
    (f) => {
      f.liveIDs.splice(f.liveIDs.indexOf(2700), 1);
    },
  ],
  [
    'missing final tail',
    (f) => {
      f.liveIDs.pop();
    },
  ],
])
  test(`owned recovery media rejects ${name}`, () => {
    const f = ownedMeasuredFixture();
    damage(f);
    assert.throws(() =>
      qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, ownedMeasuredOptions),
    );
  });
