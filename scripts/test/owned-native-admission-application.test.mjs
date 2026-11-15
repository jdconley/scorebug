import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import test from 'node:test';
import { decodeFixtureBarcodes } from '../video-observation-qualification.mjs';
const implementation = await import('../owned-native-admission-application.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const json = (p) => JSON.parse(readFileSync(new URL(`../../${p}`, import.meta.url)));
const provenance = (n) => json(`scripts/test/fixtures/${n}-LvDNAy.provenance.json`);
function load(p) {
  const compressed = readFileSync(new URL(`../../${p.fixture}`, import.meta.url));
  assert.equal(compressed.length, p.compressedBytes);
  const bytes = gunzipSync(compressed, { maxOutputLength: 8 * 1024 * 1024 });
  assert.equal(bytes.length, p.bytes);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), p.sha256);
  return bytes;
}
const receiver = provenance('owned-receiver'),
  intervals = provenance('owned-intervals');
const original = {
  ...receiver.options,
  rawOwned: JSON.parse(load(receiver.native)),
  records: JSON.parse(load(receiver.receiver)),
  intervals: JSON.parse(load(intervals.intervals)),
  workerRecords: JSON.parse(load(intervals.worker)),
  lifecycle: JSON.parse(load(provenance('owned-admission').lifecycle)),
  ...Object.fromEntries(
    Object.entries(provenance('owned-candidate').inputs).map(([k, p]) =>
      k === 'decoded' ? ['liveIDs', decodeFixtureBarcodes(load(p))] : [k, JSON.parse(load(p))],
    ),
  ),
};
const fixture = () => structuredClone(original);
function qualify(x = fixture()) {
  assert.equal(
    typeof implementation.qualifyOwnedNativeAdmissionApplication,
    'function',
    'owned admission/application join must exist',
  );
  return implementation.qualifyOwnedNativeAdmissionApplication(x);
}
const candidate = (x, n = 0) => x.quality.events.filter((e) => e.kind === 'candidate')[n];
const event = (x, kind, n = 0) => x.rawOwned.events.filter((e) => e.kind === kind)[n];
test('complete original history qualifies narrow admission/application with original indexes and failed owners', () => {
  const x = fixture(),
    before = structuredClone(x),
    r = qualify(x);
  assert.equal(r.eventCount, 540);
  assert.deepEqual(
    r.attempts.map((a) => a.campaign),
    ['1', '2', '3', '4'],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.admission?.qualityEventIndex ?? null),
    [5, null, null, 67],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.admission?.selectedIntervalIndexes ?? null),
    [[4, 5], null, null, [11, 12]],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.application?.transferEventIndex ?? null),
    [219, null, null, 528],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.application?.acknowledgementEventIndex ?? null),
    [228, null, null, 537],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.admission?.probeEventIndex ?? null),
    [218, null, null, 527],
  );
  assert.deepEqual(
    r.attempts.map((a) => a.application?.profileRequestIndex ?? null),
    [0, null, null, 2],
  );
  assert.equal(r.candidateAdmissionQualified, true);
  assert.equal(r.nativeApplicationCorrespondenceQualified, true);
  for (const key of [
    'mediaQualified',
    'recoveryQualified',
    'retryPolicyQualified',
    'upgradeAuthorized',
    'trialConfirmed',
  ])
    assert.equal(r[key], false, key);
  assert.deepEqual(x, before);
});
for (const [label, mutate] of [
  ['missing candidate', (x) => x.quality.events.splice(5, 1)],
  ['candidate UUID', (x) => (candidate(x).candidate.id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')],
  ['registered revision', (x) => (candidate(x).candidate.appliedRevision = '2')],
  ['baseline receipt', (x) => (candidate(x).candidateAdmission.applied.receipt.acceptedAt -= 0.01)],
  [
    'binding snapshot',
    (x) => (candidate(x).candidateAdmission.binding.acceptedPayloadBytes = '618520'),
  ],
  [
    'binding completion',
    (x) => (x.lifecycle.profileRequests[0].probeBinding.candidateCompletedAt -= 0.01),
  ],
  ['invented final snapshot', (x) => (x.lifecycle.profileRequests[0].probeBinding.final = {})],
  [
    'candidate measurement',
    (x) => candidate(x).candidateAdmission.measurement.transportMessageCount++,
  ],
  [
    'uncovered interval',
    (x) => (candidate(x).candidateAdmission.intervals[0].start.observedAtNanoseconds = '1'),
  ],
  ['reversed witness pair', (x) => candidate(x).candidateAdmission.intervals.reverse()],
  [
    'wire overhead arithmetic',
    (x) => (candidate(x).candidateAdmission.candidateTransportBitsPerSecond -= 1000),
  ],
  [
    'receiver clock projection',
    (x) => (candidate(x).candidateAdmission.clock.receiverClockOffsetUptimeBounds[0] += 0.01),
  ],
  [
    'evaluation chronology',
    (x) => (candidate(x).evaluatedAt = candidate(x).application.admittedAt + 1),
  ],
  [
    'application transfer UUID',
    (x) =>
      (event(x, 'applicationTransferred').applicationID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ],
  [
    'application acknowledgement UUID',
    (x) => (event(x, 'acknowledged').applicationID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ],
  [
    'application acknowledged revision',
    (x) => (event(x, 'acknowledged').currentAppliedRevision = '3'),
  ],
  ['acknowledgement receipt', (x) => (event(x, 'acknowledged').receipt.acceptedAt -= 0.01)],
  ['missing native request', (x) => x.lifecycle.profileRequests.splice(0, 1)],
  [
    'native candidate UUID',
    (x) =>
      (x.lifecycle.profileRequests[0].candidateMeasurementID =
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ],
  ['native request order', (x) => x.lifecycle.profileRequests.reverse()],
  [
    'bitrate request link',
    (x) =>
      (x.lifecycle.bitRateRequests[1].profileRequestID = x.lifecycle.profileRequests[2].requestID),
  ],
  ['bitrate request order', (x) => x.lifecycle.bitRateRequests.reverse()],
  ['native receipt', (x) => (x.lifecycle.profileRequests[0].receipt.acknowledgedAt -= 0.01)],
  [
    'native request chronology',
    (x) => (x.lifecycle.profileRequests[0].requestedAt = event(x, 'candidateRetired').at + 1),
  ],
  [
    'native terminal probe',
    (x) =>
      (x.lifecycle.profileRequests[0].terminalProbeRead.observation.acceptedPayloadBytes = '1316'),
  ],
  ['native closure', (x) => (x.lifecycle.isClosed = false)],
  ['partial native request', (x) => (x.lifecycle.profileRequests[0].outcome = 'failed')],
  [
    'failed owner suppression',
    (x) => {
      const id = event(x, 'registered', 1).ownerID;
      x.rawOwned.events = x.rawOwned.events.filter((e) => e.ownerID !== id);
    },
  ],
  [
    'failed owner fabricated transfer',
    (x) =>
      (event(x, 'candidateRetired', 1).applicationID = event(
        x,
        'applicationTransferred',
      ).applicationID),
  ],
])
  test(`rejects ${label}`, () => {
    const x = fixture();
    mutate(x);
    assert.throws(() => qualify(x));
  });
test('requires exactly the complete original inputs and trusted selectors', () => {
  for (const key of Object.keys(original)) {
    const x = fixture();
    delete x[key];
    assert.throws(() => qualify(x), key);
  }
  const x = fixture();
  x.prequalifiedAdmission = {};
  assert.throws(() => qualify(x));
});

test('receiver completion must follow the owned completion timestamp, not merely encoder end', () => {
  const x = fixture(),
    w = candidate(x).candidateAdmission;
  w.completedAt = w.clock.before - 0.000001;
  x.lifecycle.profileRequests[0].probeBinding.candidateCompletedAt = w.completedAt;
  assert.throws(() => qualify(x), /completion/);
});
test('native lifecycle retains the original 512KiB artifact bound', () => {
  const x = fixture();
  x.lifecycle.padding = 'x'.repeat(512 * 1024);
  assert.throws(() => qualify(x), /oversized lifecycle/);
});
for (const [label, mutate] of [
  ['missing original quality receipt', (x) => delete candidate(x).receipt],
  [
    'forged probe freshness under the 2000ms media profile',
    (x) => (candidate(x).candidateAdmission.intervals[1].end.snapshotAgeUpperBoundSeconds = 1.75),
  ],
  [
    'forged cached snapshot',
    (x) => (candidate(x).candidateAdmission.probe.acceptedPayloadBytes = '1316'),
  ],
  [
    'application predated witness',
    (x) =>
      (candidate(x).candidateAdmission.clock.after = candidate(x).application.admittedAt + 0.01),
  ],
  [
    'reordered cleanup',
    (x) =>
      (event(x, 'cleanupJoined').at = x.lifecycle.profileRequests[0].receipt.acknowledgedAt + 0.01),
  ],
  ['foreign binding campaign', (x) => (candidate(x).candidateAdmission.binding.campaign = '4')],
  ['lifecycle bounds', (x) => (x.lifecycle.closedAt = x.snapshot.captureDetachedAt + 3)],
  [
    'downward historical terminal',
    (x) =>
      (x.lifecycle.profileRequests[1].terminalProbeRead.observation.id =
        x.lifecycle.profileRequests[2].currentProbe.id),
  ],
  ['unowned candidate', (x) => x.quality.events.splice(6, 0, structuredClone(candidate(x)))],
  [
    'partial joined candidate',
    (x) => event(x, 'candidateJoined').measurement.encoding.frames.pop(),
  ],
  [
    'missing failed receiver stage',
    (x) => (x.records = x.records.filter((r) => r.probe.campaign !== '2')),
  ],
  ['missing worker history', (x) => (x.workerRecords = [])],
])
  test(`complete inputs reject ${label}`, () => {
    const x = fixture();
    mutate(x);
    assert.throws(() => qualify(x));
  });

test('normalized acknowledgement receipt accepts native UUID casing and keeps exact cost/headroom', () => {
  const x = fixture();
  for (const ack of x.rawOwned.events.filter((e) => e.kind === 'acknowledged')) {
    ack.receipt.configurationID = ack.receipt.configurationID.toUpperCase();
    ack.receipt.encoderSessionID = ack.receipt.encoderSessionID.toUpperCase();
    ack.applicationID = ack.applicationID.toUpperCase();
  }
  const r = qualify(x);
  for (const a of r.attempts.filter((a) => a.admission)) {
    const m = a.measurement,
      admission = a.admission;
    const cost =
      ((m.transport.transportBytes + 44 * m.transport.transportMessageCount) * 8) /
      Math.min(m.sourceDuration, m.submissionDuration);
    assert.equal(admission.candidateTransportBitsPerSecond, cost);
    assert.equal(admission.requiredPaddingBitsPerSecond, cost * 1.25);
    assert.equal(admission.headroomQualified, true);
  }
});

test('joined but incomplete owned application is unsupported rather than silently ignored', () => {
  const x = fixture();
  event(x, 'acknowledged').kind = 'policyState';
  assert.throws(() => qualify(x));
});

test('failed owner cannot hide application identity on its original registration', () => {
  const x = fixture();
  event(x, 'registered', 1).applicationID = event(x, 'applicationTransferred').applicationID;
  assert.throws(() => qualify(x), /failed owner carries application evidence/);
});
