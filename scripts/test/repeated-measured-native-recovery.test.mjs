import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { gunzipSync } from 'node:zlib';
import { repeatedReceiverIntervalFixture } from './fixtures/repeated-receiver-interval-evidence.mjs';
import { withRepeatedAdmissionWitnesses } from './fixtures/repeated-admission-witnesses.mjs';
const implementation = await import('../repeated-measured-native-recovery.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});

test('raw repeated composition is an explicit entry separate from single-cycle evidence', () => {
  assert.equal(typeof implementation.qualifyRepeatedMeasuredNativeRecovery, 'function');
  const input = JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-recovery-mnaRRb.json.gz', import.meta.url)),
    ),
  ).input;
  const before = JSON.stringify(input);
  assert.throws(() => implementation.qualifyRepeatedMeasuredNativeRecovery(input), /repeated/i);
  assert.equal(JSON.stringify(input), before);
});

test('complete admission component cannot stand in for full source, cadence and recovery evidence', () => {
  assert.equal(typeof implementation.qualifyRepeatedMeasuredNativeRecovery, 'function');
  const f = withRepeatedAdmissionWitnesses(repeatedReceiverIntervalFixture());
  const input = {
    ...f,
    nativeProbe: f.probe,
    receiverIntervals: f.intervals,
    receiverRecords: f.records,
    faults: {
      formatVersion: 2,
      mode: 'repeated',
      closed: true,
      failed: false,
      scope: f.scope,
      campaigns: [],
    },
  };
  const before = JSON.stringify(input);
  assert.throws(() => implementation.qualifyRepeatedMeasuredNativeRecovery(input));
  assert.equal(JSON.stringify(input), before);
});
