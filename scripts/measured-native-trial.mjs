import { timingContractForProfile, qualifyTimingContract } from './native-timing-contract.mjs';
import { expandQualityEvidence } from './quality-evidence-dictionary.mjs';
import { qualifyRecoveryDeliveryBucket } from './recovery-delivery-bucket.mjs';
import assert from 'node:assert/strict';
import { fixtureFrameID, qualifyVideoObservation } from './video-observation-qualification.mjs';
import { qualifyPublishingClockObservation } from './publishing-clock-qualification.mjs';
import { qualifyPublishingAttemptEvidence } from './publishing-attempt-evidence.mjs';
import { qualifyWorkerPublicationEvidence } from './worker-publication-evidence.mjs';
import { qualifySourceIntervals } from './source-interval-qualification.mjs';
import { qualifyWorkerProcessingReports } from './worker-processing-qualification.mjs';
import { qualifyWorkerReportAge } from './worker-report-age-qualification.mjs';
import { qualifyNativeCadenceReports } from './native-cadence-reports.mjs';
import { qualifyNativeDeliveryDeadlines } from './native-delivery-deadlines.mjs';
import { qualifyNativeProfileTransitions } from './native-profile-transitions.mjs';
import { qualifyMeasuredNativeLifecycle } from './measured-native-lifecycle.mjs';
import { qualifyNativeCandidateMeasurement } from './native-candidate-measurement.mjs';
import { qualifyNativeBandwidthProbe } from './native-bandwidth-probe.mjs';
import { qualifyReceiverProbeEvidence } from './receiver-probe-evidence.mjs';
import { qualifyNativeReceiverIntervals } from './native-receiver-intervals.mjs';
import { qualifyMeasuredCandidateWitness } from './measured-candidate-witness.mjs';
import { qualifyMeasuredTrialPolicy } from './measured-trial-policy.mjs';
import { nativeFormatEvidenceMaximumBytes } from './native-format-qualification.mjs';

// The harness checks these bounds before parsing. Callers of the pure replay
// must likewise supply bounded raw artifacts, never qualification summaries.
export const measuredTrialArtifacts = {
  snapshot: ['video-observation.json', 8 * 1024 * 1024],
  quality: ['quality-control.json', 8 * 1024 * 1024],
  format: ['native-profile-transitions.json', 8 * 1024 * 1024],
  startupFormat: ['native-publishing-format.json', nativeFormatEvidenceMaximumBytes],
  lifecycle: ['native-candidate-lifecycle.json', 512 * 1024],
  candidateProof: ['native-candidate-measurement.json', 256 * 1024],
  nativeProbe: ['native-bandwidth-probe.json', 512 * 1024],
  receiverIntervals: ['native-receiver-intervals.json', 1024 * 1024],
  receiverRecords: ['receiver-probe-status.json', 4 * 1024 * 1024],
  workerRecords: ['worker-publication-status.json', 4 * 1024 * 1024],
  decodedEvidence: ['decoded-video-status.json', 8 * 1024 * 1024],
  processingEvidence: ['worker-processing-status.json', 4 * 1024 * 1024],
  attemptRecords: ['publishing-attempt-status.json', 4 * 1024 * 1024],
  cadenceReports: ['worker-cadence-reports.json', 16 * 1024 * 1024],
  deliveryAudit: ['delivery-deadlines.json', 32 * 1024 * 1024],
};

/** Shared raw capture/receiver/worker/delivery replay for measured routes.
 * This grants no candidate, policy, recovery, or production permission. Each
 * route must still qualify its original media phases and admission timeline. */
