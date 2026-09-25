import { addSyntheticRecoveryProbeEvidence } from './fixtures/recovery-policy-evidence.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { qualifyNativeBandwidthProbe } from '../native-bandwidth-probe.mjs';
const fixture = () =>
  JSON.parse(readFileSync(new URL('./fixtures/measured-probe-retirement.json', import.meta.url)));
const options = (f) => ({
  mode: 'staged',
  scope: f.probe.scope,
  publishingGeneration: f.probe.publishingGeneration,
  candidateHeadroom: true,
  measuredRetirement: { lifecycle: f.lifecycle, quality: f.quality },
});
const qualify = (f) => qualifyNativeBandwidthProbe(f.probe, options(f));
const request = (f) => f.lifecycle.profileRequests[0];
const candidate = (f) => f.quality.events.find((e) => e.kind === 'candidate');
const applied = (f) => f.quality.events.find((e) => e.kind === 'applied');

test('actual profile-cancelled probe requires explicit causal context and remains immutable', () => {
  const f = fixture(),
    before = structuredClone(f);
  const { measuredRetirement, ...strict } = options(f);
  assert.throws(() => qualifyNativeBandwidthProbe(f.probe, strict));
  const result = qualify(f);
  assert.equal(result.stages[2].retirementKind, 'profile-request-terminal-read');
  assert.equal(result.stages[2].profileRequestID, request(f).requestID);
  assert.equal(result.stages[2].retirementRequestedAt, request(f).requestedAt);
  assert.equal(result.stages[2].retiredObservedAt, request(f).terminalProbeRead.completedAt);
  assert.equal(result.acceptedPayloadBytes, 9485728);
  assert.equal(result.eventCount, f.probe.events.length);
  assert.deepEqual(f, before);
});

for (const [name, mutate] of Object.entries({
  'missing lifecycle': (f) => delete f.lifecycle,
  'missing quality': (f) => delete f.quality,
  'invalid lifecycle': (f) => (f.lifecycle.invalid = true),
  'overflow quality': (f) => (f.quality.overflow = true),
  'missing owned trial': (f) => (f.quality.events = [applied(f)]),
  'missing applied receipt': (f) => delete applied(f).profileReceipt,
  'forged profile receipt': (f) => (applied(f).profileReceipt.acknowledgedAt += 0.01),
  'wrong candidate ID': (f) => (request(f).candidateMeasurementID = request(f).requestID),
  'wrong application owner': (f) => (candidate(f).application.attemptID = request(f).requestID),
  'wrong application identity': (f) => (applied(f).application.id = request(f).requestID),
  'wrong from revision': (f) => (candidate(f).action.fromRevision = '8'),
  'no pre-authority': (f) => (request(f).authorityPermitted = false),
  'no probe authority': (f) => (request(f).probeAuthorityPermitted = false),
  'inactive current probe': (f) => (request(f).currentProbeActive = false),
  'current probe expired before request': (f) =>
    (request(f).requestedAt = request(f).currentProbe.leaseDeadline),
  'request after trial expiry': (f) =>
    (candidate(f).action.validUntil = request(f).requestedAt - 0.001),
  'request before admission': (f) =>
    (request(f).requestedAt = candidate(f).application.admittedAt - 0.001),
  'unbounded completion deadline': (f) => (candidate(f).application.completionDeadline += 10),
  'terminal read before completion': (f) =>
    (request(f).terminalProbeRead.startedAt = request(f).requestedAt),
  'terminal read inverted': (f) =>
    (request(f).terminalProbeRead.completedAt = request(f).terminalProbeRead.startedAt - 0.001),
  'terminal read after deadline': (f) =>
    (request(f).terminalProbeRead.completedAt =
      candidate(f).application.completionDeadline + 0.001),
  'wrong current probe ID': (f) => (request(f).currentProbe.id = request(f).requestID),
  'wrong terminal probe ID': (f) =>
    (request(f).terminalProbeRead.observation.id = request(f).requestID),
  'wrong terminal lease': (f) => (request(f).terminalProbeRead.observation.leaseDeadline += 0.01),
  'wrong current lease': (f) => (request(f).currentProbe.leaseDeadline += 0.01),
  'terminal counter mismatch': (f) =>
    (request(f).terminalProbeRead.observation.acceptedPayloadBytes = '7081396'),
  'current counter regression': (f) => (request(f).currentProbe.acceptedPayloadBytes = '0'),
  'non-profile terminal reason': (f) =>
    (request(f).terminalProbeRead.observation.reason = 'leaseExpired'),
  'non-profile final reason': (f) => (f.probe.events.at(-1).sample.reason = 'transportFailed'),
  'campaign counter mismatch': (f) =>
    (f.probe.events.at(-1).sample.totalAcceptedPayloadBytes = '9487044'),
  'earlier stage not retired': (f) =>
    (f.probe.events.find((e) => e.phase === 'retired').phase = 'final'),
  'failed request': (f) => (request(f).outcome = 'failed'),
  'ambiguous request': (f) => f.lifecycle.profileRequests.push(structuredClone(request(f))),
}))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('measured context cannot opt non-candidate or legacy mode into retirement', () => {
  const f = fixture();
  assert.throws(() =>
    qualifyNativeBandwidthProbe(f.probe, { ...options(f), candidateHeadroom: false }),
  );
  assert.throws(() =>
    qualifyNativeBandwidthProbe(f.probe, {
      ...options(f),
      mode: 'renew',
      candidateHeadroom: false,
    }),
  );
});

