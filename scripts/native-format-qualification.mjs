import assert from 'node:assert/strict';
import { nativeMediaGeometry } from './native-live-profile.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
/** Actual pre-mux sample format, independent of the worker's resize operation. */
export function qualifyNativeFormat(format, snapshot, profile, { requireStartup = false } = {}) {
  assert.ok(['540p30', '360p30', '240p30'].includes(profile));
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
  let startup;
  if (requireStartup) {
    startup = format.startup;
    const encoded = format.firstEncoding,
      compressed = format.firstCompressed;
    assert.ok(startup && encoded && compressed, 'Missing first-frame startup evidence');
    assert.equal(startup.profile, profile);
    assert.equal(startup.width, geometry.width);
    assert.equal(startup.height, geometry.height);
    assert.equal(startup.publishingGeneration, format.publishingGeneration);
    assert.match(
      startup.encoderSessionID,
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    );
    assert.equal(startup.encoderSessionID, encoded.encoderSessionID);
    for (const pts of [
      startup.firstSourcePTS,
      encoded.sourcePTS,
      encoded.outputPTS,
      compressed.sourcePTS,
    ]) {
      assert.equal(fixtureFrameID(pts), first, 'Startup must describe the very first native frame');
    }
    for (const [field, actual] of [
      ['submittedAt', encoded.submittedAt],
      ['completedAt', encoded.completedAt],
      ['observedAt', compressed.dequeuedAt],
    ]) {
      assert.ok(Number.isFinite(actual) && actual >= 0 && actual <= 1e12);
      assert.equal(startup[field], actual);
    }
    assert.ok(
      startup.submittedAt <= startup.completedAt && startup.completedAt <= startup.observedAt,
    );
    assert.equal(compressed.publishingGeneration, startup.publishingGeneration);
    assert.equal(compressed.width, startup.width);
    assert.equal(compressed.height, startup.height);
    assert.equal(compressed.valid, true);
    assert.equal(compressed.wasEncoded, true);
    assert.equal(compressed.codec, 0x61766331);
    assert.equal(compressed.isSync, true);
    assert.ok(Number.isSafeInteger(compressed.bytes) && compressed.bytes > 0);
  }
  return {
    ...(requireStartup ? { startup } : {}),
    width: format.width,
    height: format.height,
    frames: format.frames,
    firstFrame: first,
    lastFrame: last,
    publishingGeneration: format.publishingGeneration,
    scope: format.scope,
  };
}