export function qualifyMeasuredNativeMedia(input, options = {}) {
  assert.ok(
    options !== null && typeof options === 'object' && !Array.isArray(options),
    'Media options must be an object',
  );
  for (const key of Reflect.ownKeys(options))
    assert.ok(
      ['cadenceAuditMode', 'deliveryAuditMode', 'mediaLossPolicy', 'timingProfile'].includes(key),
      `Unknown measured media option: ${String(key)}`,
    );
  const {
    timingProfile = 'strict1500-v1',
    cadenceAuditMode = 'legacy',
    deliveryAuditMode = 'legacy',
    mediaLossPolicy = 'lossless-v1',
  } = options;
  const {
    snapshot,
    workerRecords,
    decodedEvidence,
    processingEvidence,
    attemptRecords,
    cadenceReports,
    deliveryAudit,
    archiveIDs,
    liveIDs,
    expectedScope,
    completedWindowLimit,
  } = input;
  const video = qualifyVideoObservation(
    {
      snapshot,
      expectedScope,
      archiveIDs,
      liveIDs,
      completedWindowLimit,
    },
    { mediaLossPolicy },
  );
  const clock = qualifyPublishingClockObservation({ snapshot, expectedScope: video.scope });
  const attempt = qualifyPublishingAttemptEvidence(attemptRecords, video.scope);
  const worker = qualifyWorkerPublicationEvidence(workerRecords, video.scope);
  const source = qualifySourceIntervals({
    snapshot,
    videoObservation: video,
    publishingClockObservation: clock,
    workerPublicationEvidence: worker,
    decodedEvidence,
    archiveIDs,
    liveIDs,
  });
  const processing = qualifyWorkerProcessingReports({
    snapshot,
    sourceIntervalQualification: source,
    processingEvidence,
  });
  let mediaConservation;
  if (video.lossConservation) {
    const accountedSourceIntervals = [];
    const accounted = new Set();
    for (const interval of source.intervals) {
      const missingIDs = video.lossConservation.missingEncodedIDs.filter(
        (id) => id > interval.sourceStartExclusive && id <= interval.sourceEndInclusive,
      );
      assert.equal(
        missingIDs.length,
        interval.encodedNotDecodedFrames,
        'Source loss differs from enumerated missing encoded identities',
      );
      const raw = snapshot.sourceIntervals.find(
        (row) => Number(row.sequence) === interval.sequence,
      );
      const durationSeconds = raw.captureBoundaryEndTime - raw.captureBoundaryStartTime;
      assert.ok(
        missingIDs.length * 100 <= interval.encodedFrames,
        'Raw source interval exceeds 1% decoded loss',
      );
      assert.ok(
        durationSeconds > 0 && interval.decodedFrames / durationSeconds >= 24,
        'Raw source interval fell below 24 fps',
      );
      if (!missingIDs.length) continue;
      const complete = processing.completed.find((row) => row.sequence === interval.sequence);
      assert.ok(complete, 'Missing identity lacks complete independent processing evidence');
      assert.equal(complete.decodedFrames, interval.decodedFrames);
      assert.equal(complete.completedFrames, interval.decodedFrames);
      missingIDs.forEach((id) => accounted.add(id));
      accountedSourceIntervals.push({
        sequence: interval.sequence,
        missingIDs,
        encodedFrames: interval.encodedFrames,
        decodedFrames: interval.decodedFrames,
        completedFrames: complete.completedFrames,
        durationSeconds,
        decodedFPS: interval.decodedFrames / durationSeconds,
        lossFraction: missingIDs.length / interval.encodedFrames,
      });
    }
    for (const id of video.lossConservation.missingEncodedIDs)
      assert.ok(
        accounted.has(id),
        `Missing identity ${id} lacks independently qualified raw source counters`,
      );
    mediaConservation = {
      ...video.lossConservation,
      rawCountersReconciled: true,
      accountedSourceIntervals,
    };
  }
  const reportAge = qualifyWorkerReportAge({ snapshot, decodedEvidence });
  const cadence = qualifyNativeCadenceReports({
    audit: cadenceReports,
    scope: video.scope,
    cadenceAuditMode,
    timingProfile,
  });
  const delivery = qualifyNativeDeliveryDeadlines({
    audit: deliveryAudit,
    reports: cadenceReports,
    cadenceAuditMode,
    deliveryAuditMode,
    scope: video.scope,
    expectedLatencyBudget: timingContractForProfile(timingProfile).decoderBudgetMs / 1000,
    timingProfile,
  });
  return {
    scope: video.scope,
    video,
    clock,
    attempt,
    worker,
    source,
    processing,
    ...(mediaConservation ? { mediaConservation } : {}),
    reportAge,
    cadence,
    delivery,
  };
}

/** Recompute shared raw native/admission evidence. This does not qualify policy
 * success or recovery: a complete route-specific verifier must consume it.
 * Full A/V decoding, archive durability and ingress checks remain required by
 * the calling harness. No production upgrade permission is returned.
 */
