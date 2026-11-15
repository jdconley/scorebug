import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { qualifyCadenceAuditEnvelope } from '../cadence-audit-envelope.mjs';
import { qualifyDeliveryAuditEnvelope } from '../delivery-audit-envelope.mjs';
import { qualifyMeasuredNativeMedia } from '../measured-native-trial.mjs';
const limits = { cadence: [3072, 16777216], delivery: [512, 33554432] };
const wrap = (kind, audit) => ({
  ...audit,
  formatVersion: 2,
  mode: 'capacity',
  maximumRows: limits[kind][0],
  maximumBytes: limits[kind][1],
});
for (const [kind, qualify] of Object.entries({
  cadence: qualifyCadenceAuditEnvelope,
  delivery: qualifyDeliveryAuditEnvelope,
})) {
  const options = { [`${kind}AuditMode`]: 'capacity' };
  const fixture = () =>
    wrap(kind, {
      closed: true,
      overflow: false,
      invalid: false,
      rows: Array.from({ length: limits[kind][0] }, (_, index) => ({ index })),
    });
  test(`capacity ${kind} accepts its exact explicit budget without modifying raw history`, () => {
    const audit = fixture(),
      before = structuredClone(audit);
    assert.equal(qualify(audit, options), audit.rows);
    assert.deepEqual(audit, before);
    assert.throws(() => qualify(audit));
    assert.throws(() => qualify(audit, { [`${kind}AuditMode`]: 'repeated' }));
    assert.throws(() => qualify({ ...audit, mode: 'repeated' }, options));
  });
  for (const [name, mutate] of Object.entries({
    version: (a) => (a.formatVersion = 1),
    mode: (a) => (a.mode = 'repeated'),
    rowBound: (a) => a.maximumRows++,
    byteBound: (a) => a.maximumBytes++,
    empty: (a) => (a.rows = []),
    overflow: (a) => (a.overflow = true),
    open: (a) => (a.closed = false),
    invalid: (a) => (a.invalid = true),
    extraRow: (a) => a.rows.push({}),
  }))
    test(`capacity ${kind} rejects ${name}`, () => {
      const a = fixture();
      mutate(a);
      assert.throws(() => qualify(a, options));
    });
  test(`capacity ${kind} enforces exact UTF8 byte boundary`, () => {
    const a = fixture();
    a.padding = '';
    a.padding = 'x'.repeat(limits[kind][1] - Buffer.byteLength(JSON.stringify(a)));
    assert.equal(Buffer.byteLength(JSON.stringify(a)), limits[kind][1]);
    assert.equal(qualify(a, options), a.rows);
    a.padding += 'é';
    assert.throws(() => qualify(a, options), /byte bound/);
  });
}
test('capacity envelopes reconstruct all original native cadence and delivery evidence', () => {
  const f = JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-recovery-mnaRRb.json.gz', import.meta.url)),
    ),
  ).input;
  const expected = qualifyMeasuredNativeMedia(f);
  f.cadenceReports = wrap('cadence', f.cadenceReports);
  f.deliveryAudit = wrap('delivery', f.deliveryAudit);
  const before = structuredClone(f);
  const options = { cadenceAuditMode: 'capacity', deliveryAuditMode: 'capacity' };
  assert.deepEqual(qualifyMeasuredNativeMedia(f, options), expected);
  assert.deepEqual(f, before);
  assert.throws(() => qualifyMeasuredNativeMedia(f));
  assert.throws(() => qualifyMeasuredNativeMedia({ ...f, ...options }));
  f.deliveryAudit.rows.find((r) => r.result !== null).result.onTimeFrames++;
  assert.throws(() => qualifyMeasuredNativeMedia(f, options), /differs/);
});

for (const [kind, qualify] of Object.entries({
  cadence: qualifyCadenceAuditEnvelope,
  delivery: qualifyDeliveryAuditEnvelope,
})) {
  test(`${kind} timing contract cannot select or alter the trusted experimental profile`, async () => {
    const { timingContracts } = await import('../native-timing-contract.mjs');
    for (const profile of ['broadcast-reliability2000-v1', 'broadcast-reliability3000-v1']) {
      const options = { [`${kind}AuditMode`]: 'capacity', timingProfile: profile };
      const audit = wrap(kind, {
        closed: true,
        overflow: false,
        invalid: false,
        rows: [{}],
        timingContract: { ...timingContracts[profile] },
      });
      assert.equal(qualify(audit, options), audit.rows);
      assert.throws(() => qualify(audit, { [`${kind}AuditMode`]: 'capacity' }));
      const missing = { ...audit };
      delete missing.timingContract;
      assert.throws(() => qualify(missing, options));
      audit.timingContract.maximumCadenceDeliveryReportAgeMs = 2000;
      assert.throws(() => qualify(audit, options));
    }
  });
}
test('old native evidence cannot be relabelled by changing only timing envelopes', async () => {
  const { timingContracts } = await import('../native-timing-contract.mjs');
  const input = JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-recovery-mnaRRb.json.gz', import.meta.url)),
    ),
  ).input;
  const timingProfile = 'broadcast-reliability2000-v1';
  input.cadenceReports = {
    ...wrap('cadence', input.cadenceReports),
    timingContract: { ...timingContracts[timingProfile] },
  };
  input.deliveryAudit = {
    ...wrap('delivery', input.deliveryAudit),
    timingContract: { ...timingContracts[timingProfile] },
  };
  assert.throws(
    () =>
      qualifyMeasuredNativeMedia(input, {
        cadenceAuditMode: 'capacity',
        deliveryAuditMode: 'capacity',
        timingProfile,
      }),
    /deadline budgets/,
  );
});
