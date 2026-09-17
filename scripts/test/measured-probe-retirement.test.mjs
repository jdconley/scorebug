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
