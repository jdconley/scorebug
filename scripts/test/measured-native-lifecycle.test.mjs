import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { qualifyNativeProfileTransitions } from '../native-profile-transitions.mjs';
const module = await import('../measured-native-lifecycle.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const fixture = () =>
  JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-trial-15qSdC.json.gz', import.meta.url)),
    ).toString(),
  ).input;
const qualify = (f) => {
  assert.equal(
    typeof module.qualifyMeasuredNativeLifecycle,
    'function',
    'Measured lifecycle verifier is required',
  );
  const profileQualification = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
    sequence: 'measured240',
    requireFrameEvidence: true,
  });
  return module.qualifyMeasuredNativeLifecycle({ ...f, profileQualification });
};
test('joins actual minimum startup and owned native receipts without changing invalid fixed proof', () => {
  const f = fixture(),
    before = JSON.stringify(f.startupFormat);
  const r = qualify(f);
  assert.equal(r.nativeLifecycleReceiptsMatched, true);
  assert.equal(r.startup.profile, '240p30');
  assert.equal(r.applications.length, 1);
  assert.equal(r.applications[0].target, '360p30');
  assert.equal(r.upgradeAuthorized, false);
  assert.equal(JSON.stringify(f.startupFormat), before);
});
const mutations = {
  'startup before attempt clock': (f) => {
    f.startupFormat.startup.submittedAt = 0;
    f.startupFormat.firstEncoding.submittedAt = 0;
  },
  'startup contradicts maximum encoder latency': (f) => {
    f.startupFormat.startup.submittedAt = f.snapshot.monotonicAnchor;
    f.startupFormat.firstEncoding.submittedAt = f.snapshot.monotonicAnchor;
  },
  'bitrate request before attempt clock': (f) => (f.lifecycle.bitRateRequests[0].requestedAt = 0),
  'misbound startup encoder': (f) =>
    (f.startupFormat.startup.encoderSessionID =
      f.lifecycle.profileRequests[0].receipt.encoderSessionID),
  'startup after bootstrap': (f) =>
    (f.startupFormat.startup.observedAt = f.quality.events[0].at + 1),
  'different first compressed bytes': (f) => f.startupFormat.firstCompressed.bytes++,
  'invented initial sample': (f) =>
    (f.startupFormat.firstEncoding.sourcePTS.value = String(
      BigInt(f.startupFormat.firstEncoding.sourcePTS.value) + 2n,
    )),
  'missing native profile request': (f) => (f.lifecycle.profileRequests = []),
  'native request before admission': (f) => (f.lifecycle.profileRequests[0].requestedAt -= 1),
  'expired application completion': (f) =>
    (f.quality.events.find((e) => e.kind === 'applied').application.completionDeadline -= 2),
  'bitrate misbound to profile': (f) =>
    (f.lifecycle.bitRateRequests[1].profileRequestID = f.lifecycle.bitRateRequests[0].requestID),
  'ambiguous bitrate overlap': (f) =>
    (f.lifecycle.bitRateRequests[1].profileLinkUnambiguous = false),
  'wrong candidate': (f) =>
    (f.lifecycle.profileRequests[0].candidateMeasurementID =
      f.lifecycle.profileRequests[0].requestID),
  'revoked authority': (f) => (f.lifecycle.profileRequests[0].authorityPermitted = false),
  'late terminal read': (f) => (f.lifecycle.profileRequests[0].terminalProbeRead.completedAt += 5),
  'unclosed lifecycle': (f) => (f.lifecycle.isClosed = false),
  'overflow lifecycle': (f) => (f.lifecycle.overflow = true),
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('lifecycle explicitly binds recovery policy to all raw profile request observations', async () => {
  const { addSyntheticRecoveryProbeEvidence } =
    await import('./fixtures/recovery-policy-evidence.mjs');
  const f = fixture();
  f.probePolicy = 'recovery-budget-v1';
  f.quality.formatVersion = 5;
  f.quality.transportPolicy = f.probePolicy;
  addSyntheticRecoveryProbeEvidence(f.lifecycle);
  const result = qualify(f);
  assert.equal(result.probePolicy, 'recovery-budget-v1');
  for (const change of [
    (x) => delete x.probePolicy,
    (x) => (x.probePolicy = 'future-v1'),
    (x) => (x.quality.formatVersion = 4),
    (x) => (x.quality.transportPolicy = 'sender-delay-v1'),
    (x) => (x.lifecycle.profileRequests[0].currentProbe.policy = 'local-zero-loss-v1'),
    (x) =>
      (x.lifecycle.profileRequests[0].terminalProbeRead.observation.id =
        '11111111-1111-1111-1111-111111111111'),
  ]) {
    const changed = structuredClone(f);
    change(changed);
    assert.throws(() => qualify(changed));
  }
});
test('historical lifecycle rejects recovery policy metadata', () => {
  const f = fixture();
  f.lifecycle.profileRequests[0].currentProbe.policy = 'recovery-budget-v1';
  assert.throws(() => qualify(f));
});
