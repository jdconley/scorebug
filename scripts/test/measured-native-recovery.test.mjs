import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
const module = await import('../measured-native-recovery.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const fixture = (name = 'measured-recovery-mnaRRb', syntheticFresh = false) => {
  const f = JSON.parse(
    gunzipSync(fs.readFileSync(new URL(`./fixtures/${name}.json.gz`, import.meta.url))),
  ).input;
  // Unit-test timing variant only. The immutable PZGuFl native run failed its
  // 250ms freshness gate and must never be reported as qualified recovery.
  if (syntheticFresh && name === 'measured-recovery-PZGuFl') {
    f.fault.beforePauseSample.requestStartedAt += 100;
    f.fault.beforePauseSample.receivedAt += 100;
  }
  return f;
};
const qualify = (f) => {
  assert.equal(typeof module.qualifyMeasuredNativeRecovery, 'function');
  return module.qualifyMeasuredNativeRecovery(f);
};
test('independently replays unchanged C recovery evidence without relabeling its original harness failure', () => {
  const f = fixture(),
    before = JSON.stringify(f),
    r = qualify(f);
  assert.equal(r.measuredRecoveryQualified, true);
  assert.equal(r.productionUpgradeAuthorized, false);
  assert.equal(r.repeatedRampUpQualified, false);
  assert.equal(r.prefix.confirmed, 1);
  assert(r.recovery.sharedCoverage.coverageSeconds >= 10);
  assert.equal(r.profile.phases.length, 3);
  assert.equal(JSON.stringify(f), before);
});
test('synthetic fresh A timing still exercises the decoder-stall recovery composition', () => {
  assert.equal(qualify(fixture('measured-recovery-PZGuFl', true)).measuredRecoveryQualified, true);
});
test('immutable real PZGuFl cannot qualify with a stale pre-pause sample', () =>
  assert.throws(
    () => qualify(fixture('measured-recovery-PZGuFl', false)),
    /not fresh immediately before owned pause/,
  ));
test('immutable real TPUMig cannot qualify across a late control polling gap', () =>
  assert.throws(
    () => qualify(fixture('measured-recovery-TPUMig', false)),
    /Gap between usable reports exceeds 500 ms/,
  ));
test('successful unfaulted trial cannot claim recovery', () =>
  assert.throws(() => qualify(fixture('measured-trial-15qSdC'))));
const changes = {
  'missing fault': (f) => delete f.fault,
  'wrong fault schedule': (f) => (f.fault.delayBeforePauseMs = 20000),
  'unclosed pause': (f) => (f.fault.closed = false),
  'foreign decoder process': (f) => (f.fault.identity.decoder.ppid = f.fault.identity.worker.pid),
  'stale pre-fault sample': (f) =>
    (f.fault.beforePauseSample.value.decoderCadenceAgeUpperBoundMs = 300),
  'pre-fault progress predates confirmation': (f) =>
    (f.fault.beforePauseSample.value.decoderCadence.progress.lastFreshPTS = 90000),
  'missing confirmed prefix': (f) =>
    (f.quality.events.find((e) => e.reasons?.includes('trialConfirmed')).reasons = []),
  'reset bound to another decision': (f) =>
    (f.quality.events.filter((e) => e.kind === 'applied')[1].application.windowSequence = '999'),
  'unowned historical reset candidate': (f) =>
    (f.lifecycle.profileRequests[1].candidateMeasurementID =
      f.lifecycle.profileRequests[1].requestID),
  'missing recovery source window': (f) =>
    f.quality.events.splice(
      f.quality.events.findIndex((e) => e.kind === 'evaluated' && e.revision === '2') + 1,
      1,
    ),
  'missing minimum delivery lane': (f) =>
    (f.deliveryAudit.rows = f.deliveryAudit.rows.filter(
      (r) => r.appliedRevision !== '2' || r.end - r.start !== 2,
    )),
  'foreign minimum delivery profile': (f) =>
    (f.deliveryAudit.rows.find((r) => r.appliedRevision === '2').profileID = '360p30'),
  'missing native reset frames': (f) => f.format.compressedFrames.pop(),
  'stop with old revision': (f) => (f.quality.events.at(-1).revision = '1'),
};
for (const [name, mutate] of Object.entries(changes))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
