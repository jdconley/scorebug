import assert from 'node:assert/strict';

/** Selects two causal fault campaigns only after full measured-route validation. */
export function nativeRepeatedRecovery({ environment, measuredTrial, holdSeconds }) {
  if (environment.SCOREBUG_TEST_MEASURED_RECOVERY !== 'repeated') return false;
  assert.ok(
    measuredTrial === true &&
      environment.SCOREBUG_TEST_MEASURED_TRIAL === '1' &&
      environment.SCOREBUG_TEST_BANDWIDTH_PROBE === 'repeated' &&
      holdSeconds === 180,
    'Repeated recovery requires a validated repeated measured trial and exactly 180 seconds',
  );
  return true;
}

/** Selects controlled recovery on an already validated measured route. */
export function nativeMeasuredRecovery({ environment, measuredTrial, holdSeconds }) {
  const flag = environment.SCOREBUG_TEST_MEASURED_RECOVERY;
  if (flag === undefined) return false;
  if (flag === 'repeated')
    return nativeRepeatedRecovery({ environment, measuredTrial, holdSeconds });
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