test('receiver revalidation requires and forwards the same causal context', async () => {
  const { qualifyNativeReceiverIntervals } = await import('../native-receiver-intervals.mjs');
  const f = fixture(),
    accepted = qualify(f);
  const args = [
    f.receiverIntervals,
    f.receiverRecords,
    f.probe.scope,
    accepted,
    f.workerRecords,
    f.probe,
  ];
  assert.throws(() => qualifyNativeReceiverIntervals(...args));
  const result = qualifyNativeReceiverIntervals(...args, {
    measuredRetirement: options(f).measuredRetirement,
  });
  assert.ok(result.intervalCount > 0);
  assert.equal(result.receiverCapacityQualified, false);
  request(f).terminalProbeRead.observation.acceptedPayloadBytes = '0';
  assert.throws(() =>
    qualifyNativeReceiverIntervals(...args, { measuredRetirement: options(f).measuredRetirement }),
  );
});

test('current pre-authority snapshot must remain fresh at the actual request', () => {
  const f = fixture();
  const later = candidate(f).candidate.evaluatedAt + 0.251;
  request(f).requestedAt = later;
  for (const e of f.quality.events) {
    e.action.validUntil = later + 0.001;
    e.application.admittedAt = later - 0.001;
    e.application.completionDeadline = later + 1.999;
  }
  assert.throws(() => qualify(f));
});

test('active binding must use a lease present in the raw campaign', () => {
  const f = fixture();
  request(f).probeBinding.observation.leaseDeadline += 0.00001;
  candidate(f).candidateAdmission.binding.leaseDeadline += 0.00001;
  assert.throws(() => qualify(f));
});

// Synthetic later reset extends the raw scalar fixture; it does not qualify
// failure causality or recovery, which require the parent's independent gates.
function recoveryFixture() {
  const f = fixture(),
    first = request(f),
    firstApplied = applied(f);
  const admittedAt = firstApplied.at + 30;
  const profileReceipt = {
    ...structuredClone(first.receipt),
    profile: '240p30',
    width: 426,
    height: 240,
    acknowledgedAt: admittedAt + 0.2,
    previousEncoderSessionID: first.receipt.encoderSessionID,
    encoderSessionID: 'a0000000-0000-4000-8000-000000000001',
  };
  const reset = {
    kind: 'applied',
    closed: false,
    at: admittedAt + 0.4,
    revision: '2',
    profileID: '240p30',
    acknowledgedAt: admittedAt + 0.3,
    action: {
      kind: 'reset',
      bitRate: 350000,
      profileID: '240p30',
      fromRevision: '1',
      candidateID: null,
      validUntil: admittedAt + 0.5,
    },
    application: {
      id: 'a0000000-0000-4000-8000-000000000002',
      attemptID: firstApplied.application.attemptID,
      fromRevision: '1',
      candidateID: null,
      admittedAt,
      completionDeadline: admittedAt + 2,
      windowSequence: '15',
    },
    profileReceipt,
    receipt: {
      ...structuredClone(firstApplied.receipt),
      bitRate: 350000,
      acceptedAt: admittedAt + 0.25,
      encoderSessionID: profileReceipt.encoderSessionID,
      configurationID: 'a0000000-0000-4000-8000-000000000003',
    },
  };
  const later = {
    ...structuredClone(first),
    requestID: 'a0000000-0000-4000-8000-000000000004',
    requestedAt: admittedAt + 0.01,
    completedAt: admittedAt + 0.21,
    targetProfile: '240p30',
    authorityPermitted: false,
    probeAuthorityPermitted: false,
    currentProbeActive: false,
    receipt: structuredClone(profileReceipt),
    terminalProbeRead: {
      startedAt: admittedAt + 0.22,
      completedAt: admittedAt + 0.23,
      observation: structuredClone(first.terminalProbeRead.observation),
    },
  };
  f.lifecycle.profileRequests.push(later);
  f.quality.events.push(reset);
  return f;
}
const qualifyRecovery = (f, recovery = true) =>
  qualifyNativeBandwidthProbe(f.probe, {
    ...options(f),
    measuredRetirement: { ...options(f).measuredRetirement, recovery },
  });
