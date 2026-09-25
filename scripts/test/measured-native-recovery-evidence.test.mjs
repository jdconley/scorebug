import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import {
  qualifyMeasuredNativeEvidence,
  qualifyMeasuredNativeTrial,
} from '../measured-native-trial.mjs';
import { qualifyMeasuredNativeRecovery } from '../measured-native-recovery.mjs';
import { qualifyMeasuredProbeRetirement } from '../measured-probe-retirement.mjs';
import { addSyntheticRecoveryProbeEvidence } from './fixtures/recovery-policy-evidence.mjs';

// Raw recorded three-phase media chronology with synthetic policy/preflight
// metadata only. It proves composition, not a new network or fault experiment.
const fixture = () => {
  const f = JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-recovery-mnaRRb.json.gz', import.meta.url)),
    ),
  ).input;
  f.nativeProbe.formatVersion = 4;
  f.nativeProbe.policy = 'recovery-budget-v1';
  f.quality.formatVersion = 5;
  f.quality.transportPolicy = 'recovery-budget-v1';
  for (const value of [f.nativeProbe, f.quality, f.candidateProof, f.lifecycle])
    addSyntheticRecoveryProbeEvidence(value);
  return f;
};
const options = { recovery: true, probePolicy: 'recovery-budget-v1' };
const qualify = (f) => qualifyMeasuredNativeEvidence(f, options);

function capacityInput() {
  const f = fixture();
  Object.assign(f.cadenceReports, {
    formatVersion: 2,
    mode: 'capacity',
    maximumRows: 3072,
    maximumBytes: 16777216,
  });
  Object.assign(f.deliveryAudit, {
    formatVersion: 2,
    mode: 'capacity',
    maximumRows: 512,
    maximumBytes: 33554432,
  });
  return f;
}
test('explicit capacity replay retains full raw recovery checks with both bounded envelopes', () => {
  const f = capacityInput(),
    before = structuredClone(f);
  const result = qualifyMeasuredNativeEvidence(f, { ...options, capacityRecovery: true });
  assert.equal(result.profile.phases.length, 3);
  assert.equal(result.nativeLifecycle.upgradeAuthorized, false);
  assert.equal(Object.hasOwn(result, 'capacityRecoveryQualified'), false);
  assert.deepEqual(f, before);
  assert.throws(() => qualify(f));
});
test('capacity envelopes require paired explicit recovery and transport policy selection', () => {
  for (const extra of [
    {},
    { capacityRecovery: false },
    { capacityRecovery: 'true' },
    { capacityRecovery: true, recovery: false },
    { capacityRecovery: true, probePolicy: 'local-zero-loss-v1' },
  ])
    assert.throws(() => qualifyMeasuredNativeEvidence(capacityInput(), { ...options, ...extra }));
});
for (const [name, mutate] of Object.entries({
  'legacy cadence': (f) => (f.cadenceReports = fixture().cadenceReports),
  'legacy delivery': (f) => (f.deliveryAudit = fixture().deliveryAudit),
  'repeated cadence': (f) => (f.cadenceReports.mode = 'repeated'),
  'repeated delivery': (f) => (f.deliveryAudit.mode = 'repeated'),
  overflow: (f) => (f.deliveryAudit.overflow = true),
  'invalid cadence': (f) => (f.cadenceReports.invalid = true),
  'wrong row bound': (f) => f.cadenceReports.maximumRows++,
  'missing media': (f) => (f.liveIDs = []),
  'changed historical reset': (f) =>
    (f.lifecycle.profileRequests[1].terminalProbeRead.observation.id =
      f.lifecycle.profileRequests[1].requestID),
}))
  test(`capacity raw replay rejects ${name}`, () => {
    const f = capacityInput();
    mutate(f);
    assert.throws(() => qualifyMeasuredNativeEvidence(f, { ...options, capacityRecovery: true }));
  });

