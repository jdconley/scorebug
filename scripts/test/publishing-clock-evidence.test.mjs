import assert from 'node:assert/strict';
import { test } from 'node:test';
import { validatePublishingClockEvidence } from '../publishing-clock-evidence.mjs';

const clock = (value = '493', timescale = 4) => ({
  publishingGeneration: '18446744073709551615',
  sourceOrigin: { value, timescale, epoch: '0', flags: 1 },
  timescale: 90000,
  presentationLead: '9000',
  wireModulus: '8589934592',
});
const expected = { value: 123250000000n, timescale: 1000000000n };

test('preserves exact rational origin and full-width native generation without Number conversion', () => {
  const input = clock();
  const result = validatePublishingClockEvidence(input, null, expected);
  assert.deepEqual(result, input);
  assert.notEqual(result, input);
  input.sourceOrigin.value = '0';
  assert.equal(result.sourceOrigin.value, '493');
});

test('accepts origin zero and the equivalent rounded rational supplied by the muxer', () => {
  assert.deepEqual(
    validatePublishingClockEvidence(clock('0', 48000), null, { value: 0n, timescale: 1n }),
    clock('0', 48000),
  );
  const rounded = clock();
  rounded.sourceOrigin.flags = 3;
  assert.deepEqual(validatePublishingClockEvidence(rounded, null, expected), rounded);
});

for (const [name, mutate] of [
  ['missing before stop', () => null],
  ['wrong rational origin', (c) => ({ ...c, sourceOrigin: { ...c.sourceOrigin, value: '494' } })],
  ['zero scale', (c) => ({ ...c, sourceOrigin: { ...c.sourceOrigin, timescale: 0 } })],
  ['unsafe scale', (c) => ({ ...c, sourceOrigin: { ...c.sourceOrigin, timescale: 2147483648 } })],
  ['nonnumeric flags', (c) => ({ ...c, sourceOrigin: { ...c.sourceOrigin, flags: 5 } })],
  ['nonzero epoch', (c) => ({ ...c, sourceOrigin: { ...c.sourceOrigin, epoch: '1' } })],
  ['noncanonical value', (c) => ({ ...c, sourceOrigin: { ...c.sourceOrigin, value: '0493' } })],
  [
    'overflow value',
    (c) => ({ ...c, sourceOrigin: { ...c.sourceOrigin, value: '9223372036854775808' } }),
  ],
  ['zero generation', (c) => ({ ...c, publishingGeneration: '0' })],
  ['numeric generation', (c) => ({ ...c, publishingGeneration: 1 })],
  ['overflow generation', (c) => ({ ...c, publishingGeneration: '18446744073709551616' })],
  ['wrong timebase', (c) => ({ ...c, timescale: 1000 })],
  ['wrong lead', (c) => ({ ...c, presentationLead: '0' })],
  ['wrong modulus', (c) => ({ ...c, wireModulus: '4294967296' })],
]) {
  test(`rejects ${name}`, () =>
    assert.throws(() => validatePublishingClockEvidence(mutate(clock()), null, expected)));
}

test('requires explicit unavailable clock after joined stop', () => {
  for (const after of [undefined, clock(), {}])
    assert.throws(() => validatePublishingClockEvidence(clock(), after, expected));
});
