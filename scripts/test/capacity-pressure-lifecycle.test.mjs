import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { expandQualityEvidence } from '../quality-evidence-dictionary.mjs';
import { qualifyNativeProfileTransitions } from '../native-profile-transitions.mjs';
import { qualifyMeasuredNativeLifecycle } from '../measured-native-lifecycle.mjs';
import { qualifyMeasuredNativeEvidence } from '../measured-native-trial.mjs';
const raw = gunzipSync(
  readFileSync(new URL('./fixtures/measured-capacity-5UYvcA.json.gz', import.meta.url)),
).toString();
function fixture() {
  const f = JSON.parse(raw).input;
  f.quality = structuredClone(expandQualityEvidence(f.quality));
  return f;
}
function lifecycle(f, options = {}) {
  return qualifyMeasuredNativeLifecycle({
    ...f,
    profileQualification: qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
      sequence: 'measured240',
      requireFrameEvidence: true,
    }),
    recovery: true,
    probePolicy: 'recovery-budget-v1',
    capacityDecrease: true,
    ...options,
  });
}
const pressure = (f) => f.quality.events.find((e) => e.kind === 'localPressure');
const decrease = (f) => f.quality.events.filter((e) => e.kind === 'applied')[1];
const prior = (f) => f.quality.events[f.quality.events.indexOf(pressure(f)) - 1];
test('explicit capacity decrease joins raw transport pressure and native receipts without granting recovery', () => {
  const f = fixture(),
    before = JSON.stringify(f),
    r = lifecycle(f);
  assert.equal(r.nativeLifecycleReceiptsMatched, true);
  assert.equal(r.capacityDecrease.recoveryQualified, false);
  assert.equal(r.capacityDecrease.pressureEventIndex, f.quality.events.indexOf(pressure(f)));
  assert.equal(r.capacityDecrease.windowSequence, decrease(f).application.windowSequence);
  assert.equal(r.capacityDecrease.applicationID, decrease(f).application.id);
  assert.deepEqual(
    r.applications.map((a) => a.target),
    ['360p30', '240p30'],
  );
  assert.equal(r.upgradeAuthorized, false);
  assert.equal(JSON.stringify(f), before);
});
test('capacity evidence composes local decrease through retirement without granting complete recovery', () => {
  const r = qualifyMeasuredNativeEvidence(fixture(), {
    recovery: true,
    capacityRecovery: true,
    capacityDecrease: true,
    probePolicy: 'recovery-budget-v1',
  });
  assert.equal(r.nativeLifecycle.capacityDecrease.recoveryQualified, false);
  assert.equal(r.nativeLifecycle.applications.length, 2);
  assert.equal(r.witness.headroomQualified, true);
});
for (const [name, options] of Object.entries({
  default: { capacityDecrease: false },
  nonboolean: { capacityDecrease: 'true' },
  noRecovery: { recovery: false },
  wrongPolicy: { probePolicy: 'local-zero-loss-v1' },
  repeated: { sequence: 'repeated240' },
}))
  test(`capacity decrease rejects ${name} context`, () =>
    assert.throws(() => lifecycle(fixture(), options)));
test('outer evidence cannot select pressure decrease without the capacity route', () =>
  assert.throws(() =>
    qualifyMeasuredNativeEvidence(fixture(), {
      recovery: true,
      capacityDecrease: true,
      probePolicy: 'recovery-budget-v1',
    }),
  ));
for (const [name, mutate] of Object.entries({
  missingPressure: (f) => f.quality.events.splice(f.quality.events.indexOf(pressure(f)), 1),
  disguisedReset: (f) => (decrease(f).action.kind = 'reset'),
  receipt: (f) => (pressure(f).receipt.configurationID = '00000000-0000-0000-0000-000000000000'),
  trialMetadata: (f) => (pressure(f).application.id = '00000000-0000-0000-0000-000000000000'),
  revision: (f) => (pressure(f).window.revision = '0'),
  reusedSequence: (f) => (pressure(f).window.sequence = prior(f).window.sequence),
  skippedSequence: (f) =>
    (pressure(f).window.sequence = String(Number(pressure(f).window.sequence) + 1)),
  appliedSequence: (f) => (decrease(f).application.windowSequence = '1'),
  stalePressure: (f) => (pressure(f).evaluatedAt = pressure(f).window.end + 2.01),
  futurePressure: (f) => (pressure(f).evaluatedAt = pressure(f).at + 1),
  earlyAdmission: (f) => (decrease(f).application.admittedAt = pressure(f).at - 0.01),
  expiry: (f) => (decrease(f).action.validUntil += 1),
  missingReason: (f) =>
    (pressure(f).reasons = pressure(f).reasons.filter((r) => r !== 'transportPressure')),
  inventedHealth: (f) => (pressure(f).state = 'healthy'),
  falseTransport: (f) => (pressure(f).window.transport = 'nominal'),
  changedRawGeneration: (f) => (pressure(f).evidence.local.clockGeneration = '999'),
  closedIngress: (f) => (pressure(f).evidence.local.ingressClosed = true),
  falseReceipt: (f) => (pressure(f).evidence.local.receipt.bitRate = 350000),
  noRawPressure: (f) =>
    pressure(f).evidence.transport.samples.forEach((s) => {
      s.rttMilliseconds = 1;
      s.senderBufferMilliseconds = 0;
      s.droppedPackets = 0;
    }),
  overlappingPrior: (f) => (prior(f).window.end = pressure(f).window.start + 0.01),
  activeAuthority: (f) => (f.lifecycle.profileRequests[1].authorityPermitted = true),
  foreignHistoricalCandidate: (f) =>
    (f.lifecycle.profileRequests[1].candidateMeasurementID =
      '00000000-0000-0000-0000-000000000000'),
  changedHistoricalProbe: (f) => (f.lifecycle.profileRequests[1].currentProbe.lastAcceptedAt += 1),
}))
  test(`capacity decrease rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => lifecycle(f));
  });
