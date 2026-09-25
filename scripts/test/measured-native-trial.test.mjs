import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
const module = await import('../measured-native-trial.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const fixture = () =>
  JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-trial-15qSdC.json.gz', import.meta.url)),
    ),
  ).input;
const qualify = (f) => {
  assert.equal(typeof module.qualifyMeasuredNativeTrial, 'function');
  return module.qualifyMeasuredNativeTrial(f);
};
test('independently joins real raw native trial evidence without changing it', () => {
  const f = fixture(),
    before = JSON.stringify(f);
  const result = qualify(f);
  assert.equal(result.measuredTrialQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.equal(result.policy.confirmed, 1);
  assert.ok(result.policy.probation.coverageSeconds >= 10);
  assert.equal(result.delivery.observations.healthyRows, 147);
  assert.equal(result.source.intervals.length, 19);
  assert.equal(result.witness.headroomQualified, true);
  assert.equal(JSON.stringify(f), before);
});
const mutations = {
  'old encoder receipt after replacement': (f) => {
    const row = f.deliveryAudit.rows.find((r) => r.appliedRevision === '1'),
      old = f.deliveryAudit.rows[0];
    for (const key of [
      'receipt',
      'acknowledgedAt',
      'appliedRevision',
      'phase',
      'profileID',
      'videoBitrate',
    ])
      row[key] = structuredClone(old[key]);
    row.diagnostics.receipt = structuredClone(old.receipt);
    for (const e of row.history.encoded)
      if (e.encoding) {
        e.encoding.configuration = structuredClone(old.receipt.configuration);
        e.encoding.encoderSessionID = old.receipt.configuration.encoderSessionID;
      }
  },
  'foreign owned recording': (f) =>
    (f.expectedScope.recordingID = f.snapshot.scope.publishingAttemptID),
  'missing archive correspondence': (f) => (f.archiveIDs = []),
  'missing decoded output': (f) => (f.liveIDs = []),
  'forged fixed startup': (f) => f.startupFormat.firstCompressed.bytes++,
  'missing native application': (f) => (f.lifecycle.profileRequests = []),
  'withdrawn native authority': (f) =>
    (f.lifecycle.profileRequests[0].probeAuthorityPermitted = false),
  'invented final native bytes': (f) =>
    (f.nativeProbe.events.at(-1).sample.acceptedPayloadBytes = '0'),
  'missing receiver intervals': (f) => (f.receiverIntervals.intervals = []),
  'missing worker provenance': (f) => (f.workerRecords = []),
  'missing processing provenance': (f) => (f.processingEvidence = []),
  'missing publishing attempt': (f) => (f.attemptRecords = []),
  'missing candidate sources': (f) => f.candidateProof.measurement.encoding.frames.pop(),
  'forged admission load': (f) =>
    (f.quality.events.find(
      (e) => e.kind === 'candidate',
    ).candidateAdmission.deliveredPaddingBitsPerSecond *= 2),
  'missing healthy confirmation': (f) =>
    (f.quality.events.find((e) => e.reasons?.includes('trialConfirmed')).reasons = []),
  'missing cadence reports': (f) => (f.cadenceReports.rows = []),
  'missing delivery evidence': (f) => (f.deliveryAudit.rows = []),
  'foreign delivery profile': (f) => (f.deliveryAudit.rows[0].profileID = '1080p30'),
  'foreign delivery configuration': (f) =>
    (f.deliveryAudit.rows[0].receipt.configuration.id = f.snapshot.scope.publishingAttemptID),
  'deadline coverage gap': (f) =>
    (f.deliveryAudit.rows = f.deliveryAudit.rows.filter(
      (r) => r.appliedRevision !== '1' || r.end - r.start !== 1 || r.start % 2 === 0,
    )),
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

function recoveryPolicyInput(f, addRaw) {
  f.nativeProbe.formatVersion = 4;
  f.nativeProbe.policy = 'recovery-budget-v1';
  f.quality.formatVersion = 5;
  f.quality.transportPolicy = 'recovery-budget-v1';
  for (const value of [f.nativeProbe, f.quality, f.candidateProof, f.lifecycle]) addRaw(value);
  return f;
}
test('complete trial explicitly propagates recovery policy through independently recomputed gates', async () => {
  const { addSyntheticRecoveryProbeEvidence } =
    await import('./fixtures/recovery-policy-evidence.mjs');
  const f = recoveryPolicyInput(fixture(), addSyntheticRecoveryProbeEvidence),
    before = JSON.stringify(f);
  const result = module.qualifyMeasuredNativeTrial(f, { probePolicy: 'recovery-budget-v1' });
  assert.equal(result.measuredTrialQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.equal(result.probe.policy, 'recovery-budget-v1');
  assert.equal(result.witness.policy, 'recovery-budget-v1');
  assert.equal(result.policy.transportPolicy, 'recovery-budget-v1');
  assert.equal(JSON.stringify(f), before);
  assert.throws(() => qualify(f));
  assert.throws(() => module.qualifyMeasuredNativeTrial(f, { probePolicy: 'future-v1' }));
  for (const change of [
    (x) => (x.quality.transportPolicy = 'sender-delay-v1'),
    (x) => (x.quality.formatVersion = 4),
    (x) => (x.nativeProbe.policy = 'local-zero-loss-v1'),
    (x) => (x.lifecycle.profileRequests[0].currentProbe.policy = 'local-zero-loss-v1'),
    (x) => (x.candidateProof.probeBinding.final.id = '11111111-1111-1111-1111-111111111111'),
  ]) {
    const changed = structuredClone(f);
    change(changed);
    assert.throws(() =>
      module.qualifyMeasuredNativeTrial(changed, { probePolicy: 'recovery-budget-v1' }),
    );
  }
});
test('historical complete trial rejects unknown or recovery option against old evidence', () => {
  for (const probePolicy of ['future-v1', 'recovery-budget-v1', null])
    assert.throws(() => module.qualifyMeasuredNativeTrial(fixture(), { probePolicy }));
});
