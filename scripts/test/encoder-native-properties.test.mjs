import test from 'node:test';
import assert from 'node:assert/strict';
import {
  nativeEncoderProperties,
  qualifyNativeEncoderSnapshot,
} from '../encoder-native-properties.mjs';

function fixture() {
  const properties = Object.fromEntries(
    nativeEncoderProperties.map((key) => [
      key,
      {
        supported: false,
        status: -12900,
        value: null,
        type: null,
        readWriteStatus: null,
      },
    ]),
  );
  properties.EncoderID = {
    supported: true,
    status: 0,
    value: 'observed.encoder',
    type: 'String',
    readWriteStatus: 'ReadOnly',
  };
  properties.AverageBitRate = {
    supported: true,
    status: 0,
    value: 1500000,
    type: 'Number',
    readWriteStatus: 'ReadWrite',
  };
  properties.DataRateLimits = {
    supported: true,
    status: 0,
    value: [281250, 1],
    type: 'Array',
    readWriteStatus: 'ReadWrite',
  };
  return {
    supportedQueryStatus: 0,
    properties,
    encoderSessionID: '00000000-0000-4000-8000-000000000001',
    collectedAt: 1,
    completedAt: 2,
  };
}
test('retains explicit unsupported values and observed scalar native properties', () => {
  const snapshot = fixture();
  assert.deepEqual(qualifyNativeEncoderSnapshot(snapshot, 1500000), snapshot);
  snapshot.properties.UsingHardwareAcceleratedVideoEncoder = {
    supported: true,
    status: 0,
    value: false,
    type: 'Boolean',
    readWriteStatus: 'ReadOnly',
  };
  assert.equal(
    qualifyNativeEncoderSnapshot(snapshot, 1500000).properties.UsingHardwareAcceleratedVideoEncoder
      .value,
    false,
  );
});
test('rejects missing, foreign, unbounded and inconsistent native evidence', () => {
  for (const mutate of [
    (s) => delete s.properties.Quality,
    (s) => (s.properties.Foreign = s.properties.Quality),
    (s) => (s.supportedQueryStatus = NaN),
    (s) => (s.encoderSessionID = 'foreign'),
    (s) => (s.collectedAt = -1),
    (s) => (s.completedAt = 0),
    (s) => (s.properties.Quality.value = 0.5),
    (s) => (s.properties.Quality.status = 1.5),
    (s) => (s.properties.Quality.supported = 1),
    (s) => (s.properties.Quality.type = 'x'.repeat(257)),
    (s) => (s.properties.EncoderID.value = ''),
    (s) => (s.properties.EncoderID.value = { arbitrary: 'dictionary' }),
    (s) => (s.properties.EncoderID.value = 'x'.repeat(257)),
    (s) => (s.properties.AverageBitRate.value = 6000000),
    (s) => (s.properties.DataRateLimits.value = [1125000, 1]),
    (s) => (s.properties.DataRateLimits.value = Array(9).fill(1)),
    (s) => (s.properties.DataRateLimits.value = [NaN, 1]),
    (s) => (s.properties.Quality.extra = true),
    (s) => Object.assign(s.properties.RealTime, { status: 0, value: 1 }),
    (s) => Object.assign(s.properties.ExpectedFrameRate, { status: 0, value: true }),
    (s) => Object.assign(s.properties.ProfileLevel, { status: 0, value: 1 }),
  ]) {
    const snapshot = fixture();
    mutate(snapshot);
    assert.throws(() => qualifyNativeEncoderSnapshot(snapshot, 1500000));
  }
});
