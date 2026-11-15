import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedAdmissionFaultFixture } from './fixtures/repeated-policy-admission-evidence.mjs';
import { repeatedMeasuredPolicyFixture } from './fixtures/repeated-measured-policy-evidence.mjs';
import { qualifyRepeatedNativeAdmissions } from '../repeated-native-admission.mjs';
import { qualifyMeasuredNativeLifecycle } from '../measured-native-lifecycle.mjs';
import { qualifyRepeatedMeasuredPolicy } from '../repeated-measured-policy.mjs';
import { qualifyRepeatedNativeReadiness } from '../repeated-native-readiness.mjs';

function fixture(routes) {
  const f = repeatedMeasuredPolicyFixture(repeatedAdmissionFaultFixture(routes));
  // These are new synthetic raw contexts for the fixture's explicitly generated
  // health windows. No existing run or historical export is changed.
  for (const [index, campaign] of f.probe.campaigns.entries()) {
    const row = f.quality.events.find(
      (e) =>
        e.kind === 'evaluated' &&
        e.revision === String(index * 2) &&
        e.window.end === (index ? 172 : 112),
    );
    assert(row, 'Fixture needs fresh health before each native probe starts');
    Object.assign(campaign.context, {
      healthSequence: row.window.sequence,
      healthySince: index ? 161 : 104,
      healthyThrough: row.window.end,
    });
  }
  return f;
}
function qualify(f) {
  const admissions = qualifyRepeatedNativeAdmissions({ ...f, nativeProbe: f.probe });
  const lifecycle = qualifyMeasuredNativeLifecycle({ ...f, sequence: 'repeated240' });
  const policy = qualifyRepeatedMeasuredPolicy({
    ...f,
    lifecycleQualification: lifecycle,
    candidateWitnessQualifications: admissions.campaigns,
  });
  const readiness = qualifyRepeatedNativeReadiness({
    nativeProbe: f.probe,
    quality: f.quality,
    policyQualification: policy,
    scope: f.scope,
    publishingGeneration: f.format.publishingGeneration,
  });
  return { admissions, policy, readiness };
}
test('raw admissions and native lifecycle join both global policy cycles and captured readiness', () => {
  const f = fixture(),
    before = JSON.stringify(f),
    result = qualify(f);
  assert(
    result.admissions.admissionQualified &&
      result.policy.repeatedPolicyQualified &&
      result.readiness.readinessQualified,
  );
  assert.equal(result.policy.confirmations.length, 2);
  assert(result.policy.recoveries.every((r) => r.sharedCoverage.coverageSeconds >= 10));
  assert.equal(result.policy.productionUpgradeAuthorized, false);
  assert.equal(JSON.stringify(f), before);
});
test('a raw-valid second readiness context cannot invent healthy recovery', () => {
  const f = fixture();
  f.probe.campaigns[1].context.healthySince = 160.5;
  assert.equal(
    qualifyRepeatedNativeAdmissions({ ...f, nativeProbe: f.probe }).admissionQualified,
    true,
  );
  assert.throws(() => qualify(f));
});

for (const mutation of ['secondConfirmation', 'bridge', 'recoveryLane']) {
  test(`complete admissions do not authorize missing ${mutation}`, () => {
    const f = fixture();
    assert.equal(
      qualifyRepeatedNativeAdmissions({ ...f, nativeProbe: f.probe }).admissionQualified,
      true,
    );
    if (mutation === 'secondConfirmation') {
      f.quality.events.find(
        (e) => e.revision === '3' && e.reasons?.includes('trialConfirmed'),
      ).reasons = ['missingCapacity'];
    } else if (mutation === 'bridge') {
      f.quality.events.splice(
        f.quality.events.findIndex(
          (e) => e.kind === 'evaluated' && e.revision === '2' && e.window.end === 177,
        ),
        1,
      );
    } else {
      f.deliveryAudit.rows = f.deliveryAudit.rows.filter(
        (r) => r.appliedRevision !== '4' || r.end - r.start !== 2,
      );
    }
    assert.throws(() => qualify(f));
  });
}

for (const routes of [
  ['deliveryFailure', 'deliveryFailure'],
  ['decoderStall', 'deliveryFailure'],
  ['deliveryFailure', 'decoderStall'],
]) {
  test(`raw admission and readiness also compose with ${routes.join('/')}`, () => {
    const result = qualify(fixture(routes));
    assert.deepEqual(
      result.policy.faults.campaigns.map((c) => c.triggerKind),
      routes,
    );
    assert.equal(result.readiness.readinessQualified, true);
  });
}
