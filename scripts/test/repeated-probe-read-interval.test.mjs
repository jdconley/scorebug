import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedCandidateFixture } from './fixtures/repeated-candidate-evidence.mjs';
import { qualifyRepeatedNativeCandidateMeasurements } from '../repeated-native-candidate-measurement.mjs';
const fixture = () => {
  const f = repeatedCandidateFixture();
  f.proof.formatVersion = 5;
  for (const row of f.proof.campaigns)
    for (const sample of [
      row.measurement.probeBinding.initial,
      row.measurement.probeBinding.final,
    ]) {
      sample.readStartedAt = sample.observedAt - 0.0005;
      sample.readFinishedAt = sample.observedAt;
    }
  return f;
};
const qualify = (f) => qualifyRepeatedNativeCandidateMeasurements(f.proof, f.options);
const binding = (f) => f.proof.campaigns[1].measurement.probeBinding;
test('qualifies v5 native read intervals and returns its actual version', () => {
  assert.equal(qualify(fixture()).formatVersion, 5);
});
test('v5 accepts renewal between read and binding without retimestamping snapshot', () => {
  const f = fixture(),
    b = binding(f);
  b.observedAt = b.boundAt = 178.35;
  b.initial.observedAt = b.boundAt;
  assert.equal(qualify(f).formatVersion, 5);
});
test('v4 cannot enable read interval semantics by adding fields', () => {
  const f = fixture();
  f.proof.formatVersion = 4;
  assert.throws(() => qualify(f), /read interval|bracket/i);
});
for (const [name, mutate] of Object.entries({
  'missing initial bracket': (b) => delete b.initial.readStartedAt,
  'missing final bracket': (b) => delete b.final.readFinishedAt,
  'initial finishes after binding': (b) => (b.initial.readFinishedAt = b.boundAt + 0.01),
  'reversed initial bracket': (b) => (b.initial.readStartedAt = b.initial.readFinishedAt + 0.01),
  'final begins before measurement ends': (b) => (b.final.readStartedAt = 184.44),
  'final finishes after completion': (b) => (b.final.readFinishedAt = b.completedAt + 0.01),
  'future native acceptance': (b) => {
    b.initial.readStartedAt = 178.17;
    b.initial.readFinishedAt = 178.18;
  },
  'renewal from after read': (b) => {
    b.initial.readStartedAt = 178.19;
    b.initial.readFinishedAt = 178.199;
  },
  'history newer than read snapshot': (b) => {
    b.boundAt = b.initial.observedAt = 178.35;
    b.initial.readStartedAt = 178.32;
    b.initial.readFinishedAt = 178.33;
  },
}))
  test(`v5 rejects ${name}`, () => {
    const f = fixture();
    mutate(binding(f));
    assert.throws(() => qualify(f));
  });

import { repeatedReceiverIntervalFixture } from './fixtures/repeated-receiver-interval-evidence.mjs';
import { withRepeatedAdmissionWitnesses } from './fixtures/repeated-admission-witnesses.mjs';
import { qualifyRepeatedNativeAdmissions } from '../repeated-native-admission.mjs';
import { qualifyRepeatedProbeRetirements } from '../repeated-probe-retirement.mjs';
const admissionFixture = () => {
  const f = withRepeatedAdmissionWitnesses(repeatedReceiverIntervalFixture());
  f.candidateProof.formatVersion = 5;
  for (const c of f.candidateProof.campaigns)
    for (const p of [c.measurement.probeBinding.initial, c.measurement.probeBinding.final]) {
      p.readStartedAt = p.observedAt - 0.0005;
      p.readFinishedAt = p.observedAt;
    }
  return f;
};
const qualifyAdmission = (f) => qualifyRepeatedNativeAdmissions({ ...f, nativeProbe: f.probe });
function delayedBinding(f) {
  const b = f.candidateProof.campaigns[1].measurement.probeBinding;
  b.boundAt += 0.15;
  b.initial.observedAt = b.boundAt;
  f.lifecycle.profileRequests[2].probeBinding.boundAt = b.boundAt;
  f.quality.events.filter((e) => e.kind === 'candidate')[1].candidateAdmission.boundAt = b.boundAt;
  return f;
}
test('v5 intervals propagate through retirement, receiver and admission replay', () => {
  const f = delayedBinding(admissionFixture()),
    before = structuredClone(f);
  assert.equal(qualifyAdmission(f).admissionQualified, true);
  assert.deepEqual(f, before);
});
test('v4 retirement still rejects a cached binding retimestamped after renewal', () => {
  const f = delayedBinding(admissionFixture());
  f.candidateProof.formatVersion = 4;
  for (const c of f.candidateProof.campaigns)
    for (const p of [c.measurement.probeBinding.initial, c.measurement.probeBinding.final]) {
      delete p.readStartedAt;
      delete p.readFinishedAt;
    }
  assert.throws(() => qualifyRepeatedProbeRetirements(f.probe, { ...f }), /regresses history/);
});
for (const [name, mutate] of Object.entries({
  'missing candidate bracket': (f) =>
    delete f.candidateProof.campaigns[1].measurement.probeBinding.initial.readStartedAt,
  'crossed candidate campaign': (f) => (f.candidateProof.campaigns[1].campaign = '1'),
  'crossed candidate scope': (f) => (f.candidateProof.scope.recordingID = 'other'),
  'crossed measurement id': (f) =>
    (f.candidateProof.campaigns[1].measurement.measurement.id =
      '00000000-0000-4000-8000-000000000001'),
  'changed binding use instant': (f) =>
    (f.candidateProof.campaigns[1].measurement.probeBinding.boundAt += 0.001),
  'changed binding snapshot': (f) =>
    (f.candidateProof.campaigns[1].measurement.probeBinding.initial.acceptedPayloadBytes = '1316'),
  'final observation from future': (f) =>
    (f.candidateProof.campaigns[1].measurement.probeBinding.final.readFinishedAt += 1),
}))
  test(`standalone v5 retirement rejects ${name}`, () => {
    const f = admissionFixture();
    mutate(f);
    assert.throws(() => qualifyRepeatedProbeRetirements(f.probe, { ...f }));
  });
function renewalAfterCachedAdmission(f) {
  const events = f.probe.campaigns[1].events;
  const last = events.findLast((e) => e.sample.stage === 3 && e.sample.reason === null);
  const renewal = structuredClone(last);
  renewal.observedAt = 189.941;
  renewal.sample.leaseDeadline = 189.94 + 0.3;
  events.splice(events.indexOf(last) + 1, 0, renewal);
  for (const e of events)
    if (e.sample.stage === 3 && e.sample.reason !== null)
      e.sample.leaseDeadline = renewal.sample.leaseDeadline;
  for (const i of [2, 3])
    f.lifecycle.profileRequests[i].terminalProbeRead.observation.leaseDeadline =
      renewal.sample.leaseDeadline;
  return f;
}
test('v5 independently bounds cached admission read without borrowing final read interval', () => {
  const f = renewalAfterCachedAdmission(admissionFixture());
  assert.equal(qualifyAdmission(f).admissionQualified, true);
});
test('v4 keeps its original cached admission history check', () => {
  const f = renewalAfterCachedAdmission(admissionFixture());
  f.candidateProof.formatVersion = 4;
  for (const c of f.candidateProof.campaigns)
    for (const p of [c.measurement.probeBinding.initial, c.measurement.probeBinding.final]) {
      delete p.readStartedAt;
      delete p.readFinishedAt;
    }
  assert.throws(() => qualifyRepeatedProbeRetirements(f.probe, { ...f }), /regresses history/);
});
