import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { expandQualityEvidence } from '../quality-evidence-dictionary.mjs';
import { qualifyMeasuredNativeEvidence } from '../measured-native-trial.mjs';
const module = await import('../measured-capacity-policy.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const raw = JSON.stringify(
  Object.assign(
    {},
    ...['measured-capacity-5UYvcA', 'capacity-network-5UYvcA'].map(
      (n) =>
        JSON.parse(gunzipSync(readFileSync(new URL(`./fixtures/${n}.json.gz`, import.meta.url))))
          .input,
    ),
  ),
);
function fixture() {
  const f = JSON.parse(raw);
  f.quality = structuredClone(expandQualityEvidence(f.quality));
  return f;
}
function qualify(f, options = {}) {
  assert.equal(typeof module.qualifyMeasuredCapacityPolicy, 'function');
  return module.qualifyMeasuredCapacityPolicy(f, {
    profile: 'capacity750k',
    preTrialRejectionPolicy: 'invalidate-delivery-freshness-v1',
    ...options,
  });
}
const min = (f) => f.quality.events.filter((e) => e.kind === 'evaluated' && e.revision === '2');
const local = (f) =>
  f.quality.events.filter((e) => e.kind === 'localPressure' && e.revision === '2');
test('explicit congestion policy preserves the existing complete capacity result', () => {
  const f = fixture();
  assert.deepEqual(qualify(f, { capacityEvidencePolicy: 'congestion-v1' }), qualify(f));
});
test('native capacity evidence explicitly propagates bounded loss conservation without health credit', () => {
  const f = fixture();
  const options = {
    recovery: true,
    capacityRecovery: true,
    capacityDecrease: true,
    probePolicy: 'recovery-budget-v1',
  };
  const legacy = qualifyMeasuredNativeEvidence(f, options);
  const bounded = qualifyMeasuredNativeEvidence(f, {
    ...options,
    mediaLossPolicy: 'accounted-bounded-v1',
  });
  assert.equal(legacy.mediaConservation, undefined);
  assert.equal(bounded.video.lossConservation.policy, 'accounted-bounded-v1');
  assert.equal(bounded.mediaConservation.healthyCreditSeconds, 0);
  assert.equal(bounded.mediaConservation.productionUpgradeAuthorized, false);
  assert.deepEqual(bounded.profile, legacy.profile);
  assert.deepEqual(bounded.nativeLifecycle, legacy.nativeLifecycle);
  for (const patch of [
    { recovery: false },
    { capacityRecovery: false },
    { capacityDecrease: false },
  ])
    assert.throws(
      () =>
        qualifyMeasuredNativeEvidence(f, {
          ...options,
          ...patch,
          mediaLossPolicy: 'accounted-bounded-v1',
        }),
      /capacity|bounded/i,
    );
});
test('ledger capacity policy cannot reuse historical evidence without a newly observed ledger', () => {
  assert.throws(() => qualify(fixture(), { capacityEvidencePolicy: 'rate-ledger-v1' }), /ledger/i);
});
test('raw metadata cannot change the caller-selected capacity contract', () => {
  const f = fixture();
  const original = qualify(f);
  f.capacityEvidencePolicy = 'rate-ledger-v1';
  f.mediaLossPolicy = 'accounted-bounded-v1';
  assert.deepEqual(qualify(f), original);
});
for (const options of [
  null,
  false,
  [],
  { mediaLossPolicy: 'unknown' },
  { [Symbol('allowLoss')]: true },
  Object.defineProperty({}, 'allowLoss', { value: true }),
])
  test(`native evidence rejects malformed options ${String(options)}`, () => {
    assert.throws(() => qualifyMeasuredNativeEvidence(fixture(), options), /option|policy/i);
  });
