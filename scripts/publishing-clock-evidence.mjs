import assert from 'node:assert/strict';

/** Finite native fixture only: compare exact source rationals, never remote first-frame PTS. */
export function validatePublishingClockEvidence(before, after, expectedOrigin) {
  assert.ok(before && typeof before === 'object', 'Missing native transport clock before stop');
  assert.equal(after, null, 'Native clock must be unavailable after joined stop');
  const integer = (value, minimum, maximum) => {
    assert.equal(typeof value, 'string', 'Clock integers must use exact decimal strings');
    assert.match(value, /^-?(0|[1-9][0-9]*)$/);
    const result = BigInt(value);
    assert.equal(String(result), value, 'Noncanonical clock integer');
    assert.ok(result >= minimum && result <= maximum, 'Clock integer out of range');
    return result;
  };
  integer(before.publishingGeneration, 1n, 18446744073709551615n);
  assert.equal(before.timescale, 90000);
  assert.equal(before.presentationLead, '9000');
  assert.equal(before.wireModulus, '8589934592');
  const source = before.sourceOrigin;
  assert.ok(source && typeof source === 'object');
  const value = integer(source.value, -9223372036854775808n, 9223372036854775807n);
  assert.ok(
    Number.isInteger(source.timescale) && source.timescale > 0 && source.timescale <= 2147483647,
  );
  assert.equal(source.epoch, '0');
  assert.ok(source.flags === 1 || source.flags === 3, 'Non-numeric source clock');
  assert.equal(
    value * expectedOrigin.timescale,
    expectedOrigin.value * BigInt(source.timescale),
    'Native muxer origin differs from this fixture’s common A/V source origin',
  );
  return structuredClone(before);
}
