import assert from 'node:assert/strict';

export const nativeEncoderProperties = Object.freeze([
  'EncoderID',
  'UsingHardwareAcceleratedVideoEncoder',
  'AverageBitRate',
  'DataRateLimits',
  'RealTime',
  'ExpectedFrameRate',
  'ProfileLevel',
  'AllowFrameReordering',
  'Quality',
  'MaxAllowedFrameQP',
  'MinAllowedFrameQP',
  'ConstantBitRate',
  'MaxFrameDelayCount',
  'MaxKeyFrameIntervalDuration',
]);
const status = (n) => Number.isInteger(n) && n >= -2147483648 && n <= 2147483647;
const string = (s) => typeof s === 'string' && s.length <= 256;
const scalar = (v) =>
  v === null ||
  typeof v === 'boolean' ||
  string(v) ||
  (typeof v === 'number' && Number.isFinite(v)) ||
  (Array.isArray(v) &&
    v.length <= 8 &&
    v.every((n) => typeof n === 'number' && Number.isFinite(n)));
const keys = (value, expected) => assert.deepEqual(Object.keys(value).sort(), [...expected].sort());

export function qualifyNativeEncoderSnapshot(
  snapshot,
  expectedRate,
  { dataRateLimits = 'bounded' } = {},
) {
  assert.ok(['bounded', 'unsupported'].includes(dataRateLimits));
  keys(snapshot, [
    'supportedQueryStatus',
    'properties',
    'encoderSessionID',
    'collectedAt',
    'completedAt',
  ]);
  assert.match(snapshot.encoderSessionID, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
  assert.ok(Number.isFinite(snapshot.collectedAt) && snapshot.collectedAt >= 0);
  assert.ok(Number.isFinite(snapshot.completedAt) && snapshot.completedAt >= snapshot.collectedAt);
  assert.ok(status(snapshot.supportedQueryStatus));
  keys(snapshot.properties, nativeEncoderProperties);
  for (const row of Object.values(snapshot.properties)) {
    keys(row, ['supported', 'status', 'value', 'type', 'readWriteStatus']);
    assert.equal(typeof row.supported, 'boolean');
    assert.ok(status(row.status) && scalar(row.value));
    assert.ok(row.type === null || string(row.type));
    assert.ok(row.readWriteStatus === null || string(row.readWriteStatus));
    if (row.status !== 0) assert.equal(row.value, null, 'Failed copy cannot establish a value');
    if (!row.supported) {
      assert.equal(row.type, null);
      assert.equal(row.readWriteStatus, null);
    }
    if (snapshot.supportedQueryStatus !== 0) assert.equal(row.supported, false);
  }
  const p = snapshot.properties;
  for (const key of ['UsingHardwareAcceleratedVideoEncoder', 'RealTime', 'AllowFrameReordering']) {
    if (p[key].value !== null) assert.equal(typeof p[key].value, 'boolean');
  }
  for (const key of [
    'ExpectedFrameRate',
    'Quality',
    'MaxAllowedFrameQP',
    'MinAllowedFrameQP',
    'ConstantBitRate',
    'MaxFrameDelayCount',
    'MaxKeyFrameIntervalDuration',
  ]) {
    if (p[key].value !== null) assert.equal(typeof p[key].value, 'number');
  }
  if (p.ProfileLevel.value !== null) assert.ok(string(p.ProfileLevel.value));
  assert.equal(p.EncoderID.status, 0);
  assert.ok(string(p.EncoderID.value) && p.EncoderID.value.length > 0);
  assert.equal(p.AverageBitRate.status, 0);
  assert.equal(p.AverageBitRate.value, expectedRate);
  if (dataRateLimits === 'unsupported') {
    assert.equal(p.DataRateLimits.status, -12900);
    assert.equal(p.DataRateLimits.value, null);
  } else {
    assert.equal(p.DataRateLimits.status, 0);
    assert.deepEqual(p.DataRateLimits.value, [(expectedRate / 8) * 1.5, 1]);
  }
  return snapshot;
}
