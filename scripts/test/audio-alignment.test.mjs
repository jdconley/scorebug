import assert from 'node:assert/strict';
import { test } from 'node:test';
import { estimateAudioAlignment } from '../audio-alignment.mjs';

const length = 1024,
  radius = 128,
  padding = 32;
function wave(t) {
  return [
    [397.3, 0.2, 0.3],
    [1201.9, 0.7, 0.24],
    [2377.7, 0.4, 0.18],
    [3211.4, 0.9, 0.12],
  ].reduce(
    (sum, [frequency, phase, gain]) =>
      sum + gain * Math.sin((2 * Math.PI * frequency * t) / 8000 + phase),
    0,
  );
}
function fixture(delay = 0) {
  return {
    reference: Float64Array.from({ length }, (_, i) => wave(i)),
    target: Float64Array.from({ length: length + 2 * (radius + padding) }, (_, i) =>
      wave(i - radius - padding - delay),
    ),
    maxLagSamples: radius,
  };
}

for (const delay of [-99.43, -17.2, -0.43, 0, 0.27, 31.46, 99.27]) {
  test(`recovers independently generated signed delay ${delay}`, () => {
    const result = estimateAudioAlignment(fixture(delay));
    assert.ok(Math.abs(result.lagSamples - delay) <= 1 / 64);
    assert.ok(result.correlation > 0.999);
    assert.equal(result.atSearchBoundary, false);
  });
}

test('normalized comparison tolerates gain and DC offset', () => {
  const input = fixture(17.27);
  input.target = Float32Array.from(input.target, (x) => x * 0.7 + 0.12);
  const result = estimateAudioAlignment(input);
  assert.ok(Math.abs(result.lagSamples - 17.27) <= 1 / 64);
  assert.ok(result.correlation > 0.999);
});

test('unrelated signals do not become correlated by refinement', () => {
  let seed = 54321;
  const random = () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 2 ** 32 - 0.5;
  };
  const input = fixture();
  input.reference = Float64Array.from(input.reference, random);
  input.target = Float64Array.from(input.target, random);
  assert.ok(estimateAudioAlignment(input).correlation < 0.2);
});

for (const sign of [-1, 1]) {
  test(`reports the ${sign > 0 ? 'upper' : 'lower'} search boundary without extrapolation`, () => {
    const result = estimateAudioAlignment(fixture(sign * radius));
    assert.equal(result.lagSamples, sign * radius);
    assert.equal(result.atSearchBoundary, true);
  });
}

const invalid = {
  'silent reference': (x) => x.reference.fill(0),
  'constant reference': (x) => x.reference.fill(0.5),
  'silent target': (x) => x.target.fill(0),
  'constant target': (x) => x.target.fill(0.5),
  'nonfinite reference': (x) => (x.reference[100] = NaN),
  'nonfinite target padding': (x) => (x.target[0] = Infinity),
  'missing leading/trailing support': (x) => (x.target = x.target.slice(1)),
  'extra target samples': (x) => (x.target = new Float64Array(x.target.length + 1)),
  'negative radius': (x) => (x.maxLagSamples = -1),
  'fractional radius': (x) => (x.maxLagSamples = 1.5),
  'unbounded radius': (x) => (x.maxLagSamples = 2401),
  'unbounded window': (x) => (x.reference = new Float64Array(48001)),
  'tiny window': (x) => (x.reference = new Float64Array(127)),
  'untyped input': (x) => (x.reference = Array.from(x.reference)),
};
for (const [name, mutate] of Object.entries(invalid)) {
  test(`rejects ${name}`, () => {
    const input = fixture();
    mutate(input);
    assert.throws(() => estimateAudioAlignment(input));
  });
}

test('zero-radius comparison and inputs remain unchanged', () => {
  const input = fixture();
  input.maxLagSamples = 0;
  input.target = input.target.slice(radius, -radius);
  const reference = input.reference.slice(),
    target = input.target.slice();
  const result = estimateAudioAlignment(input);
  assert.equal(result.lagSamples, 0);
  assert.equal(result.atSearchBoundary, true);
  assert.ok(result.correlation > 0.999999);
  assert.deepEqual(input.reference, reference);
  assert.deepEqual(input.target, target);
});

test('numerically unusable finite audio fails closed', () => {
  const input = fixture();
  input.reference = Float64Array.from(input.reference, (x) => x * 1e300);
  assert.throws(() => estimateAudioAlignment(input));
});

test('a repeated tone cannot establish a unique delay', () => {
  const input = fixture();
  input.reference = Float64Array.from(input.reference, (_, i) => Math.sin((2 * Math.PI * i) / 16));
  input.target = Float64Array.from(input.target, (_, i) =>
    Math.sin((2 * Math.PI * (i - radius - padding - 23.25)) / 16),
  );
  const result = estimateAudioAlignment(input);
  assert.ok(result.correlation > 0.999);
  assert.equal(result.ambiguous, true);
});

test('distinct multitone peak separates from competing delay peaks', () => {
  const result = estimateAudioAlignment(fixture(31.46));
  assert.equal(result.ambiguous, false);
  assert.ok(result.peakMargin >= 0.005);
});