test('recovery raw evidence joins three phases without granting route or recovery success', () => {
  const f = fixture(),
    before = structuredClone(f),
    r = qualify(f);
  assert.equal(r.profile.phases.length, 3);
  assert.equal(r.nativeLifecycle.applications.length, 2);
  assert.equal(r.nativeLifecycle.upgradeAuthorized, false);
  assert.equal(r.probe.policy, options.probePolicy);
  assert.equal(r.witness.policy, options.probePolicy);
  assert.equal(r.nativeLifecycle.probePolicy, options.probePolicy);
  for (const key of [
    'measuredRecoveryQualified',
    'networkLossRecoveryQualified',
    'measuredTrialQualified',
    'productionUpgradeAuthorized',
    'repeatedRampUpQualified',
  ])
    assert.equal(Object.hasOwn(r, key), false);
  assert.deepEqual(f, before);
  assert.throws(() => qualifyMeasuredNativeEvidence(f));
  assert.throws(() => qualifyMeasuredNativeEvidence(f, { probePolicy: options.probePolicy }));
  assert.throws(() => qualifyMeasuredNativeTrial(f, { probePolicy: options.probePolicy }));
  assert.throws(() => qualifyMeasuredNativeRecovery(f));
});
const reset = (f) => f.lifecycle.profileRequests[1];
for (const [name, mutate] of Object.entries({
  'wrong policy': (f) => (f.nativeProbe.policy = 'local-zero-loss-v1'),
  'wrong quality policy': (f) => (f.quality.transportPolicy = 'sender-delay-v1'),
  'missing raw preflight': (f) => delete f.nativeProbe.events[0].sample.recoveryObservation,
  'late recovery preflight': (f) =>
    (f.lifecycle.profileRequests[0].currentProbe.recoveryObservation.sampledAt -= 0.101),
  'reset is still authorized': (f) => (reset(f).authorityPermitted = true),
  'foreign reset probe': (f) => (reset(f).terminalProbeRead.observation.id = reset(f).requestID),
  'altered historical reset preflight': (f) =>
    reset(f).terminalProbeRead.observation.recoveryObservation.rttMilliseconds++,
  'missing reset media': (f) => f.format.compressedFrames.pop(),
  'missing archive coverage': (f) => (f.archiveIDs = []),
  'missing live evidence': (f) => (f.liveIDs = []),
  'foreign recording': (f) => (f.expectedScope.recordingID = f.snapshot.scope.publishingAttemptID),
  'missing cadence': (f) => (f.cadenceReports.rows = []),
  'missing delivery audit': (f) => (f.deliveryAudit.rows = []),
  'missing receiver intervals': (f) => (f.receiverIntervals.intervals = []),
  'missing receiver records': (f) => (f.receiverRecords = []),
  'missing candidate source': (f) => f.candidateProof.measurement.encoding.frames.pop(),
  'changed admission witness': (f) =>
    (f.quality.events.find(
      (e) => e.kind === 'candidate',
    ).candidateAdmission.deliveredPaddingBitsPerSecond *= 2),
}))
  test(`raw recovery evidence rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

const retire = (f) =>
  qualifyMeasuredProbeRetirement(
    f.nativeProbe,
    { lifecycle: f.lifecycle, quality: f.quality, recovery: true },
    { policy: options.probePolicy },
  );
test('retirement binds the later reset to the same closed recovery preflight', () => {
  const f = fixture(),
    before = structuredClone(f),
    r = retire(f);
  assert.equal(r.profileRequestID, f.lifecycle.profileRequests[0].requestID);
  assert.equal(r.retiredObservedAt, f.lifecycle.profileRequests[0].terminalProbeRead.completedAt);
  assert.deepEqual(f, before);
});
for (const [name, mutate] of Object.entries({
  'renewed authority': (f) => (reset(f).authorityPermitted = true),
  'renewed probe authority': (f) => (reset(f).probeAuthorityPermitted = true),
  'active historical probe': (f) => (reset(f).currentProbeActive = true),
  'renewed binding': (f) => reset(f).probeBinding.boundAt++,
  'renewed current lease': (f) => reset(f).currentProbe.leaseDeadline++,
  'changed terminal preflight': (f) =>
    reset(f).terminalProbeRead.observation.recoveryObservation.rttMilliseconds++,
  'changed terminal campaign': (f) => (reset(f).terminalProbeRead.observation.campaign = 2),
  'changed terminal policy': (f) =>
    (reset(f).terminalProbeRead.observation.policy = 'local-zero-loss-v1'),
}))
  test(`recovery retirement rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => retire(f));
  });

test('dictionary recovery evidence retains the same raw three-phase qualification', async () => {
  const { dictionaryQualityFixture } = await import('./fixtures/quality-evidence-dictionary.mjs');
  const f = fixture(),
    expected = qualify(f);
  f.quality = dictionaryQualityFixture(f.quality);
  const before = structuredClone(f);
  assert.deepEqual(qualify(f), expected);
  assert.deepEqual(f, before);
  f.quality.overflow = true;
  assert.throws(() => qualify(f));
});

test('recovery raw replay requires boolean context and a known explicit policy', () => {
  const f = fixture();
  for (const recovery of [null, 1, 'true'])
    assert.throws(() => qualifyMeasuredNativeEvidence(f, { ...options, recovery }));
  for (const probePolicy of [null, 'future-v1', 'local-zero-loss-v1'])
    assert.throws(() => qualifyMeasuredNativeEvidence(f, { ...options, probePolicy }));
});
