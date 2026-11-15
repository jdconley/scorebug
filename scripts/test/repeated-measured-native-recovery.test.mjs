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

test('repeated artifact bound admits the complete two-candidate native export', () => {
  const f = repeatedReceiverIntervalFixture();
  const bytes = Buffer.byteLength(JSON.stringify(f.candidateProof));
  assert(bytes > 256 * 1024, 'Fixture must expose the legacy one-candidate limit');
  assert(
    implementation.repeatedMeasuredArtifacts?.candidateProof?.[1] >= bytes,
    'Repeated native candidate proof is truncated by legacy bound',
  );
  assert.equal(implementation.repeatedMeasuredArtifacts.candidateProof[1], 512 * 1024);
});

test('complete raw reconstruction proves source expiry without relabeling the failed native run', () => {
  const fixture = JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/repeated-source-expiry-aPqApF.json.gz', import.meta.url)),
    ),
  );
  assert.equal(fixture.provenance.originalHarnessExit, 1);
  assert.equal(fixture.provenance.originalFailureRelabeled, false);
  const input = fixture.input,
    before = JSON.stringify(input);
  const result = implementation.qualifyRepeatedMeasuredNativeRecovery(input);
  assert.equal(JSON.stringify(input), before);
  assert.equal(result.measuredRepeatedRecoveryQualified, true);
  assert.equal(result.readiness.readinessQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.equal(result.policy.invalidations.length, 1);
  const rejected = result.policy.invalidations[0];
  assert.equal(rejected.kind, 'source-expiry');
  assert.equal(rejected.eventIndex, 42);
  assert.equal(rejected.sourceSequence, '35');
  assert.equal(rejected.reportIndex, 1814);
  assert.equal(rejected.nextReportIndex, 1821);
  assert(result.policy.recoveries[1].sharedCoverage.start > rejected.availableAt);
  // Reject an apparently fresh helper whose age was reset by a later poll.
  input.quality.events[42].evaluationDiagnostic.session.sampleAgeSeconds = 0.12;
  assert.throws(
    () => implementation.qualifyRepeatedMeasuredNativeRecovery(input),
    /Diagnostic sample age (outside independent bracket|excludes elapsed time)/,
  );
});
