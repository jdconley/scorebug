import assert from 'node:assert/strict';
import { test } from 'node:test';
import { measureFreshCadence } from '../media-soak.mjs';

test('cadence qualification counts source frames and evaluates five-second windows', () => {
  const times = Array.from({ length: 600 }, (_, i) => i / 30);
  const codes = times.map((_, i) => i);
  const good = measureFreshCadence(codes, times);
  assert.equal(good.freshFps, 30);
  assert.equal(good.healthyWindowFraction, 1);
  assert.equal(good.sourceFrameLoss, 0);
  assert.throws(
    () =>
      measureFreshCadence(
        codes.map((n) => Math.floor(n / 2)),
        times,
      ),
    /fresh/,
  );
  assert.throws(
    () =>
      measureFreshCadence(
        codes.filter((n) => n % 10),
        times.filter((_, n) => n % 10),
      ),
    /loss/,
  );
  assert.throws(
    () =>
      measureFreshCadence(
        codes,
        times.map((t, i) => (i > 300 ? t + 2 : t)),
      ),
    /window/,
  );
  assert.throws(
    () =>
      measureFreshCadence(
        codes,
        times.map((t, i) => (i === 5 ? NaN : t)),
      ),
    /timestamp/,
  );
  assert.throws(
    () =>
      measureFreshCadence(
        codes,
        times.map((t, i) => (i >= 270 && i < 300 ? t + (0.4 * (300 - i)) / 30 : t)),
      ),
    /timestamp/,
  );
});