function shiftClock(f, indices, seconds) {
  for (const i of indices) {
    f.capacityClockAudit.samples[i].nativeAt += seconds;
    f.capacityClockExchanges.exchanges[i].response.sample.nativeAt += seconds;
  }
}
test('joins raw capacity fault, confirmed prefix, owned decrease and post-restoration source/delivery recovery', () => {
  const f = fixture(),
    before = JSON.stringify(f),
    r = qualify(f);
  assert.equal(r.capacityPolicyQualified, true);
  assert.equal(r.nativeProfile?.phases.length, 3);
  assert.equal(r.profile, 'capacity750k');
  assert.equal(r.freshRampQualified, false);
  assert.equal(r.mediaFilesQualified, false);
  assert.equal(r.productionUpgradeAuthorized, false);
  assert(r.prefix.confirmedEventAt < r.clock.boundaries[0].nativeLower);
  assert(r.decrease.windowStart > r.clock.boundaries[0].nativeUpper);
  assert(r.recovery.start >= r.clock.boundaries[1].nativeUpper);
  assert(r.recovery.coverageSeconds >= 10);
  assert.equal(r.recovery.lanes.length, 2);
  assert(r.localPressureEvents >= 6);
  assert(r.sourceWindows > 10);
  assert.equal(r.finalProfile, '240p30');
  assert.equal(JSON.stringify(f), before);
});
for (const [name, mutate] of Object.entries({
  clockScope: (f) => (f.capacityClockExchanges.scope.recordingID = 'foreign'),
  earlyLimit: (f) => shiftClock(f, [0, 1], -40),
  pressureBeforeLimit: (f) => shiftClock(f, [0, 1], 15),
  restoreBeforeDecrease: (f) => shiftClock(f, [2, 3], -58),
  noRestoredCoverage: (f) => shiftClock(f, [2, 3], 100),
  missingMinPressure: (f) => f.quality.events.splice(f.quality.events.indexOf(local(f)[0]), 1),
  fakeMinPressure: (f) => (local(f)[1].window.transport = 'nominal'),
  pressureReasons: (f) =>
    (local(f)[0].reasons = local(f)[0].reasons.filter((r) => r !== 'minimumProfileInsufficient')),
  pressureAuthority: (f) => (local(f)[0].action = { kind: 'trial' }),
  pressureSequence: (f) => (local(f)[1].window.sequence = local(f)[0].window.sequence),
  missingSource: (f) => f.quality.events.splice(f.quality.events.indexOf(min(f)[4]), 1),
  repeatedSource: (f) => (min(f)[4].source.sequence = min(f)[3].source.sequence),
  skippedPolicy: (f) => (min(f)[3].window.sequence = String(Number(min(f)[3].window.sequence) + 1)),
  sourceFrameCount: (f) => min(f)[4].window.received--,
  sourceReceipt: (f) => (min(f)[4].receipt.bitRate = 600000),
  sourceAuthority: (f) => (min(f)[4].action = { kind: 'trial' }),
  sourceReasons: (f) => min(f)[4].reasons.push('trialConfirmed'),
  sourcePressure: (f) => (min(f)[4].window.transport = 'elevated'),
  sourceState: (f) => (min(f)[4].state = 'unknown'),
  sourceStale: (f) => (min(f)[4].evaluatedAt = min(f)[4].window.end + 3),
  forgedTransition: (f) => {
    const e = min(f)[4];
    e.kind = 'transition';
    delete e.window;
    delete e.reasons;
    delete e.state;
    delete e.evidence;
    delete e.evaluatedAt;
  },
  transitionCredit: (f) => {
    const e = f.quality.events.find((e) => e.kind === 'transition' && e.revision === '2');
    e.window = { start: e.source.start, end: e.source.end };
  },
  missingStop: (f) => f.quality.events.pop(),
  changedStop: (f) => (f.quality.events.at(-1).profileID = '360p30'),
  cadenceLoss: (f) => {
    const i = f.cadenceReports.rows.findIndex(
      (r) => r.evaluatedUptime > f.capacityClockAudit.samples[3].nativeAt,
    );
    f.cadenceReports.rows.splice(i, 10);
  },
  deliveryGap: (f) => {
    const i = f.deliveryAudit.rows.findIndex(
      (r) => r.start > f.capacityClockAudit.samples[3].nativeAt && r.end - r.start === 2,
    );
    f.deliveryAudit.rows.splice(i, 1);
  },
  lateDelivery: (f) => {
    const r = f.deliveryAudit.rows.find((r) => r.start > f.capacityClockAudit.samples[3].nativeAt);
    r.result.lateFrames = 1;
  },
  wrongDeliveryOwner: (f) => {
    const r = f.deliveryAudit.rows.find((r) => r.start > f.capacityClockAudit.samples[3].nativeAt);
    r.receipt.configuration.id = '00000000-0000-0000-0000-000000000000';
  },
}))
  test(`capacity policy rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
test('capacity policy requires the explicit matching trusted profile', () =>
  assert.throws(() => qualify(fixture(), { profile: 'capacity550k' })));
test('capacity policy keeps pre-trial rejection strict by default', () =>
  assert.throws(() => qualify(fixture(), { preTrialRejectionPolicy: 'reject' })));

test('capacity policy rejects an omitted explicit profile before replay', () =>
  assert.throws(
    () => qualify(fixture(), { profile: undefined }),
    /Unknown measured capacity profile/,
  ));
for (const count of [1, 3])
  test(`capacity policy rejects ${count} missing terminal source decisions`, () => {
    const f = fixture();
    const removed = new Set(min(f).slice(-count));
    f.quality.events = f.quality.events.filter((e) => !removed.has(e));
    assert.throws(() => qualify(f), /Unconsumed capacity source/);
  });
for (const durations of [[1], [2], [1, 2]])
  test(`capacity policy rejects terminal delivery truncation in lanes ${durations}`, () => {
    const f = fixture();
    const removed = new Set(
      durations.map((d) =>
        f.deliveryAudit.rows.findLast((r) => r.appliedRevision === '2' && r.end - r.start === d),
      ),
    );
    f.deliveryAudit.rows = f.deliveryAudit.rows.filter((r) => !removed.has(r));
    assert.throws(() => qualify(f), /Incomplete terminal delivery lane/);
  });
for (const duration of [1, 2])
  test(`capacity policy requires full probation delivery in lane ${duration}`, () => {
    const f = fixture(),
      { start, end } = qualify(f).prefix.probation;
    const index = f.deliveryAudit.rows.findIndex(
      (r) =>
        r.appliedRevision === '1' && r.end - r.start === duration && r.start > start && r.end < end,
    );
    assert(index >= 0);
    f.deliveryAudit.rows.splice(index, 1);
    assert.throws(() => qualify(f), /Gap or overlap in delivery coverage/);
  });
