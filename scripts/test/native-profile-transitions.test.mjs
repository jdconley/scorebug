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
