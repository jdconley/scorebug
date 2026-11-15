import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { qualifyMeasuredNativeEvidence } from '../measured-native-trial.mjs';
import { qualifyMeasuredTrialConfirmedPrefix } from '../measured-trial-policy.mjs';
import { fixtureFrameID } from '../video-observation-qualification.mjs';
const module = await import('../measured-recovery-fault.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const { input } = JSON.parse(
  gunzipSync(
    fs.readFileSync(new URL('./fixtures/measured-recovery-PZGuFl.json.gz', import.meta.url)),
  ),
);
const evidence = qualifyMeasuredNativeEvidence(input, { recovery: true });
const prefix = qualifyMeasuredTrialConfirmedPrefix({
  quality: input.quality,
  snapshot: input.snapshot,
  sourceIntervalQualification: evidence.source,
  profileQualification: evidence.profile,
  lifecycleQualification: evidence.nativeLifecycle,
  candidateWitnessQualification: evidence.witness,
  cadenceReports: input.cadenceReports,
});
function fixture({ syntheticFresh = true } = {}) {
  const f = structuredClone({
    ...input,
    scope: input.snapshot.scope,
    prefix,
    sourceIntervalQualification: evidence.source,
    profileQualification: evidence.profile,
  });
  // Synthetic timing-only positive: PZGuFl itself has 273.134 ms pre-pause age.
  // Do not use this adjusted object as native-run evidence.
  if (syntheticFresh) {
    f.fault.beforePauseSample.requestStartedAt += 100;
    f.fault.beforePauseSample.receivedAt += 100;
  }
  return f;
}
function qualify(f) {
  assert.equal(typeof module.qualifyMeasuredRecoveryFault, 'function');
  return module.qualifyMeasuredRecoveryFault(f);
}
test('synthetic fresh timing variant binds post-confirmation source, raw stall, and exact reset without recovery credit', () => {
  const f = fixture(),
    before = JSON.stringify(f),
    result = qualify(f);
  assert.equal(result.faultQualified, true);
  assert.equal(result.recoveryQualified, false);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.equal(result.triggerEventIndex, 16);
  assert.equal(result.resetEventIndex, 17);
  assert.equal(result.triggerEvaluatedAt, f.quality.events[16].evaluatedAt);
  assert.equal(result.resetApplicationID, f.quality.events[17].application.id);
  assert.equal(result.prePauseSourceFrame, 2450);
  assert.equal(result.prePauseSourceIntervalSequence, '15');
  assert.equal(f.cadenceReports.rows[result.triggerCadenceReportIndex].observedStall, true);
  assert.equal(JSON.stringify(f), before);
});
test('immutable real PZGuFl artifact fails total pre-pause freshness budget', () => {
  assert.throws(
    () => qualify(fixture({ syntheticFresh: false })),
    /not fresh immediately before owned pause/,
  );
});
const mutations = {
  'wrong pause schedule': (f) => (f.fault.delayBeforePauseMs = 20000),
  'short pause': (f) => (f.fault.resumeSentAt = f.fault.pauseSentAt + 1799),
  'long pause': (f) => (f.fault.resumeSentAt = f.fault.pauseSentAt + 2501),
  'failed fault': (f) => (f.fault.failed = true),
  'reused decoder PID': (f) => (f.fault.identity.decoder.pid = f.fault.identity.worker.pid),
  'foreign parent': (f) => f.fault.identity.decoder.ppid++,
  'missing start identity': (f) => delete f.fault.identity.decoder.start,
  'wrong decoder binary': (f) => (f.fault.identity.decoder.command = '/usr/bin/sleep'),
  'stale pre-pause aggregate': (f) =>
    (f.fault.beforePauseSample.value.decoderCadenceAgeUpperBoundMs += 100),
  'before sample after pause': (f) =>
    (f.fault.beforePauseSample.receivedAt = f.fault.pauseSentAt + 1),
  'foreign pre-pause owner': (f) =>
    (f.fault.beforePauseSample.value.context.publication.publisherId = 'foreign'),
  'paused sample outside pause': (f) =>
    (f.fault.pausedSample.receivedAt = f.fault.resumeSentAt + 1),
  'different paused scope': (f) =>
    (f.fault.pausedSample.value.decoderCadence.scopeID = f.scope.publishingAttemptID),
  'different paused PTS': (f) =>
    (f.fault.pausedSample.value.decoderCadence.progress.lastFreshPTS += 3000),
  'PTS outside source intervals': (f) =>
    (f.fault.beforePauseSample.value.decoderCadence.progress.lastFreshPTS = 1),
  'fractional source mapping': (f) =>
    f.fault.beforePauseSample.value.decoderCadence.progress.lastFreshPTS++,
  'unqualified source interval': (f) =>
    (f.sourceIntervalQualification.intervals = f.sourceIntervalQualification.intervals.filter(
      (r) => r.sequence !== 15,
    )),
  'source boundary before confirmation': (f) =>
    (f.snapshot.sourceIntervals.find((r) => r.sequence === '15').captureBoundaryStartTime =
      f.prefix.confirmedAt - 1),
  'foreign source owner': (f) =>
    (f.snapshot.sourceIntervals.find((r) => r.sequence === '15').workerEpoch = 'foreign'),
  'missing archive frame': (f) => (f.archiveIDs = f.archiveIDs.filter((id) => id !== 2450)),
  'missing live frame': (f) => (f.liveIDs = f.liveIDs.filter((id) => id !== 2450)),
  'missing native frame': (f) =>
    (f.format.compressedFrames = f.format.compressedFrames.filter(
      (r) => fixtureFrameID(r.sourcePTS) !== 2450,
    )),
  'pre-pause outside 360 phase': (f) => (f.profileQualification.phases[1].lastFrame = 2449),
  'missing confirmation': (f) => (f.quality.events[12].reasons = []),
  'prefix points to later decision': (f) => (f.prefix.confirmedEventIndex = 15),
  'unsupported deadline trigger': (f) => (f.quality.events[16].kind = 'deliveryFailure'),
  'second decoder trigger': (f) =>
    f.quality.events.splice(17, 0, structuredClone(f.quality.events[16])),
  'foreign applied stall receipt': (f) =>
    (f.quality.events[16].receipt.configurationID = f.scope.recordingID),
  'foreign stall application': (f) => (f.quality.events[16].application.id = f.scope.recordingID),
  'invented competing failure signal': (f) =>
    (f.quality.events[16].deliveryFailure = { sequence: '13' }),
  'foreign stall acknowledgment': (f) => f.quality.events[16].acknowledgedAt--,
  'native pre-pause encoder relabeled': (f) =>
    (f.profileQualification.phases[1].encoderSessionID = f.scope.recordingID),
  'foreign stall revision': (f) => (f.quality.events[16].decoderStall.revision = '0'),
  'missing raw stall report': (f) =>
    (f.cadenceReports.rows = f.cadenceReports.rows.filter((r) => r.observedStall !== true)),
  'foreign native stall publisher': (f) =>
    f.cadenceReports.rows
      .filter((r) => r.observedStall)
      .forEach((r) => (r.response.status.publication.publisherId = 'foreign')),
  'expired native stall': (f) => (f.quality.events[16].evaluatedAt += 0.3),
  'reset wrong trigger sequence': (f) => (f.quality.events[17].application.windowSequence = '12'),
  'reset predates trigger': (f) =>
    (f.quality.events[17].application.admittedAt = f.quality.events[16].evaluatedAt - 1),
  'reset wrong action': (f) => (f.quality.events[17].action.kind = 'trial'),
  'reset wrong revision': (f) => (f.quality.events[17].revision = '3'),
  'reset carries candidate': (f) =>
    (f.quality.events[17].application.candidateID = f.quality.events[7].application.candidateID),
  'reset admission exceeds validity': (f) =>
    (f.quality.events[17].application.admittedAt = f.quality.events[17].action.validUntil + 0.001),
  'reset validUntil fabricated': (f) => (f.quality.events[17].action.validUntil += 0.1),
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

// Raw diagnostic B has an unrelated late cadence gap, so the whole run must fail.
// This leaf uses independently replayed source/profile facts and an explicit
// prefix dependency contract; it does not claim that all B prerequisites passed.
const { input: deliveryInput } = JSON.parse(
  gunzipSync(
    fs.readFileSync(new URL('./fixtures/measured-recovery-TPUMig.json.gz', import.meta.url)),
  ),
);
const { qualifyVideoObservation } = await import('../video-observation-qualification.mjs');
const { qualifyPublishingClockObservation } = await import('../publishing-clock-qualification.mjs');
const { qualifyWorkerPublicationEvidence } = await import('../worker-publication-evidence.mjs');
const { qualifySourceIntervals } = await import('../source-interval-qualification.mjs');
const { qualifyNativeProfileTransitions } = await import('../native-profile-transitions.mjs');
const bVideo = qualifyVideoObservation(deliveryInput);
const bClock = qualifyPublishingClockObservation({
  snapshot: deliveryInput.snapshot,
  expectedScope: bVideo.scope,
});
const bWorker = qualifyWorkerPublicationEvidence(deliveryInput.workerRecords, bVideo.scope);
const bSource = qualifySourceIntervals({
  ...deliveryInput,
  videoObservation: bVideo,
  publishingClockObservation: bClock,
  workerPublicationEvidence: bWorker,
});
const bProfile = qualifyNativeProfileTransitions(
  deliveryInput.format,
  deliveryInput.snapshot,
  deliveryInput.liveIDs,
  { sequence: 'measured240', requireFrameEvidence: true },
);
function deliveryFixture() {
  const confirmedEventIndex = deliveryInput.quality.events.findIndex((e) =>
    e.reasons?.includes('trialConfirmed'),
  );
  const event = deliveryInput.quality.events[confirmedEventIndex];
  return structuredClone({
    ...deliveryInput,
    scope: bVideo.scope,
    sourceIntervalQualification: bSource,
    profileQualification: bProfile,
    prefix: {
      proofExtent: 'confirmed-prefix',
      confirmed: 1,
      confirmedEventIndex,
      confirmedAt: event.evaluatedAt,
      confirmedEventAt: event.at,
    },
  });
}
test('raw B delivery-first leaf binds a pre-stall deadline signal to the same paused decoder without qualifying the whole run', () => {
  const f = deliveryFixture(),
    before = JSON.stringify(f),
    result = qualify(f);
  assert.equal(result.triggerKind, 'deliveryFailure');
  assert.equal(result.triggerDeliveryRowIndex, 97);
  assert.equal(result.triggerCadenceReportIndex, 784);
  assert.equal(result.stalledCadenceReportIndex, 785);
  assert.equal(result.lastStalledPTS, '6856081');
  assert.equal(result.faultQualified, true);
  assert.equal(result.recoveryQualified, false);
  assert.equal(JSON.stringify(f), before);
});
const deliveryMutations = {
  'forged failure count': (f) => f.quality.events[16].deliveryFailure.missingFrames++,
  'foreign delivery receipt': (f) =>
    (f.quality.events[16].deliveryFailure.deliveryReceiptID = f.scope.recordingID),
  'stale delivery decision': (f) => (f.quality.events[16].evaluatedAt += 0.3),
  'wrong delivery action': (f) => (f.quality.events[16].action.validUntil += 0.1),
  'wrong delivery reasons': (f) => (f.quality.events[16].reasons = ['stalled']),
  'invented delivery watchdog': (f) => (f.quality.events[16].decoderStall = { sequence: '13' }),
  'wrong delivery sequence': (f) => (f.quality.events[17].application.windowSequence = '14'),
  'wrong trigger frozen PTS': (f) =>
    (f.cadenceReports.rows[784].response.status.observation.decoderCadence.progress.lastFreshPTS += 3000),
  'missing later raw stall': (f) =>
    (f.cadenceReports.rows = f.cadenceReports.rows.filter((r) => !r.observedStall)),
  'foreign later raw stall': (f) =>
    f.cadenceReports.rows
      .filter((r) => r.observedStall)
      .forEach((r) => (r.response.status.publication.publisherId = 'foreign')),
  'stale later raw stall': (f) =>
    f.cadenceReports.rows
      .filter((r) => r.observedStall)
      .forEach((r) => (r.response.status.decoderCadenceAgeUpperBoundMs = 300)),
  'later stall different PTS': (f) =>
    f.cadenceReports.rows
      .filter((r) => r.observedStall)
      .forEach((r) => (r.response.status.observation.decoderCadence.progress.lastFreshPTS += 3000)),
  'later stall different scope': (f) =>
    f.cadenceReports.rows
      .filter((r) => r.observedStall)
      .forEach((r) => (r.response.status.observation.decoderCadence.scopeID = f.scope.recordingID)),
  'later resumed decoder missing': (f) =>
    (f.cadenceReports.rows = f.cadenceReports.rows.filter(
      (r) => r.evaluatedUptime <= f.cadenceReports.rows[795].evaluatedUptime,
    )),
};
for (const [name, mutate] of Object.entries(deliveryMutations))
  test(`delivery-first rejects ${name}`, () => {
    const f = deliveryFixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

const { input: twoSecondInput } = JSON.parse(
  gunzipSync(
    fs.readFileSync(new URL('./fixtures/measured-recovery-mnaRRb.json.gz', import.meta.url)),
  ),
);
const cEvidence = qualifyMeasuredNativeEvidence(twoSecondInput, { recovery: true });
const cPrefix = qualifyMeasuredTrialConfirmedPrefix({
  quality: twoSecondInput.quality,
  snapshot: twoSecondInput.snapshot,
  cadenceReports: twoSecondInput.cadenceReports,
  sourceIntervalQualification: cEvidence.source,
  profileQualification: cEvidence.profile,
  lifecycleQualification: cEvidence.nativeLifecycle,
  candidateWitnessQualification: cEvidence.witness,
});
const twoSecondFixture = () =>
  structuredClone({
    ...twoSecondInput,
    scope: cEvidence.scope,
    prefix: cPrefix,
    sourceIntervalQualification: cEvidence.source,
    profileQualification: cEvidence.profile,
  });
test('unchanged C two-second source-loss fault qualifies with full independently replayed prerequisites', () => {
  const f = twoSecondFixture(),
    before = JSON.stringify(f),
    r = qualify(f);
  assert.equal(r.triggerKind, 'deliveryFailure');
  assert.equal(r.triggerDeliveryRowIndex, 98);
  assert.equal(r.triggerCadenceReportIndex, 785);
  assert.equal(f.quality.events[r.triggerEventIndex].deliveryFailure.missingFrames, 5);
  assert.equal(r.faultQualified, true);
  assert.equal(r.recoveryQualified, false);
  assert.equal(JSON.stringify(f), before);
});
test('synthetic already-stalled current cadence preserves delivery priority without a decoder decision', () => {
  const f = twoSecondFixture(),
    first = 785,
    frozen =
      f.cadenceReports.rows[first].response.status.observation.decoderCadence.progress.lastFreshPTS;
  for (let i = first; i < f.cadenceReports.rows.length; i++) {
    const r = f.cadenceReports.rows[i],
      p = r.response.status.observation.decoderCadence.progress;
    if (p.lastFreshPTS !== frozen) break;
    p.ageMs += 400;
    p.stalled = p.ageMs >= 1000;
    r.observedStall = p.stalled;
  }
  const result = qualify(f);
  assert.equal(result.triggerKind, 'deliveryFailure');
  assert.equal(result.stalledCadenceReportIndex, first);
  assert(!f.quality.events.some((e) => e.kind === 'decoderStall'));
});
for (const [name, mutate] of Object.entries({
  'one-second reason on two-second failure': (f) =>
    (f.quality.events[16].reasons = ['freshFrameFloor']),
  'invented stall reason with nonzero delivery': (f) =>
    (f.quality.events[16].reasons = ['sourceLoss', 'stalled']),
  'invented stalled state with nonzero delivery': (f) => (f.quality.events[16].state = 'stalled'),
  'five-percent threshold forgery': (f) => {
    const d = f.quality.events[16].deliveryFailure;
    d.missingFrames = 2;
    d.onTimeFrames = 57;
  },
  'two-second foreign paused PTS': (f) =>
    (f.fault.pausedSample.value.decoderCadence.progress.lastFreshPTS += 3000),
}))
  test(`two-second fault rejects ${name}`, () => {
    const f = twoSecondFixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
