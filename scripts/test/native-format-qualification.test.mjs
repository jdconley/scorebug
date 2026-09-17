import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyNativeFormat } from '../native-format-qualification.mjs';
const pts = (n) => ({ value: String(7395 + 2 * n), timescale: 60, epoch: '0', flags: 1 });
const scope = {
  recordingID: 'owned',
  matchID: 'owned',
  broadcastGeneration: 1,
  publishingAttemptID: 'owned',
  appliedProfileRevision: '1',
};
const snapshot = {
  scope,
  isClosed: true,
  omittedCompletedWindowCount: '0',
  publishingClockObservation: { publishingGeneration: '2' },
  completed: [
    { encodedVideo: { callbackCount: '10', firstSourcePTS: pts(1), lastSourcePTS: pts(10) } },
  ],
  current: { encodedVideo: { callbackCount: '0' } },
};
const format = {
  formatVersion: 1,
  profile: '540p30',
  scope,
  isClosed: true,
  invalid: false,
  publishingGeneration: '2',
  width: 960,
  height: 540,
  frames: 10,
  firstSourcePTS: pts(1),
  lastSourcePTS: pts(10),
};
test('requires every actual pre-mux frame and its scope, not worker-scaled dimensions', () => {
  assert.equal(qualifyNativeFormat(format, snapshot, '540p30').frames, 10);
  for (const patch of [
    { width: 1920, height: 1080 },
    { invalid: true },
    { frames: 9 },
    { scope: { ...scope, publishingAttemptID: 'other' } },
    { publishingGeneration: '3' },
    { firstSourcePTS: pts(2) },
    { lastSourcePTS: pts(9) },
    { isClosed: false },
  ])
    assert.throws(() => qualifyNativeFormat({ ...format, ...patch }, snapshot, '540p30'));
  assert.throws(() =>
    qualifyNativeFormat(format, { ...snapshot, omittedCompletedWindowCount: '1' }, '540p30'),
  );
});

test('fixed360 requires actual native360 dimensions and exact profile identity', () => {
  const low = { ...format, profile: '360p30', width: 640, height: 360 };
  assert.equal(qualifyNativeFormat(low, snapshot, '360p30').width, 640);
  assert.throws(() => qualifyNativeFormat({ ...low, width: 960, height: 540 }, snapshot, '360p30'));
  assert.throws(() => qualifyNativeFormat(low, snapshot, '540p30'));
});

test('fixed240 requires actual native240 dimensions and exact profile identity', () => {
  const low = { ...format, profile: '240p30', width: 426, height: 240 };
  assert.equal(qualifyNativeFormat(low, snapshot, '240p30').width, 426);
  assert.throws(() => qualifyNativeFormat({ ...low, width: 960, height: 540 }, snapshot, '240p30'));
  assert.throws(() => qualifyNativeFormat(low, snapshot, '540p30'));
});

test('startup requires the actual first encoder and compressed callback join', () => {
  const firstEncoding = {
    sourcePTS: pts(1),
    outputPTS: pts(1),
    encoderSessionID: '11111111-1111-4111-8111-111111111111',
    submittedAt: 10,
    completedAt: 10.1,
  };
  const firstCompressed = {
    sourcePTS: pts(1),
    publishingGeneration: '2',
    width: 960,
    height: 540,
    valid: true,
    wasEncoded: true,
    codec: 0x61766331,
    bytes: 100,
    isSync: true,
    dequeuedAt: 10.2,
  };
  const startup = {
    profile: '540p30',
    width: 960,
    height: 540,
    publishingGeneration: '2',
    encoderSessionID: firstEncoding.encoderSessionID,
    firstSourcePTS: pts(1),
    submittedAt: 10,
    completedAt: 10.1,
    observedAt: 10.2,
  };
  const value = { ...format, firstEncoding, firstCompressed, startup };
  assert.deepEqual(
    qualifyNativeFormat(value, snapshot, '540p30', { requireStartup: true }).startup,
    startup,
  );
  for (const patch of [
    { startup: null },
    { firstEncoding: null },
    { firstCompressed: null },
    { startup: { ...startup, encoderSessionID: 'other' } },
    { startup: { ...startup, publishingGeneration: '3' } },
    { startup: { ...startup, profile: '240p30' } },
    { startup: { ...startup, firstSourcePTS: pts(2) } },
    { startup: { ...startup, observedAt: 11 } },
    { firstEncoding: { ...firstEncoding, outputPTS: pts(2) } },
    { firstEncoding: { ...firstEncoding, completedAt: 10.3 } },
    { firstCompressed: { ...firstCompressed, isSync: false } },
    { firstCompressed: { ...firstCompressed, codec: 0 } },
    { firstCompressed: { ...firstCompressed, bytes: 0 } },
    { firstCompressed: { ...firstCompressed, width: 1920 } },
  ]) {
    assert.throws(() =>
      qualifyNativeFormat({ ...value, ...patch }, snapshot, '540p30', { requireStartup: true }),
    );
  }
});
