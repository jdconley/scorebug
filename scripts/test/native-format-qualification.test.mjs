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
