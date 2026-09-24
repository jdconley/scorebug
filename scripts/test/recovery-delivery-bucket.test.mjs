import test from 'node:test';
import assert from 'node:assert/strict';
const { qualifyRecoveryDeliveryBucket } = await import('../recovery-delivery-bucket.mjs').catch(
  (error) => {
    if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
    return {};
  },
);
const result = (frames) => ({
  expectedFrames: frames,
  onTimeFrames: frames,
  lateFrames: 0,
  missingFrames: 0,
  uncertainFrames: 0,
});
test('lossless short buckets allow only one frame of boundary tolerance', () => {
  assert.equal(typeof qualifyRecoveryDeliveryBucket, 'function');
  for (const [duration, counts] of [
    [1, [29, 30, 31]],
    [2, [59, 60, 61]],
  ])
    for (const frames of counts)
      assert.equal(qualifyRecoveryDeliveryBucket(result(frames), duration), true);
});
test('bucket tolerance cannot hide weak cadence, any delivery loss, or malformed counts', () => {
  assert.equal(typeof qualifyRecoveryDeliveryBucket, 'function');
  for (const [duration, frames] of [
    [1, 28],
    [2, 58],
    [1, 24],
    [2, 48],
    [0, 30],
    [3, 90],
    [NaN, 30],
  ])
    assert.throws(() => qualifyRecoveryDeliveryBucket(result(frames), duration));
  for (const key of ['lateFrames', 'missingFrames', 'uncertainFrames']) {
    const r = result(30);
    r[key] = 1;
    r.onTimeFrames--;
    assert.throws(() => qualifyRecoveryDeliveryBucket(r, 1));
  }
  for (const r of [
    result(29.5),
    result(Infinity),
    result(241),
    { ...result(30), expectedFrames: 31 },
    { ...result(30), missingFrames: -1 },
    { ...result(30), onTimeFrames: '30' },
  ])
    assert.throws(() => qualifyRecoveryDeliveryBucket(r, 1));
});
