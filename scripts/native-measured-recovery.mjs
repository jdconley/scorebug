import assert from 'node:assert/strict';

/** Adds one controlled decoder fault to an already validated measured route. */
export function nativeMeasuredRecovery({ environment, measuredTrial, holdSeconds }) {
  const flag = environment.SCOREBUG_TEST_MEASURED_RECOVERY;
  if (flag === undefined) return false;
  assert.ok(
    flag === 'decoder-stall' &&
      measuredTrial === true &&
      Number.isSafeInteger(holdSeconds) &&
      holdSeconds >= 90 &&
      holdSeconds <= 600,
    'Measured recovery requires decoder-stall, a validated measured trial, and a 90–600 second hold',
  );
  return true;
}
