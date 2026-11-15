import assert from 'node:assert/strict';

const kinds = ['thermal', 'transport', 'queue'];
const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const integer = (value) => Number.isSafeInteger(value) && value >= 0;
function entryKey(value) {
  assert(object(value), 'Invalid evidence dictionary entry');
  const keys = Object.keys(value).sort();
  assert(keys.length <= 32);
  for (const key of keys) {
    const scalar = value[key];
    assert(
      key.length <= 128 &&
        (scalar === null ||
          typeof scalar === 'boolean' ||
          (typeof scalar === 'number' &&
            Number.isFinite(scalar) &&
            Math.abs(scalar) <= Number.MAX_SAFE_INTEGER) ||
          (typeof scalar === 'string' && scalar.length <= 512)),
      'Non-scalar or oversized evidence entry',
    );
  }
  return JSON.stringify(Object.fromEntries(keys.map((k) => [k, value[k]])));
}

/** Decode the recovery export wire format without discarding any history. The
 * returned format5 object is input to existing independent validators, not a
 * qualification. Shared entries are immutable copies, never aliases to raw input. */
export function expandQualityEvidence(value) {
  assert(object(value), 'Missing quality evidence');
  if (value.formatVersion !== 6) {
    assert(!Object.hasOwn(value, 'evidenceDictionary'), 'Dictionary on historical quality format');
    return value;
  }
  assert.equal(value.transportPolicy, 'recovery-budget-v1');
  assert.equal(value.overflow, false, 'Overflowed evidence dictionary');
  assert(Array.isArray(value.events) && value.events.length <= 512);
  assert(Buffer.byteLength(JSON.stringify(value)) <= 8 * 1024 * 1024, 'Quality file exceeds bound');
  const dictionary = value.evidenceDictionary;
  assert(object(dictionary));
  assert.deepEqual(Object.keys(dictionary).sort(), [
    'formatVersion',
    'queue',
    'thermal',
    'transport',
  ]);
  assert.equal(dictionary.formatVersion, 1);
  const tables = {},
    seen = {};
  for (const kind of kinds) {
    const entries = dictionary[kind];
    assert(Array.isArray(entries) && entries.length <= 65536);
    const keys = new Set();
    tables[kind] = entries.map((entry) => {
      const key = entryKey(entry);
      assert(!keys.has(key), 'Duplicate dictionary entry');
      keys.add(key);
      return Object.freeze({ ...entry });
    });
    seen[kind] = 0;
  }
  const events = value.events.map((row) => {
    assert(object(row), 'Invalid quality event');
    if (!Object.hasOwn(row, 'evidence')) return { ...row };
    assert(object(row.evidence));
    const evidence = { ...row.evidence };
    for (const kind of kinds) {
      const history = evidence[kind];
      if (history === null && kind === 'queue') continue;
      assert(object(history), 'Missing pressure history');
      const field = kind === 'queue' ? 'states' : 'samples';
      const rangeKey = kind === 'queue' ? 'stateRanges' : 'sampleRanges';
      const countKey = kind === 'queue' ? 'stateCount' : 'sampleCount';
      const maximum = kind === 'queue' ? 4096 : 64;
      assert(!Object.hasOwn(history, field), 'Mixed inline/reference history');
      assert(integer(history[countKey]) && history[countKey] <= maximum);
      const ranges = history[rangeKey];
      assert(Array.isArray(ranges) && ranges.length <= maximum);
      let previousEnd,
        count = 0;
      const samples = [];
      for (const range of ranges) {
        assert(Array.isArray(range) && range.length === 2);
        const [start, length] = range;
        assert(
          integer(start) &&
            integer(length) &&
            length > 0 &&
            start + length <= tables[kind].length &&
            start !== previousEnd,
          'Invalid or noncanonical range',
        );
        count += length;
        assert(count <= maximum);
        for (let index = start; index < start + length; index++) {
          assert(index <= seen[kind], 'Dictionary first-use order changed');
          if (index === seen[kind]) seen[kind]++;
          samples.push(tables[kind][index]);
        }
        previousEnd = start + length;
      }
      assert.equal(count, history[countKey], 'Truncated pressure history');
      const decoded = { ...history, [field]: samples };
      delete decoded[rangeKey];
      delete decoded[countKey];
      evidence[kind] = decoded;
    }
    return { ...row, evidence };
  });
  for (const kind of kinds)
    assert.equal(seen[kind], tables[kind].length, 'Unused dictionary entry');
  const decoded = { ...value, formatVersion: 5, events };
  delete decoded.evidenceDictionary;
  return decoded;
}