export function qualifyMeasuredNativeEvidence(input, options = {}) {
  assert(
    options !== null && typeof options === 'object' && !Array.isArray(options),
    'Native evidence options must be an object',
  );
  for (const key of Reflect.ownKeys(options))
    assert(
      [
        'recovery',
        'probePolicy',
        'capacityRecovery',
        'capacityDecrease',
        'mediaLossPolicy',
      ].includes(key),
      'Unknown native evidence option',
    );
  const {
    recovery = false,
    probePolicy = 'local-zero-loss-v1',
    capacityRecovery = false,
    capacityDecrease = false,
    mediaLossPolicy = 'lossless-v1',
  } = options;
  assert(
    ['lossless-v1', 'accounted-bounded-v1'].includes(mediaLossPolicy),
    'Unknown native media loss policy',
  );
  assert(
    mediaLossPolicy === 'lossless-v1' || (recovery && capacityRecovery && capacityDecrease),
    'Bounded native media requires the explicit capacity decrease route',
  );
  input = { ...input, quality: expandQualityEvidence(input.quality) };
  qualifyTimingContract(input.quality);
  assert.ok(
    ['local-zero-loss-v1', 'recovery-budget-v1'].includes(probePolicy),
    'Unknown measured probe policy',
  );
  assert.equal(typeof recovery, 'boolean');
  assert.equal(typeof capacityRecovery, 'boolean');
  assert.equal(typeof capacityDecrease, 'boolean');
  assert(
    !capacityDecrease || capacityRecovery,
    'Local decrease requires the explicit capacity route',
  );
  assert(
    !capacityRecovery || (recovery && probePolicy === 'recovery-budget-v1'),
    'Capacity evidence requires explicit recovery and recovery-budget policy',
  );
  const {
    snapshot,
    quality,
    format,
    startupFormat,
    lifecycle,
    candidateProof,
    nativeProbe,
    receiverIntervals,
    receiverRecords,
    workerRecords,
    liveIDs,
  } = input;
  const {
    video,
    clock,
    attempt,
    worker,
    source,
    processing,
    mediaConservation,
    reportAge,
    cadence,
    delivery,
  } = qualifyMeasuredNativeMedia(
    input,
    capacityRecovery
      ? {
          cadenceAuditMode: 'capacity',
          deliveryAuditMode: 'capacity',
          mediaLossPolicy,
        }
      : {},
  );
  const profile = qualifyNativeProfileTransitions(format, snapshot, liveIDs, {
    sequence: 'measured240',
    requireFrameEvidence: true,
  });
  assert.equal(profile.phases.length, recovery ? 3 : 2);
  const nativeLifecycle = qualifyMeasuredNativeLifecycle({
    lifecycle,
    quality,
    format,
    snapshot,
    startupFormat,
    profileQualification: profile,
    probePolicy,
    recovery,
    capacityDecrease,
  });
  const phase = profile.phases[0];
  const baseline = {
    evidenceScope: 'baseline-source-phase',
    scope: profile.scope,
    publishingGeneration: profile.publishingGeneration,
    width: phase.width,
    height: phase.height,
    frames: phase.nativeFrames,
    firstFrame: phase.firstFrame,
    lastFrame: phase.lastFrame,
  };
  const candidate = qualifyNativeCandidateMeasurement(candidateProof, {
    scope: video.scope,
    profile: '360p30',
    liveProfile: '240p30',
    format: baseline,
    requiredFormatVersion: 3,
  });
  const nativeFrames = new Set(
    format.compressedFrames.slice(0, phase.nativeFrames).map((f) => fixtureFrameID(f.sourcePTS)),
  );
  const decodedFrames = new Set(liveIDs);
  for (const frame of candidateProof.measurement.encoding.frames) {
    const id = fixtureFrameID(frame.sourcePTS);
    assert(
      nativeFrames.has(id) && decodedFrames.has(id),
      'Candidate must use actual baseline and decoded source frames',
    );
  }
  assert.equal(nativeLifecycle.applications.length, recovery ? 2 : 1);
  assert(candidateProof.measurement.endedAt <= nativeLifecycle.applications[0].requestedAt);
  const measuredRetirement = {
    lifecycle,
    quality,
    ...(recovery ? { recovery: true } : {}),
    ...(capacityDecrease ? { capacityDecrease: true, snapshot } : {}),
  };
  const probe = qualifyNativeBandwidthProbe(nativeProbe, {
    mode: 'staged',
    candidateHeadroom: true,
    scope: video.scope,
    publishingGeneration: clock.publishingGeneration,
    measuredRetirement,
    policy: probePolicy,
  });
  const receiver = qualifyReceiverProbeEvidence(receiverRecords, video.scope, probe);
  const intervals = qualifyNativeReceiverIntervals(
    receiverIntervals,
    receiverRecords,
    video.scope,
    probe,
    workerRecords,
    nativeProbe,
    { includeIntervalIndexes: true, measuredRetirement, policy: probePolicy },
  );
  const admissions = quality.events.filter((e) => e.kind === 'candidate');
  assert.equal(admissions.length, 1);
  const witness = qualifyMeasuredCandidateWitness({
    witness: admissions[0].candidateAdmission,
    candidateProof,
    candidate,
    bootstrap: nativeLifecycle.bootstrap,
    intervals: receiverIntervals,
    intervalQualification: intervals,
    nativeProof: nativeProbe,
    policy: probePolicy,
  });
  assert.equal(witness.headroomQualified, true);
  return {
    scope: video.scope,
    video,
    clock,
    attempt,
    worker,
    source,
    processing,
    reportAge,
    cadence,
    delivery,
    profile,
    nativeLifecycle,
    candidate,
    probe,
    receiver,
    intervals,
    witness,
    ...(mediaConservation ? { mediaConservation } : {}),
  };
}

