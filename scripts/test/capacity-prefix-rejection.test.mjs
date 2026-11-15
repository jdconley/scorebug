import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { expandQualityEvidence } from '../quality-evidence-dictionary.mjs';
import { qualifyMeasuredNativeEvidence } from '../measured-native-trial.mjs';
import {
  qualifyMeasuredTrialConfirmedPrefix,
  qualifyMeasuredTrialPolicy,
} from '../measured-trial-policy.mjs';
const input = JSON.parse(
  gunzipSync(readFileSync(new URL('./fixtures/measured-capacity-5UYvcA.json.gz', import.meta.url))),
).input;
input.quality = expandQualityEvidence(input.quality);
const evidence = qualifyMeasuredNativeEvidence(input, {
  recovery: true,
  capacityRecovery: true,
  capacityDecrease: true,
  probePolicy: 'recovery-budget-v1',
});
const fixture = () =>
  structuredClone({
    quality: input.quality,
    snapshot: input.snapshot,
    cadenceReports: input.cadenceReports,
    sourceIntervalQualification: evidence.source,
    profileQualification: evidence.profile,
    lifecycleQualification: evidence.nativeLifecycle,
    candidateWitnessQualification: evidence.witness,
    transportPolicy: 'recovery-budget-v1',
    cadenceAuditMode: 'capacity',
    preTrialRejectionPolicy: 'invalidate-delivery-freshness-v1',
  });
const rejected = (f) => f.quality.events.find((e) => e.kind === 'rejected');
test('explicit pre-trial delivery invalidation preserves complete history and earns no healthy credit', () => {
  const f = fixture(),
    before = JSON.stringify(f),
    r = qualifyMeasuredTrialConfirmedPrefix(f);
  assert.equal(r.confirmed, 1);
  assert.equal(r.proofExtent, 'confirmed-prefix');
  assert.equal(r.rawEventCount, f.quality.events.length);
  assert.equal(r.upgradeAuthorized, false);
  assert.deepEqual(r.preTrialRejections, {
    policy: 'invalidate-delivery-freshness-v1',
    events: 1,
    healthyCreditSeconds: 0,
    rejectedSampleFreshnessQualified: false,
  });
  assert.equal(JSON.stringify(f), before);
});
for (const [name, change] of Object.entries({
  default: (f) => delete f.preTrialRejectionPolicy,
  unknownPolicy: (f) => (f.preTrialRejectionPolicy = 'ignore-all'),
  unknownReason: (f) => (rejected(f).reason = 'delivery-ownership'),
  changedReceipt: (f) => (rejected(f).receipt.bitRate = 1),
  changedRevision: (f) => (rejected(f).revision = '1'),
  changedProfile: (f) => (rejected(f).profileID = '360p30'),
  changedAcknowledgment: (f) => (rejected(f).acknowledgedAt += 0.01),
  closed: (f) => (rejected(f).closed = true),
  authority: (f) => (rejected(f).action = { kind: 'trial' }),
  inventedWindow: (f) => (rejected(f).window = { start: 1, end: 2 }),
  clock: (f) => (rejected(f).at = f.quality.events[0].at - 1),
  afterLastHealth: (f) => {
    const r = structuredClone(rejected(f));
    const i = f.quality.events.findIndex((e) => e.kind === 'applied');
    r.at = f.quality.events[i - 1].at + 0.00001;
    f.quality.events.splice(i, 0, r);
  },
  duringTrial: (f) => {
    const r = structuredClone(rejected(f));
    const i = f.quality.events.findIndex((e) => e.kind === 'candidate');
    const a = f.quality.events[i];
    Object.assign(r, {
      at: a.at + 0.00001,
      revision: '1',
      profileID: '360p30',
      receipt: a.receipt,
      acknowledgedAt: a.acknowledgedAt,
    });
    f.quality.events.splice(i + 1, 0, r);
  },
}))
  test(`pre-trial rejection replay rejects ${name}`, () => {
    const f = fixture();
    change(f);
    assert.throws(
      () => qualifyMeasuredTrialConfirmedPrefix(f),
      name === 'afterLastHealth' ? /Trial lacks healthy baseline/ : undefined,
    );
  });
test('complete static-trial replay does not accept capacity pre-trial exception', () =>
  assert.throws(() => qualifyMeasuredTrialPolicy(fixture())));
