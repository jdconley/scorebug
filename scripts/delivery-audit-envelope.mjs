import { qualifyTimingContract } from './native-timing-contract.mjs';
import assert from 'node:assert/strict';

/** The trusted caller selects capacity. Envelope acceptance grants no delivery health. */
export function qualifyDeliveryAuditEnvelope(
  audit,
  { deliveryAuditMode = 'legacy', timingProfile = 'strict1500-v1' } = {},
) {
  qualifyTimingContract(audit, timingProfile);
  assert(
    timingProfile === 'strict1500-v1' || deliveryAuditMode === 'capacity',
    'Experimental timing requires capacity diagnostic envelopes',
  );
  assert(
    ['legacy', 'repeated', 'capacity'].includes(deliveryAuditMode),
    'Unsupported delivery audit mode',
  );
  assert(audit && typeof audit === 'object', 'Missing deadline audit envelope');
  assert(
    audit.deliveryTiming === undefined || audit.deliveryTiming === 'request-uptime-v1',
    'Unknown delivery timing mode',
  );
  const extended = deliveryAuditMode !== 'legacy';
  const label = deliveryAuditMode === 'capacity' ? 'Capacity' : 'Repeated';
  if (extended) {
    assert.equal(audit.formatVersion, 2, `${label} deadline audit requires version2`);
    assert.equal(audit.mode, deliveryAuditMode, `${label} deadline audit mode mismatch`);
    assert.equal(audit.maximumRows, 512, `${label} deadline audit row bound mismatch`);
    assert.equal(audit.maximumBytes, 33554432, `${label} deadline audit byte bound mismatch`);
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
      audit.rows.length <= (extended ? 512 : 256),
    'Unbounded deadline audit',
  );
  if (extended)
    assert(
      Buffer.byteLength(JSON.stringify(audit), 'utf8') <= 33554432,
      `${label} deadline audit exceeds serialized byte bound`,
    );
  return audit.rows;
}
