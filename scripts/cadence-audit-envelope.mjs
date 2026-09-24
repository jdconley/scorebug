import assert from 'node:assert/strict';

/** The caller selects the route; raw metadata never selects a larger budget. */
export function cadenceAuditRowLimit(cadenceAuditMode = 'legacy') {
  assert(['legacy', 'repeated'].includes(cadenceAuditMode), 'Unsupported cadence audit mode');
  return cadenceAuditMode === 'repeated' ? 3072 : 2048;
}

/** Envelope only. This does not qualify the contained cadence, delivery or health. */
export function qualifyCadenceAuditEnvelope(audit, { cadenceAuditMode = 'legacy' } = {}) {
  const maximumRows = cadenceAuditRowLimit(cadenceAuditMode);
  assert(audit && typeof audit === 'object', 'Missing cadence audit envelope');
  if (cadenceAuditMode === 'repeated') {
    assert.equal(audit.formatVersion, 2, 'Repeated cadence audit requires version2');
    assert.equal(audit.mode, 'repeated', 'Repeated cadence audit mode mismatch');
    assert.equal(audit.maximumRows, 3072, 'Repeated cadence audit row bound mismatch');
    assert.equal(audit.maximumBytes, 16777216, 'Repeated cadence audit byte bound mismatch');
  } else {
    assert.equal(audit.formatVersion, 1, 'Legacy cadence audit requires version1');
    for (const key of ['mode', 'maximumRows', 'maximumBytes'])
      assert(!Object.hasOwn(audit, key), 'Legacy cadence audit carries repeated metadata');
  }
  assert(
    audit.closed === true && audit.overflow === false && audit.invalid === false,
    'Invalid cadence audit envelope',
  );
  assert(
    Array.isArray(audit.rows) && audit.rows.length > 0 && audit.rows.length <= maximumRows,
    'Unbounded or missing cadence audit rows',
  );
  if (cadenceAuditMode === 'repeated')
    assert(
      Buffer.byteLength(JSON.stringify(audit), 'utf8') <= 16777216,
      'Repeated cadence audit exceeds serialized byte bound',
    );
  return audit.rows;
}