function validateDeliveryProfile(profile) {
  assert(['strict30-v1', 'floor24-v1'].includes(profile), 'Unknown delivery profile');
}

/** Select a benchmark only after raw deadline reconstruction. This helper alone
 * grants no full-trial, admission, recovery or production qualification. */
export function qualifyMeasuredTrialDelivery(delivery, profile = 'strict30-v1') {
  validateDeliveryProfile(profile);
  assert(delivery.rowCount > 0, 'Missing measured delivery');
  assert.equal(delivery.unknownRows, 0, 'Incomplete delivery classification');
  assert.equal(delivery.successfulRows, delivery.rowCount, 'Incomplete delivery classification');
  for (const key of ['lateRows', 'missingRows', 'uncertainRows', 'below24FPSRows'])
    assert.equal(delivery.observations[key], 0, 'Unhealthy measured delivery');
  if (profile === 'strict30-v1')
    assert.equal(
      delivery.observations.healthyRows,
      delivery.rowCount,
      'Unhealthy measured delivery',
    );
  return profile;
}

/** Laboratory trial; explicit startup pressure earns no health credit. Later
 * failure/recovery episodes still require a separately qualified route. */
export function qualifyMeasuredNativeTrial(
  input,
  {
    probePolicy = 'local-zero-loss-v1',
    deliveryProfile = 'strict30-v1',
    startupPressurePolicy = 'reject',
  } = {},
) {
  validateDeliveryProfile(deliveryProfile);
  input = { ...input, quality: expandQualityEvidence(input.quality) };
  const { quality, snapshot, cadenceReports, deliveryAudit } = input;
  const {
    video,
    clock,
    attempt,
    worker,
    source,
    processing,
    reportAge,
    cadence,
    delivery,
    profile,
    nativeLifecycle,
    candidate,
    probe,
    receiver,
    intervals,
    witness,
  } = qualifyMeasuredNativeEvidence(input, { probePolicy });
  const policy = qualifyMeasuredTrialPolicy({
    quality,
    snapshot,
    sourceIntervalQualification: source,
    profileQualification: profile,
    lifecycleQualification: nativeLifecycle,
    candidateWitnessQualification: witness,
    transportPolicy: probePolicy === 'recovery-budget-v1' ? probePolicy : 'sender-delay-v1',
    startupPressurePolicy,
    cadenceReports,
  });

  // Deadlines are replayed independently, then joined to actual applications.
  // Overlapping one-/two-second lanes never contribute additive probation credit.
  qualifyMeasuredTrialDelivery(delivery, deliveryProfile);
  qualifyMeasuredDeliveryOwnership(input, { profile, nativeLifecycle, delivery });
  for (const duration of [1, 2]) {
    const rows = deliveryAudit.rows.filter(
      (r) => r.appliedRevision === '1' && r.end - r.start === duration,
    );
    assert(rows.length >= 10, 'Insufficient independent delivery lane coverage');
    let end = rows[0].start;
    assert(end <= policy.probation.start, 'Delivery starts after probation');
    for (const row of rows) {
      assert.equal(row.start, end, 'Delivery coverage gap');
      end = row.end;
    }
    assert(end >= policy.probation.end, 'Delivery does not cover probation');
  }
  return {
    measuredTrialQualified: true,
    deliveryProfile,
    productionUpgradeAuthorized: false,
    scope: video.scope,
    video,
    clock,
    attempt,
    worker,
    source,
    processing,
    reportAge,
    cadence,
    delivery,
    profile,
    nativeLifecycle,
    candidate,
    probe,
    receiver,
    intervals,
    witness,
    policy,
  };
}