const resetRequest = (f) => f.lifecycle.profileRequests[1];
const resetApplied = (f) => f.quality.events.filter((e) => e.kind === 'applied')[1];

test('explicit recovery context permits exactly one later owned reset without changing first retirement', () => {
  const f = recoveryFixture(),
    before = structuredClone(f);
  assert.throws(() => qualify(f));
  assert.throws(() => qualifyRecovery(f, false));
  assert.deepEqual(qualifyRecovery(f), qualify(fixture()));
  assert.deepEqual(f, before);
  resetRequest(f).candidateMeasurementID = null;
  assert.deepEqual(qualifyRecovery(f), qualify(fixture()));
});

test('recovery context must be boolean and cannot silently accept a missing reset', () => {
  assert.throws(() => qualifyRecovery(fixture()));
  for (const value of [null, 'true', 1, {}])
    assert.throws(() => qualifyRecovery(recoveryFixture(), value));
  assert.deepEqual(qualifyRecovery(fixture(), false), qualify(fixture()));
});

for (const [name, mutate] of Object.entries({
  'extra request': (f) => f.lifecycle.profileRequests.push(structuredClone(resetRequest(f))),
  'extra application': (f) => f.quality.events.push(structuredClone(resetApplied(f))),
  'extra candidate': (f) => f.quality.events.push(structuredClone(candidate(f))),
  'reset before trial request': (f) => f.lifecycle.profileRequests.reverse(),
  'reset before trial application': (f) => f.quality.events.unshift(f.quality.events.pop()),
  'reused request ID': (f) => (resetRequest(f).requestID = request(f).requestID),
  'reused application ID': (f) => (resetApplied(f).application.id = applied(f).application.id),
  'foreign reset attempt': (f) =>
    (resetApplied(f).application.attemptID = resetRequest(f).requestID),
  'foreign historical candidate': (f) =>
    (resetRequest(f).candidateMeasurementID = resetRequest(f).requestID),
  'candidate reset action': (f) =>
    (resetApplied(f).action.candidateID = request(f).candidateMeasurementID),
  'candidate reset application': (f) =>
    (resetApplied(f).application.candidateID = request(f).candidateMeasurementID),
  'reset substituted as trial': (f) => (resetApplied(f).action.kind = 'trial'),
  'wrong reset target': (f) => (resetApplied(f).action.profileID = '360p30'),
  'wrong reset revision': (f) => (resetApplied(f).revision = '3'),
  'wrong reset from revision': (f) => (resetApplied(f).application.fromRevision = '0'),
  'early reset admission': (f) => (resetApplied(f).application.admittedAt = applied(f).at - 0.001),
  'early reset dispatch': (f) => (resetRequest(f).requestedAt = request(f).requestedAt),
  'reset after closure': (f) => (resetApplied(f).at = f.lifecycle.closedAt + 0.001),
  'missing reset terminal read': (f) => (resetRequest(f).terminalProbeRead = null),
  'foreign reset terminal probe': (f) =>
    (resetRequest(f).terminalProbeRead.observation.id = resetRequest(f).requestID),
  'changed reset terminal counters': (f) =>
    (resetRequest(f).terminalProbeRead.observation.acceptedPayloadBytes = '0'),
  'changed reset terminal lease': (f) =>
    (resetRequest(f).terminalProbeRead.observation.leaseDeadline += 0.1),
  'changed reset terminal reason': (f) =>
    (resetRequest(f).terminalProbeRead.observation.reason = 'closed'),
  'early reset terminal read': (f) =>
    (resetRequest(f).terminalProbeRead.startedAt = resetRequest(f).requestedAt),
  'failed reset': (f) => (resetRequest(f).outcome = 'failed'),
  'foreign reset receipt': (f) =>
    (resetApplied(f).profileReceipt.encoderSessionID = resetRequest(f).requestID),
  'wrong previous encoder': (f) => {
    resetRequest(f).receipt.previousEncoderSessionID = resetRequest(f).requestID;
    resetApplied(f).profileReceipt.previousEncoderSessionID = resetRequest(f).requestID;
  },
  'expired reset application': (f) =>
    (resetApplied(f).acknowledgedAt = resetApplied(f).application.completionDeadline + 0.01),
  'original retirement mismatch': (f) =>
    (request(f).terminalProbeRead.observation.acceptedPayloadBytes = '0'),
}))
  test(`recovery context rejects ${name}`, () => {
    const f = recoveryFixture();
    mutate(f);
    assert.throws(() => qualifyRecovery(f));
  });

