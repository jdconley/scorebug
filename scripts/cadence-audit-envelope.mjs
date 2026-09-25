import assert from 'node:assert/strict';

/** The caller selects the route; raw metadata never selects a larger budget. */
export function cadenceAuditRowLimit(cadenceAuditMode = 'legacy') {
  assert(
    ['legacy', 'repeated', 'capacity'].includes(cadenceAuditMode),
    'Unsupported cadence audit mode',
  );
  return cadenceAuditMode === 'legacy' ? 2048 : 3072;
}

/** Envelope only. This does not qualify the contained cadence, delivery or health. */
export function qualifyCadenceAuditEnvelope(audit, { cadenceAuditMode = 'legacy' } = {}) {
  const maximumRows = cadenceAuditRowLimit(cadenceAuditMode);
  const label = cadenceAuditMode === 'capacity' ? 'Capacity' : 'Repeated';
  assert(audit && typeof audit === 'object', 'Missing cadence audit envelope');
  if (cadenceAuditMode !== 'legacy') {
    assert.equal(audit.formatVersion, 2, `${label} cadence audit requires version2`);
    assert.equal(audit.mode, cadenceAuditMode, `${label} cadence audit mode mismatch`);
    assert.equal(audit.maximumRows, 3072, `${label} cadence audit row bound mismatch`);
    assert.equal(audit.maximumBytes, 16777216, `${label} cadence audit byte bound mismatch`);
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
  if (cadenceAuditMode !== 'legacy')
    assert(
      Buffer.byteLength(JSON.stringify(audit), 'utf8') <= 16777216,
      `${label} cadence audit exceeds serialized byte bound`,
    );
  return audit.rows;
}
