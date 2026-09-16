import assert from 'node:assert/strict';
import { nativeMediaGeometry } from './native-live-profile.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
/** Actual pre-mux sample format, independent of the worker's resize operation. */
export function qualifyNativeFormat(format, snapshot, profile) {
  assert.ok(['540p30', '360p30'].includes(profile));
  const geometry = nativeMediaGeometry(profile, true);
  assert.equal(format.formatVersion, 1);
  assert.equal(format.profile, profile);
  assert.equal(format.isClosed, true);
  assert.equal(format.invalid, false);
  assert.deepEqual(format.scope, snapshot.scope);
  assert.equal(snapshot.isClosed, true);
  assert.equal(
    format.publishingGeneration,
    snapshot.publishingClockObservation.publishingGeneration,
  );
  assert.equal(format.width, geometry.width);
  assert.equal(format.height, geometry.height);
  assert.ok(Number.isSafeInteger(format.frames) && format.frames > 0 && format.frames <= 25000);
  assert.equal(snapshot.omittedCompletedWindowCount, '0');
  const rows = [...snapshot.completed, snapshot.current]
    .map((w) => w.encodedVideo)
    .filter((r) => BigInt(r.callbackCount) > 0n);
  const frames = rows.reduce((sum, r) => sum + BigInt(r.callbackCount), 0n);
  assert.equal(
    BigInt(format.frames),
    frames,
    'Pre-mux format must cover every native encoded frame',
  );
  const first = fixtureFrameID(format.firstSourcePTS),
    last = fixtureFrameID(format.lastSourcePTS);
  assert.equal(first, Math.min(...rows.map((r) => fixtureFrameID(r.firstSourcePTS))));
  assert.equal(last, Math.max(...rows.map((r) => fixtureFrameID(r.lastSourcePTS))));
  return {
    width: format.width,
    height: format.height,
    frames: format.frames,
    firstFrame: first,
    lastFrame: last,
    publishingGeneration: format.publishingGeneration,
    scope: format.scope,
  };
}