/** Join already reconstructed deadline rows to actual native configuration lives.
 * Timeliness failures remain failures; this function grants no health duration.
 */
export function qualifyMeasuredDeliveryOwnership(input, { profile, nativeLifecycle, delivery }) {
  const { archiveIDs, liveIDs, format, quality, deliveryAudit } = input;
  const decodedFrames = new Set(liveIDs);
  assert.equal(delivery.unknownRows, 0, 'Incomplete delivery classification');
  const archiveFrames = new Set(archiveIDs);
  const allNativeFrames = new Set(format.compressedFrames.map((f) => fixtureFrameID(f.sourcePTS)));
  const configurations = [
    nativeLifecycle.bootstrap,
    ...quality.events.filter((e) => e.kind === 'applied'),
  ];
  for (const row of deliveryAudit.rows) {
    const event = configurations.find((e) => e.revision === row.appliedRevision);
    assert(event, 'Deadline revision lacks native application');
    const r = event.receipt;
    assert.equal(row.profileID, event.profileID);
    const next = configurations[configurations.indexOf(event) + 1];
    if (next) assert(row.end <= next.acknowledgedAt, 'Old delivery window crosses application');
    const phase = profile.phases.find(
      (p) => p.encoderSessionID.toLowerCase() === r.encoderSessionID.toLowerCase(),
    );
    assert(phase, 'Delivery encoder lacks native phase');
    for (const frame of row.frames) {
      const id = fixtureFrameID(frame.sourcePTS);
      assert(
        archiveFrames.has(id) && decodedFrames.has(id) && allNativeFrames.has(id),
        'Deadline frame lacks actual archive/native/decoded correspondence',
      );
      assert(
        id >= phase.firstFrame && id <= phase.lastFrame,
        'Deadline frame belongs to another encoder',
      );
    }
    assert.deepEqual(row.receipt, {
      acceptedAt: r.acceptedAt,
      generation: r.generation,
      lastSubmittedPTS: r.lastSubmittedPTS,
      configuration: {
        id: r.configurationID.toLowerCase(),
        encoderSessionID: r.encoderSessionID.toLowerCase(),
        bitRate: r.bitRate,
      },
    });
    assert.equal(row.acknowledgedAt, event.acknowledgedAt);
    assert(row.start >= event.acknowledgedAt);
  }
  return { rows: deliveryAudit.rows.length, scope: profile.scope };
}

/** Each lane must independently cover the interval; overlap never adds credit. */
export function qualifyMeasuredDeliveryCoverage(audit, { revision, start, end, recovery = false }) {
  assert.equal(typeof recovery, 'boolean');
  assert(Number.isFinite(start) && Number.isFinite(end) && end > start);
  const lanes = [];
  for (const duration of [1, 2]) {
    const rows = audit.rows.filter(
      (r) =>
        r.appliedRevision === revision &&
        r.end - r.start === duration &&
        r.end > start &&
        r.start < end,
    );
    assert(rows.length > 0, 'Missing delivery coverage');
    let cursor = start;
    for (const [index, row] of rows.entries()) {
      assert(
        (index === 0 ? row.start <= cursor : row.start === cursor) && row.end > cursor,
        'Gap or overlap in delivery coverage',
      );
      const result = row.result;
      // The independently replayed recovery already requires strong source
      // cadence. Keep probation's existing stricter bucket rule unchanged.
      if (recovery) qualifyRecoveryDeliveryBucket(result, duration);
      else
        assert(
          result &&
            result.uncertainFrames === 0 &&
            result.missingFrames === 0 &&
            result.lateFrames === 0 &&
            result.onTimeFPS >= 30,
          'Unhealthy delivery coverage',
        );
      cursor = row.end;
    }
    assert(cursor >= end, 'Insufficient delivery coverage');
    lanes.push({ duration, rows: rows.length, start: rows[0].start, end: cursor });
  }
  return { start, end, coverageSeconds: end - start, lanes };
}
