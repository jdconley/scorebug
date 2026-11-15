import assert from 'node:assert/strict';
import test from 'node:test';
import { nativeMeasuredRecovery } from '../native-measured-recovery.mjs';

const options = () => ({
  environment: { SCOREBUG_TEST_MEASURED_RECOVERY: 'decoder-stall' },
  measuredTrial: true,
  holdSeconds: 90,
});

test('measured recovery is absent by default and accepts only the complete measured route', () => {
  assert.equal(nativeMeasuredRecovery({ environment: {} }), false);
  for (const holdSeconds of [90, 120, 600]) {
    assert.equal(nativeMeasuredRecovery({ ...options(), holdSeconds }), true);
  }
});

test('measured recovery rejects invalid flags, unvalidated trials, and unbounded holds', () => {
  for (const flag of ['', '1', 'true', 'decoder-stall ', 'reset540', null]) {
    assert.throws(
      () =>
        nativeMeasuredRecovery({
          ...options(),
          environment: { SCOREBUG_TEST_MEASURED_RECOVERY: flag },
        }),
      /Measured recovery/,
    );
  }
  for (const measuredTrial of [undefined, false, 1, 'true']) {
    assert.throws(
      () => nativeMeasuredRecovery({ ...options(), measuredTrial }),
      /Measured recovery/,
    );
  }
  for (const holdSeconds of [undefined, 89, 601, 90.5, '90', NaN, Infinity]) {
    assert.throws(() => nativeMeasuredRecovery({ ...options(), holdSeconds }), /Measured recovery/);
  }
});