test('receiver revalidation preserves the explicit recovery context', async () => {
  const { qualifyNativeReceiverIntervals } = await import('../native-receiver-intervals.mjs');
  const f = recoveryFixture();
  const args = [
    f.receiverIntervals,
    f.receiverRecords,
    f.probe.scope,
    qualifyRecovery(f),
    f.workerRecords,
    f.probe,
  ];
  assert.throws(() =>
    qualifyNativeReceiverIntervals(...args, { measuredRetirement: options(f).measuredRetirement }),
  );
  assert.ok(
    qualifyNativeReceiverIntervals(...args, {
      measuredRetirement: { ...options(f).measuredRetirement, recovery: true },
    }).intervalCount > 0,
  );
});

// Synthetic policy/raw evidence on the recorded scalar chronology. These unit
// fixtures are not a newly qualified native run or a network capacity claim.
function recoveryPolicyFixture() {
  const f = fixture();
  f.probe.formatVersion = 4;
  f.probe.policy = 'recovery-budget-v1';
  f.quality.formatVersion = 5;
  f.quality.transportPolicy = 'recovery-budget-v1';
  addSyntheticRecoveryProbeEvidence(f);
  return f;
}
const qualifyRecoveryPolicy = (f) =>
  qualifyNativeBandwidthProbe(f.probe, {
    ...options(f),
    policy: 'recovery-budget-v1',
  });
test('explicit recovery policy joins actual retirement chronology and raw preflight evidence', () => {
  const f = recoveryPolicyFixture(),
    before = structuredClone(f);
  const result = qualifyRecoveryPolicy(f);
  assert.equal(result.policy, 'recovery-budget-v1');
  assert.equal(result.stages[2].retirementKind, 'profile-request-terminal-read');
  assert.equal(result.receiverCapacityQualified, false);
  assert.deepEqual(f, before);
  assert.throws(() => qualify(f));
});
for (const [name, mutate] of Object.entries({
  oldQuality: (f) => (f.quality.formatVersion = 4),
  missingPressurePolicy: (f) => delete f.quality.transportPolicy,
  wrongPressurePolicy: (f) => (f.quality.transportPolicy = 'sender-delay-v1'),
  oldWitness: (f) => (candidate(f).candidateAdmission.formatVersion = 1),
  wrongWitnessConvention: (f) =>
    (candidate(f).candidateAdmission.convention = 'measured-candidate-ipv4-v1'),
  wrongCurrentPolicy: (f) => (request(f).currentProbe.policy = 'local-zero-loss-v1'),
  missingBindingRaw: (f) => delete request(f).probeBinding.observation.recoveryObservation,
  wrongTerminalRaw: (f) =>
    (request(f).terminalProbeRead.observation.recoveryObservation.rttMilliseconds += 1),
  wrongAdmissionRaw: (f) =>
    (candidate(f).candidateAdmission.probe.recoveryObservation.rttMilliseconds += 1),
  wrongAdmissionBindingRaw: (f) =>
    (candidate(f).candidateAdmission.binding.recoveryObservation.rttMilliseconds += 1),
  detachedCurrentChecks: (f) => {
    const raw = request(f).currentProbe.recoveryObservation;
    raw.checkedAt = request(f).currentProbe.startedAt;
    raw.sampledAt = raw.checkedAt;
    candidate(f).candidateAdmission.probe.recoveryObservation = structuredClone(raw);
  },
}))
  test(`recovery retirement rejects ${name}`, () => {
    const f = recoveryPolicyFixture();
    mutate(f);
    assert.throws(() => qualifyRecoveryPolicy(f));
  });
