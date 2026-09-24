import assert from 'node:assert/strict';

/** The trusted caller selects capacity. Envelope acceptance grants no delivery health. */
export function qualifyDeliveryAuditEnvelope(audit, { deliveryAuditMode = 'legacy' } = {}) {
  assert(['legacy', 'repeated'].includes(deliveryAuditMode), 'Unsupported delivery audit mode');
  assert(audit && typeof audit === 'object', 'Missing deadline audit envelope');
  assert(
    audit.deliveryTiming === undefined || audit.deliveryTiming === 'request-uptime-v1',
    'Unknown delivery timing mode',
  );
  const repeated = deliveryAuditMode === 'repeated';
  if (repeated) {
    assert.equal(audit.formatVersion, 2, 'Repeated deadline audit requires version2');
    assert.equal(audit.mode, 'repeated', 'Repeated deadline audit mode mismatch');
    assert.equal(audit.maximumRows, 512, 'Repeated deadline audit row bound mismatch');
    assert.equal(audit.maximumBytes, 33554432, 'Repeated deadline audit byte bound mismatch');
  } else {
    assert.equal(audit.formatVersion, 1, 'Legacy deadline audit requires version1');
    for (const key of ['mode', 'maximumRows', 'maximumBytes'])
      assert(!Object.hasOwn(audit, key), 'Legacy deadline audit carries repeated metadata');
  }
  assert(
    audit.closed === true && audit.overflow === false && audit.invalid === false,
    'Invalid deadline audit envelope',
  );
  assert(
    Array.isArray(audit.rows) &&
      audit.rows.length > 0 &&
      audit.rows.length <= (repeated ? 512 : 256),
    'Unbounded deadline audit',
  );
  if (repeated)
    assert(
      Buffer.byteLength(JSON.stringify(audit), 'utf8') <= 33554432,
      'Repeated deadline audit exceeds serialized byte bound',
    );
  return audit.rows;
}
