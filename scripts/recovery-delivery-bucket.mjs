import assert from 'node:assert/strict';

/** One frame may cross an adjacent host-clock bucket boundary. This delivery
 * prerequisite cannot replace independently qualified >=29.7fps source health,
 * contiguous lanes, ownership, freshness or ten seconds of shared coverage. */
export function qualifyRecoveryDeliveryBucket(result, duration) {
  assert([1, 2].includes(duration), 'Unsupported recovery delivery duration');
  assert(
    result &&
      Number.isSafeInteger(result.expectedFrames) &&
      result.expectedFrames >= 1 &&
      result.expectedFrames <= 240,
    'Invalid recovery frame count',
  );
  assert.equal(result.onTimeFrames, result.expectedFrames, 'Incomplete recovery delivery');
  for (const key of ['lateFrames', 'missingFrames', 'uncertainFrames'])
    assert.equal(result[key], 0, 'Unhealthy recovery delivery');
  assert(result.onTimeFrames >= 30 * duration - 1, 'Recovery cadence exceeds boundary tolerance');
  return true;
}
