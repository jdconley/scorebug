import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
const module = await import('../measured-native-trial.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const fixture = () =>
  JSON.parse(
    gunzipSync(
      fs.readFileSync(new URL('./fixtures/measured-trial-15qSdC.json.gz', import.meta.url)),
    ),
  ).input;
const qualify = (f) => {
  assert.equal(typeof module.qualifyMeasuredNativeTrial, 'function');
  return module.qualifyMeasuredNativeTrial(f);
};
test('independently joins real raw native trial evidence without changing it', () => {
  const f = fixture(),
    before = JSON.stringify(f);
  const result = qualify(f);
  assert.equal(result.measuredTrialQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.equal(result.policy.confirmed, 1);
  assert.ok(result.policy.probation.coverageSeconds >= 10);
  assert.equal(result.delivery.observations.healthyRows, 147);
  assert.equal(result.source.intervals.length, 19);
  assert.equal(result.witness.headroomQualified, true);
  assert.equal(JSON.stringify(f), before);
});
const mutations = {
  'old encoder receipt after replacement': (f) => {
    const row = f.deliveryAudit.rows.find((r) => r.appliedRevision === '1'),
      old = f.deliveryAudit.rows[0];
    for (const key of [
      'receipt',
      'acknowledgedAt',
      'appliedRevision',
      'phase',
      'profileID',
      'videoBitrate',
    ])
      row[key] = structuredClone(old[key]);
    row.diagnostics.receipt = structuredClone(old.receipt);
    for (const e of row.history.encoded)
      if (e.encoding) {
        e.encoding.configuration = structuredClone(old.receipt.configuration);
        e.encoding.encoderSessionID = old.receipt.configuration.encoderSessionID;
      }
  },
  'foreign owned recording': (f) =>
    (f.expectedScope.recordingID = f.snapshot.scope.publishingAttemptID),
  'missing archive correspondence': (f) => (f.archiveIDs = []),
  'missing decoded output': (f) => (f.liveIDs = []),
  'forged fixed startup': (f) => f.startupFormat.firstCompressed.bytes++,
  'missing native application': (f) => (f.lifecycle.profileRequests = []),
  'withdrawn native authority': (f) =>
    (f.lifecycle.profileRequests[0].probeAuthorityPermitted = false),
  'invented final native bytes': (f) =>
    (f.nativeProbe.events.at(-1).sample.acceptedPayloadBytes = '0'),
  'missing receiver intervals': (f) => (f.receiverIntervals.intervals = []),
  'missing worker provenance': (f) => (f.workerRecords = []),
  'missing processing provenance': (f) => (f.processingEvidence = []),
  'missing publishing attempt': (f) => (f.attemptRecords = []),
  'missing candidate sources': (f) => f.candidateProof.measurement.encoding.frames.pop(),
  'forged admission load': (f) =>
    (f.quality.events.find(
      (e) => e.kind === 'candidate',
    ).candidateAdmission.deliveredPaddingBitsPerSecond *= 2),
  'missing healthy confirmation': (f) =>
    (f.quality.events.find((e) => e.reasons?.includes('trialConfirmed')).reasons = []),
  'missing cadence reports': (f) => (f.cadenceReports.rows = []),
  'missing delivery evidence': (f) => (f.deliveryAudit.rows = []),
  'foreign delivery profile': (f) => (f.deliveryAudit.rows[0].profileID = '1080p30'),
  'foreign delivery configuration': (f) =>
    (f.deliveryAudit.rows[0].receipt.configuration.id = f.snapshot.scope.publishingAttemptID),
  'deadline coverage gap': (f) =>
    (f.deliveryAudit.rows = f.deliveryAudit.rows.filter(
      (r) => r.appliedRevision !== '1' || r.end - r.start !== 1 || r.start % 2 === 0,
    )),
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

function recoveryPolicyInput(f, addRaw) {
  f.nativeProbe.formatVersion = 4;
  f.nativeProbe.policy = 'recovery-budget-v1';
  f.quality.formatVersion = 5;
  f.quality.transportPolicy = 'recovery-budget-v1';
  for (const value of [f.nativeProbe, f.quality, f.candidateProof, f.lifecycle]) addRaw(value);
  return f;
}
test('complete trial explicitly propagates recovery policy through independently recomputed gates', async () => {
  const { addSyntheticRecoveryProbeEvidence } =
    await import('./fixtures/recovery-policy-evidence.mjs');
  const f = recoveryPolicyInput(fixture(), addSyntheticRecoveryProbeEvidence),
    before = JSON.stringify(f);
  const result = module.qualifyMeasuredNativeTrial(f, { probePolicy: 'recovery-budget-v1' });
  assert.equal(result.measuredTrialQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.equal(result.probe.policy, 'recovery-budget-v1');
  assert.equal(result.witness.policy, 'recovery-budget-v1');
  assert.equal(result.policy.transportPolicy, 'recovery-budget-v1');
  assert.equal(JSON.stringify(f), before);
  assert.throws(() => qualify(f));
  assert.throws(() => module.qualifyMeasuredNativeTrial(f, { probePolicy: 'future-v1' }));
  for (const change of [
    (x) => (x.quality.transportPolicy = 'sender-delay-v1'),
    (x) => (x.quality.formatVersion = 4),
    (x) => (x.nativeProbe.policy = 'local-zero-loss-v1'),
    (x) => (x.lifecycle.profileRequests[0].currentProbe.policy = 'local-zero-loss-v1'),
    (x) => (x.candidateProof.probeBinding.final.id = '11111111-1111-1111-1111-111111111111'),
  ]) {
    const changed = structuredClone(f);
    change(changed);
    assert.throws(() =>
      module.qualifyMeasuredNativeTrial(changed, { probePolicy: 'recovery-budget-v1' }),
    );
  }
});
test('historical complete trial rejects unknown or recovery option against old evidence', () => {
  for (const probePolicy of ['future-v1', 'recovery-budget-v1', null])
    assert.throws(() => module.qualifyMeasuredNativeTrial(fixture(), { probePolicy }));
});

test('dictionary recovery export passes the same complete independent trial and preserves policy gates', async () => {
  const { addSyntheticRecoveryProbeEvidence } =
    await import('./fixtures/recovery-policy-evidence.mjs');
  const { dictionaryQualityFixture } = await import('./fixtures/quality-evidence-dictionary.mjs');
  const inline = recoveryPolicyInput(fixture(), addSyntheticRecoveryProbeEvidence);
  const expected = module.qualifyMeasuredNativeTrial(inline, { probePolicy: 'recovery-budget-v1' });
  const encoded = { ...inline, quality: dictionaryQualityFixture(inline.quality) },
    before = structuredClone(encoded);
  assert.deepEqual(
    module.qualifyMeasuredNativeTrial(encoded, { probePolicy: 'recovery-budget-v1' }),
    expected,
  );
  assert.deepEqual(encoded, before);
  assert.throws(() => qualify(encoded));
  const damaged = structuredClone(encoded);
  damaged.quality.evidenceDictionary.transport[0].droppedPackets = 100000;
  assert.throws(() =>
    module.qualifyMeasuredNativeTrial(damaged, { probePolicy: 'recovery-budget-v1' }),
  );
});

test('complete trial records the explicit delivery profile and preserves all other gates', () => {
  const f = fixture(),
    before = JSON.stringify(f);
  const strict = qualify(f);
  assert.equal(strict.deliveryProfile, 'strict30-v1');
  const floor = module.qualifyMeasuredNativeTrial(f, { deliveryProfile: 'floor24-v1' });
  assert.equal(floor.deliveryProfile, 'floor24-v1');
  assert.deepEqual({ ...floor, deliveryProfile: strict.deliveryProfile }, strict);
  assert.equal(JSON.stringify(f), before);
  for (const value of ['', null, 24, 'floor24-v2'])
    assert.throws(
      () => module.qualifyMeasuredNativeTrial(f, { deliveryProfile: value }),
      /delivery profile/i,
    );
});
for (const [name, mutate] of Object.entries(mutations))
  test(`floor24 complete trial still rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => module.qualifyMeasuredNativeTrial(f, { deliveryProfile: 'floor24-v1' }));
  });

test('full trial forwards explicit startup policy without granting recovery or production authority', async () => {
  const { addSyntheticRecoveryProbeEvidence } =
    await import('./fixtures/recovery-policy-evidence.mjs');
  const f = recoveryPolicyInput(fixture(), addSyntheticRecoveryProbeEvidence);
  const result = module.qualifyMeasuredNativeTrial(f, {
    probePolicy: 'recovery-budget-v1',
    startupPressurePolicy: 'minimum-before-source-v1',
  });
  assert.equal(result.measuredTrialQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.deepEqual(result.policy.startupPressure, {
    policy: 'minimum-before-source-v1',
    events: 0,
    healthyCreditSeconds: 0,
  });
});
for (const startupPressurePolicy of ['ignore', null, false, 'minimum-before-source-v1'])
  test(`full trial rejects startup policy without recovery transport ${startupPressurePolicy}`, () => {
    assert.throws(() => module.qualifyMeasuredNativeTrial(fixture(), { startupPressurePolicy }));
  });

function singleLossMediaFixture() {
  // Synthetic loss variant of the saved successful trial; original raw fixture is unchanged.
  const f = fixture(),
    row = f.snapshot.sourceIntervals[2];
  const id = (Number(row.sourceStartExclusive.value) - 7395) / 2 + 30;
  f.liveIDs = f.liveIDs.filter((value) => value !== id);
  row.decodedFrames--;
  row.encodedNotDecodedFrames++;
  for (const sample of f.decodedEvidence)
    if (sample.completed.sequence === Number(row.sequence)) sample.completed.freshFrames--;
  const decrement = (p) => {
    for (const key of ['decodedFrames', 'submittedFrames', 'completedFrames']) p.interval[key]--;
  };
  decrement(row.processing);
  for (const sample of f.processingEvidence)
    if (sample.processing.sequence === Number(row.sequence)) decrement(sample.processing);
  return { f, id, row };
}
const boundedMediaOptions = { mediaLossPolicy: 'accounted-bounded-v1' };
test('shared raw media reconciles explicit bounded loss to actual IDs, raw source, receiver and completed processing', () => {
  const { f, id, row } = singleLossMediaFixture(),
    before = structuredClone(f);
  const result = module.qualifyMeasuredNativeMedia(f, boundedMediaOptions);
  assert.equal(result.mediaConservation.rawCountersReconciled, true);
  assert.deepEqual(result.mediaConservation.missingEncodedIDs, [id]);
  assert.deepEqual(result.mediaConservation.accountedSourceIntervals, [
    {
      sequence: Number(row.sequence),
      missingIDs: [id],
      encodedFrames: 150,
      decodedFrames: 149,
      completedFrames: 149,
      durationSeconds: row.captureBoundaryEndTime - row.captureBoundaryStartTime,
      decodedFPS: 149 / (row.captureBoundaryEndTime - row.captureBoundaryStartTime),
      lossFraction: 1 / 150,
    },
  ]);
  assert.equal(result.mediaConservation.productionUpgradeAuthorized, false);
  assert.equal(result.mediaConservation.healthyCreditSeconds, 0);
  assert.deepEqual(f, before);
  assert.throws(() => module.qualifyMeasuredNativeMedia(f), /decoded/);
});
for (const [name, change] of Object.entries({
  'unaccounted identity': (f) => f.snapshot.sourceIntervals.splice(2, 1),
  'forged raw source count': (f) => f.snapshot.sourceIntervals[2].decodedFrames++,
  'forged receiver count': (f) => {
    for (const r of f.decodedEvidence) if (r.completed.sequence === 4) r.completed.freshFrames++;
  },
  'forged processing count': (f) =>
    f.snapshot.sourceIntervals[2].processing.interval.decodedFrames++,
  'missing processing': (f) => delete f.snapshot.sourceIntervals[2].processing,
  'pending processing': (f) => {
    const p = f.snapshot.sourceIntervals[2].processing.interval;
    p.completedFrames--;
    p.pendingFrames++;
    p.processingDuration = null;
  },
  'missing independent processing': (f) =>
    (f.processingEvidence = f.processingEvidence.filter((r) => r.processing.sequence !== 4)),
}))
  test(`shared bounded conservation rejects ${name}`, () => {
    const { f } = singleLossMediaFixture();
    change(f);
    assert.throws(() => module.qualifyMeasuredNativeMedia(f, boundedMediaOptions));
  });
test('shared media rejects unknown policy values and option keys', () => {
  for (const options of [
    { mediaLossPolicy: 'future' },
    { mediaLossPolicy: null },
    { allowLoss: true },
  ])
    assert.throws(() => module.qualifyMeasuredNativeMedia(fixture(), options), /option|policy/i);
});

test('raw source intervals retain their own conservative loss cap across observation boundaries', () => {
  const { f, id, row } = singleLossMediaFixture();
  const end = (Number(row.sourceEndInclusive.value) - 7395) / 2;
  // This source interval straddles two native observation windows. Keep one
  // absence per native window but exceed one percent in the joined raw span.
  const second = end - 1;
  assert.notEqual(Math.floor(id / 150), Math.floor(second / 150));
  // Shift this synthetic capture split five frames; encoded already splits at 892.
  const left = f.snapshot.completed[4].captureVideo;
  const right = f.snapshot.completed[5].captureVideo;
  for (const key of ['lastSourcePTS', 'highWaterSourcePTS'])
    left[key].value = String(7395 + 900 * 2);
  right.firstSourcePTS.value = String(7395 + 901 * 2);
  for (const key of ['callbackCount', 'advancingSourcePTSCount']) {
    left[key] = '145';
    right[key] = '155';
  }
  f.liveIDs = f.liveIDs.filter((value) => value !== second);
  row.decodedFrames--;
  row.encodedNotDecodedFrames++;
  for (const sample of f.decodedEvidence)
    if (sample.completed.sequence === Number(row.sequence)) sample.completed.freshFrames--;
  for (const p of [
    row.processing,
    ...f.processingEvidence
      .filter((s) => s.processing.sequence === Number(row.sequence))
      .map((s) => s.processing),
  ])
    for (const key of ['decodedFrames', 'submittedFrames', 'completedFrames']) p.interval[key]--;
  assert.throws(
    () => module.qualifyMeasuredNativeMedia(f, boundedMediaOptions),
    /source interval.*1%/i,
  );
});
test('raw source conservation preserves whole measured capture-boundary duration', () => {
  for (const duration of [0, 6.3]) {
    const { f, row } = singleLossMediaFixture();
    row.captureBoundaryStartTime = row.captureBoundaryEndTime - duration;
    assert.throws(
      () => module.qualifyMeasuredNativeMedia(f, boundedMediaOptions),
      /source interval.*24 fps/i,
    );
  }
});
test('raw artifacts cannot select a permissive media policy', () => {
  const { f } = singleLossMediaFixture();
  f.mediaLossPolicy = 'accounted-bounded-v1';
  assert.throws(() => module.qualifyMeasuredNativeMedia(f), /decoded/);
});

for (const [name, options] of [
  ['array', []],
  ['boolean', false],
  ['string', 'lossless-v1'],
  ['symbol key', { [Symbol('unknown')]: true }],
  ['hidden key', Object.defineProperty({}, 'unknown', { value: true })],
])
  test(`media options reject ${name}`, () => {
    assert.throws(() => module.qualifyMeasuredNativeMedia(fixture(), options), /option/i);
  });