for (const path of ['current', 'binding', 'terminal', 'admission', 'admissionBinding'])
  test(`historical retirement rejects recovery metadata on ${path}`, () => {
    const f = fixture();
    const sample = {
      current: request(f).currentProbe,
      binding: request(f).probeBinding.observation,
      terminal: request(f).terminalProbeRead.observation,
      admission: candidate(f).candidateAdmission.probe,
      admissionBinding: candidate(f).candidateAdmission.binding,
    }[path];
    sample.policy = 'recovery-budget-v1';
    assert.throws(() => qualify(f));
  });
test('receiver interval replay requires explicit matching recovery policy and retirement context', async () => {
  const { qualifyNativeReceiverIntervals } = await import('../native-receiver-intervals.mjs');
  const f = recoveryPolicyFixture(),
    accepted = qualifyRecoveryPolicy(f);
  const args = [
    f.receiverIntervals,
    f.receiverRecords,
    f.probe.scope,
    accepted,
    f.workerRecords,
    f.probe,
  ];
  const context = {
    measuredRetirement: options(f).measuredRetirement,
    policy: 'recovery-budget-v1',
  };
  const result = qualifyNativeReceiverIntervals(...args, context);
  assert.ok(result.intervalCount > 0);
  assert.throws(() =>
    qualifyNativeReceiverIntervals(...args, { measuredRetirement: context.measuredRetirement }),
  );
  assert.throws(() => qualifyNativeReceiverIntervals(...args, { ...context, policy: 'future-v1' }));
});

// A renewal can finish before an older async binding read returns. Read completion
// order must not manufacture additional accepted packets or move their timestamp.
function bindingCompletesAfterUnchangedRenewal(make) {
  const f = make(),
    binding = request(f).probeBinding;
  const renewed = f.probe.events.find(
    (e) =>
      e.phase === 'renewed' &&
      e.sample.stage === 3 &&
      e.sample.acceptedPayloadBytes === binding.observation.acceptedPayloadBytes &&
      e.sample.lastAcceptedAt === binding.observation.lastAcceptedAt &&
      e.observedAt > binding.boundAt,
  );
  assert.ok(renewed);
  binding.boundAt = renewed.observedAt + 0.000001;
  candidate(f).candidateAdmission.boundAt = binding.boundAt;
  return { f, renewed };
}
for (const [name, make, validate] of [
  ['historical', fixture, qualify],
  ['recovery', recoveryPolicyFixture, qualifyRecoveryPolicy],
]) {
  test(`${name} retirement accepts unchanged acceptance when an older binding read finishes after renewal`, () => {
    const { f } = bindingCompletesAfterUnchangedRenewal(make),
      before = structuredClone(f);
    assert.equal(validate(f).stages[2].retirementKind, 'profile-request-terminal-read');
    assert.deepEqual(f, before);
  });
  test(`${name} retirement still rejects extra packets beyond one-token credit after renewal`, () => {
    const { f, renewed } = bindingCompletesAfterUnchangedRenewal(make);
    const binding = request(f).probeBinding.observation;
    binding.acceptedPayloadBytes = String(BigInt(binding.acceptedPayloadBytes) + 2632n);
    binding.lastAcceptedAt = renewed.sample.leaseDeadline - 0.3 + 0.00001;
    candidate(f).candidateAdmission.binding = structuredClone(binding);
    if (name === 'recovery') addSyntheticRecoveryProbeEvidence(f);
    assert.throws(() => validate(f), /active observation exceeds token budget/);
  });
  test(`${name} retirement rejects changing acceptance time without accepting packets`, () => {
    const { f } = bindingCompletesAfterUnchangedRenewal(make);
    request(f).probeBinding.observation.lastAcceptedAt += 0.00001;
    candidate(f).candidateAdmission.binding = structuredClone(request(f).probeBinding.observation);
    if (name === 'recovery') addSyntheticRecoveryProbeEvidence(f);
    assert.throws(() => validate(f));
  });
}
