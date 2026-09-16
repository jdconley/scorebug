import assert from 'node:assert/strict';

const integer = (value, min, max) => {
  assert.equal(typeof value, 'string');
  assert.match(value, /^-?(0|[1-9][0-9]*)$/);
  const result = BigInt(value);
  assert.equal(String(result), value);
  assert.ok(result >= min && result <= max);
  return result;
};
const uint64 = (value) => integer(value, 1n, (1n << 64n) - 1n);
const time = (value) => {
  assert.ok(value && typeof value === 'object');
  const numerator = integer(value.value, -(1n << 63n), (1n << 63n) - 1n);
  assert.ok(
    Number.isInteger(value.timescale) && value.timescale > 0 && value.timescale <= 2147483647,
  );
  assert.equal(value.epoch, '0');
  assert.ok(value.flags === 1 || value.flags === 3);
  return { n: numerator, d: BigInt(value.timescale) };
};
const sameTime = (a, b) => a.n * b.d === b.n * a.d;
const uptime = (value) =>
  assert.ok(typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12);
const uuid = (value) => {
  assert.equal(typeof value, 'string');
  assert.match(value, /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
};

/** Finite 14-second fixture only. Submission configuration is not achieved per-frame bitrate. */
export function qualifyEncoderConfiguration({ clock, receipt, evidence, decodedSourceFrames }) {
  assert.ok(receipt && evidence);
  assert.equal(uint64(receipt.publishingGeneration), uint64(clock.publishingGeneration));
  assert.equal(evidence.overflow, false);
  assert.ok(Array.isArray(evidence.frames));
  assert.equal(evidence.frames.length, 420);
  assert.deepEqual(
    decodedSourceFrames,
    Array.from({ length: 420 }, (_, i) => i),
    'Decoded media must retain all fixture identities',
  );
  const configuration = receipt.configuration;
  uuid(configuration.id);
  uuid(configuration.encoderSessionID);
  assert.equal(configuration.bitRate, 2000000);
  uptime(receipt.acceptedAt);
  const origin = time(clock.sourceOrigin);
  const indexFor = (value) => {
    const pts = time(value);
    const delta = pts.n * origin.d - origin.n * pts.d;
    const denominator = pts.d * origin.d;
    assert.ok(delta >= 0n);
    const index = (delta * 30n + denominator / 2n) / denominator;
    assert.ok(index >= 0n && index < 420n);
    const error = delta * 30n - index * denominator;
    // The offset fixture explicitly rounds source CMTime to nanoseconds.
    assert.ok(
      (error < 0n ? -error : error) * 1000000000n <= 30n * denominator,
      'Source PTS is off fixture cadence',
    );
    return Number(index);
  };
  const lastOld = indexFor(receipt.lastSubmittedSourcePTS);
  assert.ok(lastOld >= 0 && lastOld < 419, 'Boundary must have frames on both sides');
  const seen = new Set();
  for (const frame of evidence.frames) {
    const index = indexFor(frame.sourcePTS);
    assert.ok(!seen.has(index), 'Duplicate native source frame');
    seen.add(index);
    assert.ok(
      sameTime(time(frame.sourcePTS), time(frame.outputPTS)),
      'Native output changed source PTS',
    );
    assert.equal(frame.encoderSessionID, configuration.encoderSessionID);
    uptime(frame.submittedAt);
    uptime(frame.completedAt);
    assert.ok(frame.completedAt >= frame.submittedAt);
    if (index <= lastOld) {
      assert.equal(frame.configuration, null, 'Pre-write frame was relabeled');
      assert.ok(frame.submittedAt <= receipt.acceptedAt);
    } else {
      assert.deepEqual(frame.configuration, configuration);
      assert.ok(frame.submittedAt >= receipt.acceptedAt);
    }
    if (index === lastOld)
      assert.ok(
        sameTime(time(frame.sourcePTS), time(receipt.lastSubmittedSourcePTS)),
        'Receipt must name an actual submitted PTS',
      );
  }
  return {
    frames: seen.size,
    publishingGeneration: receipt.publishingGeneration,
    configuration: structuredClone(configuration),
    lastUnverifiedSourceFrame: lastOld,
    firstVerifiedSourceFrame: lastOld + 1,
    acceptedAt: receipt.acceptedAt,
    scope: 'Verified configuration at native submission; rate convergence measured separately',
  };
}
