import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { qualifyMeasuredNativeMedia } from '../measured-native-trial.mjs';
const implementation = await import('../delivery-audit-envelope.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const options = { deliveryAuditMode: 'repeated' };
const repeated = (audit) => ({
  ...audit,
  formatVersion: 2,
  mode: 'repeated',
  maximumRows: 512,
  maximumBytes: 33554432,
});
const fixture = (count = 512) =>
  repeated({
    closed: true,
    overflow: false,
    invalid: false,
    rows: Array.from({ length: count }, (_, index) => ({ index })),
  });
function qualify(value, mode) {
  assert.equal(typeof implementation.qualifyDeliveryAuditEnvelope, 'function');
  return implementation.qualifyDeliveryAuditEnvelope(value, mode);
}
test('repeated delivery envelope retains exactly512 rows through trusted route only', () => {
  const value = fixture(),
    before = JSON.stringify(value);
  assert.equal(qualify(value, options), value.rows);
  assert.throws(() => qualify(value));
  assert.equal(JSON.stringify(value), before);
});
for (const [name, mutate] of Object.entries({
  version: (v) => (v.formatVersion = 1),
  mode: (v) => (v.mode = 'other'),
  rows: (v) => (v.maximumRows = 513),
  bytes: (v) => (v.maximumBytes = 33554433),
  open: (v) => (v.closed = false),
  overflow: (v) => (v.overflow = true),
  invalid: (v) => (v.invalid = true),
  empty: (v) => (v.rows = []),
  extra: (v) => v.rows.push({}),
  timing: (v) => (v.deliveryTiming = 'unknown'),
  missingRows: (v) => delete v.rows,
}))
  test(`repeated delivery rejects ${name}`, () => {
    const value = fixture();
    mutate(value);
    assert.throws(() => qualify(value, options));
  });
test('repeated delivery rejects unknown trusted mode and oversized UTF8 export', () => {
  assert.throws(() => qualify(fixture(), { deliveryAuditMode: 'other' }));
  const value = fixture(1);
  value.rows[0].padding = 'é'.repeat(16 * 1024 * 1024);
  assert.throws(() => qualify(value, options), /byte bound/);
});
test('legacy delivery retains256 limit and rejects repeated metadata', () => {
  const value = {
    formatVersion: 1,
    closed: true,
    overflow: false,
    invalid: false,
    rows: Array.from({ length: 256 }, () => ({})),
  };
  assert.equal(qualify(value), value.rows);
  for (const key of ['mode', 'maximumRows', 'maximumBytes'])
    assert.throws(() => qualify({ ...value, [key]: fixture()[key] }));
  assert.throws(() => qualify({ ...value, rows: [...value.rows, {}] }));
  assert.throws(() => qualify(value, options));
});
function rawMediaFixture() {
  const f = JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-trial-15qSdC.json.gz', import.meta.url)),
    ),
  ).input;
  f.deliveryAudit = repeated(f.deliveryAudit);
  return f;
}
test('shared raw media forwards explicit delivery mode without granting authority to input metadata', () => {
  const f = rawMediaFixture(),
    before = JSON.stringify(f);
  const result = qualifyMeasuredNativeMedia(f, options);
  assert(result.delivery.successfulRows > 0);
  assert.throws(() => qualifyMeasuredNativeMedia(f));
  assert.throws(() => qualifyMeasuredNativeMedia({ ...f, deliveryAuditMode: 'repeated' }));
  assert.equal(JSON.stringify(f), before);
});
test('repeated delivery still replays every original deadline result', () => {
  const f = rawMediaFixture();
  const row = f.deliveryAudit.rows.findLast((r) => r.result !== null);
  row.result.onTimeFrames++;
  assert.throws(() => qualifyMeasuredNativeMedia(f, options), /differs/);
});

const { qualifyRepeatedMeasuredPolicy } = await import('../repeated-measured-policy.mjs');
const { qualifyRepeatedMeasuredRecoveryFaults } =
  await import('../repeated-measured-recovery-fault.mjs');
const { repeatedMeasuredPolicyFixture } =
  await import('./fixtures/repeated-measured-policy-evidence.mjs');
const { repeatedMeasuredDeliveryFaultFixture } =
  await import('./fixtures/repeated-measured-recovery-fault-evidence.mjs');
for (const routes of [
  ['decoderStall', 'decoderStall'],
  ['deliveryFailure', 'deliveryFailure'],
]) {
  test(`full repeated policy forwards deadline mode through ${routes.join('/')}`, () => {
    const f = repeatedMeasuredPolicyFixture(repeatedMeasuredDeliveryFaultFixture(routes));
    f.deliveryAudit = repeated(f.deliveryAudit);
    assert.equal(qualifyRepeatedMeasuredPolicy(f).repeatedPolicyQualified, true);
    f.deliveryAudit.overflow = true;
    assert.throws(() => qualifyRepeatedMeasuredPolicy(f), /deadline audit envelope/);
  });
}
test('nested repeated delivery fault validates repeated envelope before causality', () => {
  const f = repeatedMeasuredDeliveryFaultFixture(['deliveryFailure', 'decoderStall']);
  f.deliveryAudit = repeated(f.deliveryAudit);
  assert.equal(qualifyRepeatedMeasuredRecoveryFaults(f).faultQualified, true);
  f.deliveryAudit.maximumRows = 513;
  assert.throws(() => qualifyRepeatedMeasuredRecoveryFaults(f), /row bound/);
});
