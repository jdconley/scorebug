import test from 'node:test';
import assert from 'node:assert/strict';
import {
  nativeProfileTransitions,
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
function fixture() {
  const scope = {
    recordingID: 'recording',
    matchID: 'match',
    broadcastGeneration: 1,
    publishingAttemptID: 'attempt',
    appliedProfileRevision: '1',
  };
  const phases = [0, 1, 2].map((n) => ({
    width: n === 1 ? 960 : 1920,
    height: n === 1 ? 540 : 1080,
    frames: 900,
    firstSourcePTS: pts(n * 900),
    lastSourcePTS: pts(n * 900 + 899),
    maximumSourceGapSeconds: 1 / 30,
    firstObservedAt: 100.01 + n * 30,
    lastObservedAt: 100.01 + n * 30 + 899 / 30,
    maximumObservationGapSeconds: 1 / 30,
  }));
  const format = {
    formatVersion: 2,
    scope,
    isClosed: true,
    invalid: false,
    frames: 2700,
    publishingGeneration: '2',
    phases,
    encoderSessions: phases.map((p, n) => ({
      encoderSessionID: ids[n],
      frames: p.frames,
      firstSourcePTS: p.firstSourcePTS,
      lastSourcePTS: p.lastSourcePTS,
      firstCompletedAt: 100 + n * 30,
      lastCompletedAt: 100 + n * 30 + 899 / 30,
      maximumCompletionGapSeconds: 1 / 30,
      maximumEncodeLatencySeconds: 0.2,
    })),
    receipts: [1, 2].map((n) => ({
      profile: n === 1 ? '540p30' : '1080p30',
      publishingGeneration: '2',
      previousEncoderSessionID: ids[n - 1],
      encoderSessionID: ids[n],
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
    captureDetachedAt: 191,
    omittedCompletedWindowCount: '0',
    publishingClockObservation: { publishingGeneration: '2' },
    completed: [
      { encodedVideo: { callbackCount: '2700', firstSourcePTS: pts(0), lastSourcePTS: pts(2699) } },
    ],
    current: { encodedVideo: { callbackCount: '0' } },
  };
  return { format, snapshot, liveIDs: Array.from({ length: 2670 }, (_, n) => n + 30) };
}
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
