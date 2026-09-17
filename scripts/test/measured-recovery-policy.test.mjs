import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { gunzipSync } from 'node:zlib';
import { qualifyMeasuredNativeEvidence } from '../measured-native-trial.mjs';
import { qualifyMeasuredTrialConfirmedPrefix } from '../measured-trial-policy.mjs';
const { qualifyMeasuredRecoveryPolicy } = await import('../measured-recovery-policy.mjs').catch(
  (e) => {
    if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
    return {};
  },
);
const raw = JSON.parse(
  gunzipSync(
    fs.readFileSync(new URL('./fixtures/measured-recovery-PZGuFl.json.gz', import.meta.url)),
  ),
).input;
const evidence = qualifyMeasuredNativeEvidence(raw, { recovery: true });
const base = {
  ...raw,
  sourceIntervalQualification: evidence.source,
  profileQualification: evidence.profile,
  lifecycleQualification: evidence.nativeLifecycle,
  candidateWitnessQualification: evidence.witness,
};
base.prefix = qualifyMeasuredTrialConfirmedPrefix(base);
// Isolated fault dependency contract only: PZGuFl's real pre-pause observation
// failed the 250-ms fault gate. This suite never claims whole recovery success.
base.faultQualification = {
  triggerEventIndex: 16,
  resetEventIndex: 17,
  triggerEvaluatedAt: raw.quality.events[16].evaluatedAt,
  resetApplicationID: raw.quality.events[17].application.id,
  resetAcknowledgedAt: raw.quality.events[17].acknowledgedAt,
  decoderScopeID: raw.quality.events[16].decoderStall.scopeID,
  lastStalledPTS: raw.quality.events[16].decoderStall.lastFreshPTS,
};
const fixture = () => structuredClone(base);
const qualify = (f) => {
  assert.equal(typeof qualifyMeasuredRecoveryPolicy, 'function');
  return qualifyMeasuredRecoveryPolicy(f);
};
const post = (f) => f.quality.events.filter((e) => e.kind === 'evaluated' && e.revision === '2');
test('replays actual reset suffix and grants only whole windows covered by both healthy delivery lanes', () => {
  const f = fixture(),
    before = JSON.stringify(f),
    r = qualify(f);
  assert.equal(JSON.stringify(f), before);
  assert.equal(r.recoveryPolicyQualified, true);
  assert.equal(r.productionUpgradeAuthorized, false);
  assert.equal(r.healthyWindows.length, 5);
  assert.equal(r.sharedCoverage.start, post(f)[1].window.start);
  assert.equal(r.sharedCoverage.end, post(f)[3].window.end);
  assert(r.sharedCoverage.coverageSeconds >= 10);
  assert.equal(r.sharedCoverage.windowCount, 3);
});
for (const [name, mutate] of [
  ['bare prefix flag', (f) => (f.prefix = { confirmed: true })],
  ['bare fault flag', (f) => (f.faultQualification = { faultQualified: true })],
  ['unsupported trigger', (f) => (f.quality.events[16].kind = 'deliveryFailure')],
  [
    'wrong fault owner',
    (f) => (f.faultQualification.resetApplicationID = f.quality.events[7].application.id),
  ],
  ['wrong causal window', (f) => (f.quality.events[17].application.windowSequence = '12')],
  [
    'expired reset',
    (f) =>
      (f.quality.events[17].acknowledgedAt =
        f.quality.events[17].application.completionDeadline + 0.01),
  ],
  [
    'foreign native reset receipt',
    (f) =>
      (f.lifecycleQualification.applications[1].receipt.configurationID =
        '00000000-0000-4000-8000-000000000001'),
  ],
  ['wrong reset revision', (f) => (f.quality.events[17].revision = '3')],
  [
    'candidate-bearing reset',
    (f) => (f.quality.events[17].action.candidateID = f.quality.events[7].action.candidateID),
  ],
  ['missing transition', (f) => f.quality.events.splice(18, 1)],
  ['missing first healthy window', (f) => f.quality.events.splice(19, 1)],
  ['missing post-reset window', (f) => f.quality.events.splice(21, 1)],
  ['stale post-reset window', (f) => (post(f)[1].evaluatedAt = post(f)[1].window.end + 2.01)],
  ['foreign processing owner', (f) => (post(f)[1].source.processingScopeID = 'other')],
  [
    'pressure contradiction',
    (f) => post(f)[1].evidence.thermal.samples.forEach((s) => (s.state = 2)),
  ],
  [
    'quiet rejected event',
    (f) => f.quality.events.splice(21, 0, { kind: 'rejected', at: f.quality.events[21].at }),
  ],
  ['duplicate confirmation', (f) => post(f)[1].reasons.push('trialConfirmed')],
  ['future reset source', (f) => (post(f)[1].window.revision = '1')],
  [
    'intermediate new stall',
    (f) => {
      const r = f.cadenceReports.rows.find((r) => r.evaluatedUptime > post(f)[1].window.start + 1);
      r.observedStall = true;
      r.response.status.observation.decoderCadence.progress.stalled = true;
      r.response.status.observation.decoderCadence.progress.ageMs = 1001;
    },
  ],
  [
    'intermediate unavailable telemetry',
    (f) => {
      const r = f.cadenceReports.rows.find((r) => r.evaluatedUptime > post(f)[1].window.start + 1);
      r.sampleAgeSeconds = null;
      r.observedStall = null;
    },
  ],
  [
    'delivery lane gap',
    (f) => {
      const i = f.deliveryAudit.rows.findIndex(
        (r) =>
          r.appliedRevision === '2' && r.end - r.start === 2 && r.start > post(f)[1].window.start,
      );
      f.deliveryAudit.rows.splice(i, 1);
    },
  ],
  [
    'delivery receipt substitution',
    (f) => {
      f.deliveryAudit.rows.find((r) => r.appliedRevision === '2').receipt.configuration.id =
        '00000000-0000-4000-8000-000000000001';
    },
  ],
  [
    'insufficient shared delivery',
    (f) =>
      (f.deliveryAudit.rows = f.deliveryAudit.rows.filter(
        (r) => r.appliedRevision !== '2' || r.end < post(f)[2].window.end,
      )),
  ],
  ['missing stop', (f) => f.quality.events.pop()],
])
  test(`recovery policy rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('transition cannot be exported before its source boundary exists', () => {
  const f = fixture();
  f.quality.events[18].at = (f.quality.events[17].at + f.quality.events[18].source.end) / 2;
  assert.throws(() => qualify(f));
});

const rawB = JSON.parse(
  gunzipSync(
    fs.readFileSync(new URL('./fixtures/measured-recovery-TPUMig.json.gz', import.meta.url)),
  ),
).input;
const bTrigger = () => {
  const f = structuredClone(rawB),
    events = f.quality.events;
  const confirmedEventIndex = events.findIndex((e) => e.reasons?.includes('trialConfirmed'));
  // Structured prefix contract for isolated trigger tests, not a whole-run proof:
  // immutable B has late cadence gaps and can never qualify the complete gate.
  f.prefix = {
    confirmedEventIndex,
    nextEventIndex: confirmedEventIndex + 1,
    confirmedAt: events[confirmedEventIndex].evaluatedAt,
  };
  f.faultQualification = {
    triggerKind: 'deliveryFailure',
    triggerEventIndex: 16,
    resetEventIndex: 17,
    triggerEvaluatedAt: events[16].evaluatedAt,
    resetApplicationID: events[17].application.id,
    resetAcknowledgedAt: events[17].acknowledgedAt,
    triggerDeliveryRowIndex: 97,
    triggerCadenceReportIndex: 784,
    stalledCadenceReportIndex: 785,
    decoderScopeID: f.cadenceReports.rows[784].response.status.observation.decoderCadence.scopeID,
    lastStalledPTS: '6856081',
  };
  return f;
};
const triggerModule = await import('../measured-recovery-policy.mjs');
const qualifyTrigger = (f) => {
  assert.equal(typeof triggerModule.qualifyMeasuredRecoveryTrigger, 'function');
  return triggerModule.qualifyMeasuredRecoveryTrigger(f);
};
test('actual B delivery-first trigger is independent of later disqualifying cadence gaps', () => {
  const f = bTrigger(),
    before = JSON.stringify(f),
    r = qualifyTrigger(f);
  assert.equal(r.triggerIndex, 16);
  assert.equal(r.resetIndex, 17);
  assert.equal(r.signal.sequence, '13');
  assert.equal(r.trigger.kind, 'deliveryFailure');
  assert.equal(r.triggerReport.observedStall, false);
  assert.equal(r.lastStalledPTS, 6856081);
  assert.equal(JSON.stringify(f), before);
});
for (const [name, mutate] of [
  ['wrong delivery row', (f) => f.faultQualification.triggerDeliveryRowIndex++],
  ['forged delivery floor', (f) => (f.quality.events[16].deliveryFailure.onTimeFrames = 30)],
  ['wrong delivery reason', (f) => (f.quality.events[16].reasons = ['stalled'])],
  ['wrong delivery state', (f) => (f.quality.events[16].state = 'healthy')],
  [
    'wrong delivery owner',
    (f) => (f.quality.events[16].deliveryFailure.context.workerId = 'foreign'),
  ],
  ['expired delivery decision', (f) => (f.quality.events[16].evaluatedAt += 0.3)],
  ['wrong causal branch', (f) => (f.faultQualification.triggerKind = 'decoderStall')],
  ['wrong subsequent stall', (f) => (f.faultQualification.stalledCadenceReportIndex = 784)],
  [
    'unrelated subsequent stall progress',
    (f) =>
      (f.cadenceReports.rows[785].response.status.observation.decoderCadence.progress.lastFreshPTS += 3000),
  ],
])
  test(`delivery trigger rejects ${name}`, () => {
    const f = bTrigger();
    mutate(f);
    assert.throws(() => qualifyTrigger(f));
  });

test('immutable B complete suffix rejects late polling gaps after its valid delivery trigger', async () => {
  const f = bTrigger();
  const { qualifyVideoObservation } = await import('../video-observation-qualification.mjs');
  const { qualifyPublishingClockObservation } =
    await import('../publishing-clock-qualification.mjs');
  const { qualifyWorkerPublicationEvidence } = await import('../worker-publication-evidence.mjs');
  const { qualifySourceIntervals } = await import('../source-interval-qualification.mjs');
  const { qualifyNativeProfileTransitions } = await import('../native-profile-transitions.mjs');
  const { qualifyMeasuredNativeLifecycle } = await import('../measured-native-lifecycle.mjs');
  const video = qualifyVideoObservation(f);
  const clock = qualifyPublishingClockObservation({
    snapshot: f.snapshot,
    expectedScope: video.scope,
  });
  const worker = qualifyWorkerPublicationEvidence(f.workerRecords, video.scope);
  f.sourceIntervalQualification = qualifySourceIntervals({
    ...f,
    videoObservation: video,
    publishingClockObservation: clock,
    workerPublicationEvidence: worker,
  });
  f.profileQualification = qualifyNativeProfileTransitions(f.format, f.snapshot, f.liveIDs, {
    sequence: 'measured240',
    requireFrameEvidence: true,
  });
  f.lifecycleQualification = qualifyMeasuredNativeLifecycle(f);
  const c = f.quality.events[f.prefix.confirmedEventIndex],
    start = f.quality.events[10].window.start;
  // Only the structured prefix dependency is isolated; no raw history is filtered
  // and all recovery source/profile/lifecycle proofs are reconstructed above.
  Object.assign(f.prefix, {
    proofExtent: 'confirmed-prefix',
    rawEventCount: f.quality.events.length,
    confirmedEventAt: c.at,
    probation: { start, end: c.window.end, coverageSeconds: c.window.end - start },
  });
  qualifyTrigger(f);
  assert.throws(() => qualify(f), /Unhealthy recovery delivery classification/);
  const { qualifyMeasuredCadenceContinuity } = await import('../measured-trial-policy.mjs');
  assert.throws(
    () =>
      qualifyMeasuredCadenceContinuity({
        reports: f.cadenceReports.rows,
        start: f.cadenceReports.rows.findLast((r) => r.evaluatedUptime <= f.prefix.confirmedAt)
          .evaluatedUptime,
        end: f.cadenceReports.rows.at(-1).evaluatedUptime,
        source: c.source,
        scope: f.snapshot.scope,
        allowedStall: {
          start: f.cadenceReports.rows[784].evaluatedUptime,
          end: f.quality.events[20].window.start,
          lastFreshPTS: 6856081,
        },
      }),
    /Missing intermediate cadence coverage/,
  );
});

test('synthetic delivery sample uses the earlier source-window expiry at the two-second boundary', () => {
  const f = bTrigger(),
    trigger = f.quality.events[16],
    reset = f.quality.events[17];
  // B's immutable native evidence is unchanged. This bounded scalar timing variant
  // moves only the delivery sample age 10ms younger, so source-end+2 becomes the
  // earlier deadline. Raw delivery reconstruction still validates the variant.
  const report = f.cadenceReports.rows[784];
  report.response.status.decoderDeliveryAgeUpperBoundMs -= 10;
  report.deliverySampleAgeSeconds -= 0.01;
  for (const row of f.deliveryAudit.rows.filter(
    (r) => r.deliveryReceiptID === report.deliveryReceiptID,
  )) {
    row.sampleAgeSeconds -= 0.01;
    row.observedAtLowerBound += 0.01;
  }
  trigger.deliveryFailure.observedAtLowerBound += 0.01;
  const expectedExpiry = trigger.deliveryFailure.end + 2;
  assert(expectedExpiry < trigger.deliveryFailure.observedAtLowerBound + 0.25);
  trigger.action.validUntil = reset.action.validUntil = expectedExpiry;
  assert.equal(qualifyTrigger(f).expectedExpiry, expectedExpiry);
  trigger.action.validUntil = reset.action.validUntil =
    trigger.deliveryFailure.observedAtLowerBound + 0.25;
  assert.throws(() => qualifyTrigger(f));
});

const rawC = JSON.parse(
  gunzipSync(
    fs.readFileSync(new URL('./fixtures/measured-recovery-mnaRRb.json.gz', import.meta.url)),
  ),
).input;
function cFixture() {
  const f = structuredClone(rawC),
    proof = qualifyMeasuredNativeEvidence(f, { recovery: true });
  Object.assign(f, {
    scope: proof.scope,
    sourceIntervalQualification: proof.source,
    profileQualification: proof.profile,
    lifecycleQualification: proof.nativeLifecycle,
    candidateWitnessQualification: proof.witness,
  });
  f.prefix = qualifyMeasuredTrialConfirmedPrefix(f);
  const trigger = f.quality.events[16],
    reset = f.quality.events[17];
  // Isolated exact fault contract; the full test below recomputes the causal fault.
  f.faultQualification = {
    triggerKind: 'deliveryFailure',
    triggerEventIndex: 16,
    resetEventIndex: 17,
    triggerEvaluatedAt: trigger.evaluatedAt,
    resetApplicationID: reset.application.id,
    resetAcknowledgedAt: reset.acknowledgedAt,
    triggerDeliveryRowIndex: f.deliveryAudit.rows.findIndex(
      (r) =>
        r.evaluatedAt === trigger.deliveryFailure.classifiedAt &&
        r.start === trigger.deliveryFailure.start &&
        r.end === trigger.deliveryFailure.end,
    ),
    triggerCadenceReportIndex: 785,
    stalledCadenceReportIndex: 789,
    decoderScopeID: f.cadenceReports.rows[785].response.status.observation.decoderCadence.scopeID,
    lastStalledPTS: String(
      f.cadenceReports.rows[785].response.status.observation.decoderCadence.progress.lastFreshPTS,
    ),
  };
  return f;
}
test('actual C two-second source-loss trigger follows native policy', () => {
  const f = cFixture(),
    r = qualifyTrigger(f);
  assert.equal(r.trigger.kind, 'deliveryFailure');
  assert.deepEqual(r.trigger.reasons, ['sourceLoss']);
  assert.equal(r.signal.expectedFrames, 59);
  assert.equal(r.signal.missingFrames, 5);
});
test('actual C full suffix uses independent common proofs, confirmed prefix and causal fault', async () => {
  const f = cFixture(),
    before = JSON.stringify(f);
  const { qualifyMeasuredRecoveryFault } = await import('../measured-recovery-fault.mjs');
  f.faultQualification = qualifyMeasuredRecoveryFault(f);
  const r = qualify(f);
  assert.equal(r.recoveryPolicyQualified, true);
  assert.equal(r.productionUpgradeAuthorized, false);
  assert(r.sharedCoverage.coverageSeconds >= 10);
  assert.equal(r.healthyWindows.length, 5);
  assert.equal(r.sharedCoverage.start, post(f)[1].window.start);
  assert(r.resumedAt > post(f)[0].window.start);
  const expected = JSON.parse(before);
  expected.faultQualification = f.faultQualification;
  assert.deepEqual(f, expected);
});
for (const [name, mutate] of [
  ['wrong two-second reason', (f) => (f.quality.events[16].reasons = ['freshFrameFloor'])],
  ['wrong nonzero-frame state', (f) => (f.quality.events[16].state = 'stalled')],
  ['invented stalled reason', (f) => f.quality.events[16].reasons.push('stalled')],
  ['forged sub-threshold loss', (f) => (f.quality.events[16].deliveryFailure.missingFrames = 2)],
])
  test(`C policy rejects ${name}`, () => {
    const f = cFixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('native delivery semantics cover both lanes, strict thresholds and zero on-time state', () => {
  assert.equal(typeof triggerModule.measuredDeliveryFailureDecision, 'function');
  const signal = (duration, onTime, missing) => ({
    start: 100,
    end: 100 + duration,
    expectedFrames: onTime + missing,
    onTimeFrames: onTime,
    lateFrames: 0,
    missingFrames: missing,
  });
  for (const duration of [1, 2]) {
    assert.deepEqual(
      triggerModule.measuredDeliveryFailureDecision(signal(duration, 0, 30 * duration)),
      { state: 'stalled', reasons: [duration === 1 ? 'freshFrameFloor' : 'sourceLoss', 'stalled'] },
    );
  }
  assert.deepEqual(triggerModule.measuredDeliveryFailureDecision(signal(1, 23, 7)), {
    state: 'degraded',
    reasons: ['freshFrameFloor'],
  });
  assert.deepEqual(triggerModule.measuredDeliveryFailureDecision(signal(2, 56, 4)), {
    state: 'degraded',
    reasons: ['sourceLoss'],
  });
  for (const invalid of [signal(1, 24, 6), signal(2, 57, 3), signal(3, 0, 90), signal(2, 54, -1)])
    assert.throws(() => triggerModule.measuredDeliveryFailureDecision(invalid));
});

test('synthetic delivery-priority decision may already have a stalled current cadence sample', () => {
  const f = bTrigger(),
    r = f.cadenceReports.rows[784];
  // Scalar cadence variant only; the independent delivery trace remains intact.
  r.observedStall = true;
  Object.assign(r.response.status.observation.decoderCadence.progress, {
    stalled: true,
    ageMs: 1001,
  });
  f.faultQualification.stalledCadenceReportIndex = 784;
  assert.equal(qualifyTrigger(f).triggerReport.observedStall, true);
});
