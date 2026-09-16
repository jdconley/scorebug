import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';
const finite = (n) => Number.isFinite(n) && n >= 0 && n <= 1e12;
const uuid = (s) =>
  typeof s === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(s);
const near = (a, b) => assert.ok(finite(a) && finite(b) && Math.abs(a - b) < 1e-6, `${a} != ${b}`);
function uint(s) {
  assert.ok(typeof s === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(s));
  const n = BigInt(s);
  assert.ok(n <= 18446744073709551615n);
  return n;
}
/** Reconstructs cost from separately retained actual encoder/output callbacks.
 * Worker re-encoding changes bytes; this does not equate destination payload with
 * publisher payload, or turn current/historical cost into candidate capacity. */
export function qualifyNativeVideoCost(proof, format) {
  assert.equal(proof.formatVersion, 1);
  assert.equal(proof.isClosed, true);
  assert.equal(proof.invalidReason, null);
  assert.equal(proof.profile, '540p30');
  assert.deepEqual(proof.scope, format.scope);
  for (const rows of [proof.compressed, proof.encoded])
    assert.ok(Array.isArray(rows) && rows.length > 0 && rows.length <= 1024);
  assert.equal(proof.compressed.length, proof.encoded.length);
  assert.ok(
    Array.isArray(proof.intervals) && proof.intervals.length > 0 && proof.intervals.length <= 8,
  );
  // This fixture uses one fixed encoder profile and consecutive 30 Hz source
  // frames. Its first pre-mux frame anchors every two-second cost boundary.
  assert.equal(format.frames, format.lastFrame - format.firstFrame + 1);
  assert.equal(proof.compressed.length, Math.min(1024, format.frames));
  const completedWindows = Math.floor((format.lastFrame - format.firstFrame) / 60);
  assert.equal(proof.intervals.length, Math.min(8, completedWindows));
  proof.intervals.forEach((w, index) => {
    const sequence = completedWindows - proof.intervals.length + index + 1;
    assert.equal(uint(w.sequence), BigInt(sequence));
    assert.equal(fixtureFrameID(w.sourceStartExclusive), format.firstFrame + (sequence - 1) * 60);
    assert.equal(fixtureFrameID(w.sourceEndInclusive), format.firstFrame + sequence * 60);
  });
  const encoded = new Map();
  for (const e of proof.encoded) {
    const id = fixtureFrameID(e.sourcePTS);
    assert.equal(id, fixtureFrameID(e.outputPTS));
    assert.ok(!encoded.has(id));
    assert.ok(uuid(e.encoderSessionID));
    assert.ok(e.configurationID === null || uuid(e.configurationID));
    assert.equal(e.configurationID === null, e.configuredBitRate === null);
    if (e.configurationID !== null)
      assert.ok(
        Number.isSafeInteger(e.configuredBitRate) &&
          e.configuredBitRate > 0 &&
          e.configuredBitRate <= 2147483647,
      );
    assert.ok(finite(e.submittedAt) && finite(e.completedAt) && e.submittedAt <= e.completedAt);
    encoded.set(id, e);
  }
  const joined = new Map();
  let previous;
  for (const c of proof.compressed) {
    const id = fixtureFrameID(c.sourcePTS),
      e = encoded.get(id);
    assert.ok(e);
    assert.ok(!joined.has(id));
    assert.ok(id >= format.firstFrame && id <= format.lastFrame);
    assert.equal(c.publishingGeneration, format.publishingGeneration);
    assert.ok(uint(c.publishingGeneration) > 0n);
    assert.equal(c.width, format.width);
    assert.equal(c.height, format.height);
    assert.equal(c.codec, 1635148593);
    assert.equal(c.valid, true);
    assert.equal(c.wasEncoded, true);
    assert.ok(Number.isSafeInteger(c.bytes) && c.bytes > 0 && c.bytes <= 16 * 1024 * 1024);
    assert.ok(finite(c.dequeuedAt) && c.dequeuedAt >= e.completedAt);
    if (previous) {
      assert.equal(id, previous.id + 1);
      assert.ok(c.dequeuedAt >= previous.c.dequeuedAt && e.submittedAt > previous.e.submittedAt);
    }
    joined.set(id, { c, e, id });
    previous = { c, e, id };
  }
  assert.equal(previous.id, format.lastFrame);
  let priorWindow,
    total = 0,
    maximum = 0;
  for (const w of proof.intervals) {
    const start = fixtureFrameID(w.sourceStartExclusive),
      end = fixtureFrameID(w.sourceEndInclusive),
      anchor = joined.get(start),
      last = joined.get(end);
    assert.ok(anchor && last && end > start);
    assert.equal(w.usable, true);
    assert.ok(uint(w.sequence) > 0n);
    if (priorWindow) {
      assert.equal(uint(w.sequence), uint(priorWindow.sequence) + 1n);
      assert.equal(start, fixtureFrameID(priorWindow.sourceEndInclusive));
    }
    assert.equal(w.publishingGeneration, format.publishingGeneration);
    assert.equal(w.width, format.width);
    assert.equal(w.height, format.height);
    assert.equal(w.encoderSessionID, anchor.e.encoderSessionID);
    assert.equal(w.configurationID, anchor.e.configurationID);
    assert.equal(w.configuredBitRate, anchor.e.configuredBitRate);
    let bytes = 0,
      maxFrame = 0,
      latency = 0;
    for (let id = start + 1; id <= end; id++) {
      const v = joined.get(id);
      assert.ok(v);
      assert.equal(v.e.encoderSessionID, w.encoderSessionID);
      assert.equal(v.e.configurationID, w.configurationID);
      assert.equal(v.e.configuredBitRate, w.configuredBitRate);
      bytes += v.c.bytes;
      maxFrame = Math.max(maxFrame, v.c.bytes);
      latency = Math.max(latency, v.c.dequeuedAt - v.e.submittedAt);
    }
    assert.ok(bytes <= 64 * 1024 * 1024 && end - start <= 256);
    assert.equal(uint(w.payloadBytes), BigInt(bytes));
    assert.equal(w.maximumFrameBytes, maxFrame);
    assert.equal(w.frames, end - start);
    near(w.submissionStart, anchor.e.submittedAt);
    near(w.submissionEnd, last.e.submittedAt);
    near(w.observedAt, last.c.dequeuedAt);
    near(w.sourceDuration, (end - start) / 30);
    near(w.submissionDuration, last.e.submittedAt - anchor.e.submittedAt);
    near(w.maximumLatency, latency);
    near(w.maximumSourceGap, 1 / 30);
    assert.ok(
      w.sourceDuration >= 2 &&
        w.sourceDuration <= 2.25 &&
        w.submissionDuration > 0 &&
        w.submissionDuration <= 2.25,
    );
    assert.ok(w.frames / Math.max(w.sourceDuration, w.submissionDuration) >= 24 && latency <= 1.5);
    const rate = (bytes * 8) / Math.min(w.sourceDuration, w.submissionDuration);
    near(w.payloadBitsPerSecond, rate);
    total += bytes;
    maximum = Math.max(maximum, rate);
    priorWindow = w;
  }
  return {
    intervalCount: proof.intervals.length,
    payloadBytes: total,
    maximumPayloadBitsPerSecond: maximum,
    usableCapacity: false,
  };
}
