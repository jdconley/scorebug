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

// The harness checks these bounds before parsing. Callers of the pure replay
// must likewise supply bounded raw artifacts, never qualification summaries.
export const measuredTrialArtifacts = {
  snapshot: ['video-observation.json', 8 * 1024 * 1024],
  quality: ['quality-control.json', 8 * 1024 * 1024],
  format: ['native-profile-transitions.json', 8 * 1024 * 1024],
  startupFormat: ['native-publishing-format.json', 4096],
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

/** Compose independent raw evidence for one successful minimum-to-next native
 * laboratory trial. Full A/V decoding, archive durability and ingress checks
 * remain required by the calling harness. No production upgrade permission.
 */
export function qualifyMeasuredNativeTrial(input) {
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
  const video = qualifyVideoObservation({
    snapshot,
    expectedScope,
    archiveIDs,
    liveIDs,
    completedWindowLimit,
  });
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
  const reportAge = qualifyWorkerReportAge({ snapshot, decodedEvidence });
  const cadence = qualifyNativeCadenceReports({ audit: cadenceReports, scope: video.scope });
  const delivery = qualifyNativeDeliveryDeadlines({
    audit: deliveryAudit,
    reports: cadenceReports,
    scope: video.scope,
    expectedLatencyBudget: 1.5,
  });
  const profile = qualifyNativeProfileTransitions(format, snapshot, liveIDs, {
    sequence: 'measured240',
    requireFrameEvidence: true,
  });
  const nativeLifecycle = qualifyMeasuredNativeLifecycle({
    lifecycle,
    quality,
    format,
    snapshot,
    startupFormat,
    profileQualification: profile,
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
  assert.equal(nativeLifecycle.applications.length, 1);
  assert(candidateProof.measurement.endedAt <= nativeLifecycle.applications[0].requestedAt);
  const measuredRetirement = { lifecycle, quality };
  const probe = qualifyNativeBandwidthProbe(nativeProbe, {
    mode: 'staged',
    candidateHeadroom: true,
    scope: video.scope,
    publishingGeneration: clock.publishingGeneration,
    measuredRetirement,
  });
  const receiver = qualifyReceiverProbeEvidence(receiverRecords, video.scope, probe);
  const intervals = qualifyNativeReceiverIntervals(
    receiverIntervals,
    receiverRecords,
    video.scope,
    probe,
    workerRecords,
    nativeProbe,
    { includeIntervalIndexes: true, measuredRetirement },
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
  });
  assert.equal(witness.headroomQualified, true);
  const policy = qualifyMeasuredTrialPolicy({
    quality,
    snapshot,
    sourceIntervalQualification: source,
    profileQualification: profile,
    lifecycleQualification: nativeLifecycle,
    candidateWitnessQualification: witness,
    cadenceReports,
  });

  // Deadlines are replayed independently, then joined to actual applications.
  // Overlapping one-/two-second lanes never contribute additive probation credit.
  assert.equal(delivery.unknownRows, 0, 'Incomplete delivery classification');
  assert.equal(delivery.observations.healthyRows, delivery.rowCount, 'Unhealthy measured delivery');
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
