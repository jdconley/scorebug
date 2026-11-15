import assert from 'node:assert/strict';
import { qualifyRepeatedNativeCandidateMeasurements } from './repeated-native-candidate-measurement.mjs';
import { qualifyMeasuredNativeLifecycle } from './measured-native-lifecycle.mjs';
import { qualifyRepeatedProbeRetirements } from './repeated-probe-retirement.mjs';
import {
  qualifyRepeatedNativeReceiverIntervals,
  assertRepeatedNativeAcceptanceConsistent,
} from './repeated-native-receiver-intervals.mjs';
import { qualifyRepeatedCandidateWitness } from './measured-candidate-witness.mjs';
import { assertNativeProbeStateOrder } from './native-probe-read-interval.mjs';

const sameID = (a, b) => {
  assert.match(a, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
  assert.match(b, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
  assert.equal(a.toLowerCase(), b.toLowerCase());
};

// Components separately constrain their observations against raw native events.
// Their interpolated observations must also agree with one another. Include all
// interval rows: an unselected row may disprove authority, never improve the
// captured pair. The admission probe is cached, so do not invent an exact read
// instant from witness.clock.after; pace against native acceptance/renewal times.
function reconcileAdmissionAcceptance(binding, admission, rows, version) {
  // NativeCandidateFixture.candidateSnapshot refreshes after the completed
  // measurement's final diagnostic. The read instant is not exported, but this
  // ordering and its monotonic floor are known.
  assert.ok(
    BigInt(admission.probe.acceptedPayloadBytes) >= BigInt(binding.final.acceptedPayloadBytes) &&
      admission.probe.lastAcceptedAt >= binding.final.lastAcceptedAt &&
      admission.probe.leaseDeadline >= binding.final.leaseDeadline,
    'Admission regressed completed candidate observation',
  );
  // observedAt and clock.after are upper bounds on when the snapshot was
  // read. The interval audit and v5 candidate snapshots export actual brackets.
  // Current is known to be refreshed after candidate completion. Compare
  // monotonic floors only when those bounds prove nonoverlapping read order.
  const interval = (sample) =>
    version === 5
      ? { lower: sample.readStartedAt, upper: sample.readFinishedAt }
      : { upper: sample.observedAt };
  const samples = [
    { sample: binding.initial, ...interval(binding.initial) },
    { sample: binding.final, ...interval(binding.final) },
    { sample: admission.binding, ...interval(binding.initial) },
    { sample: admission.probe, lower: binding.completedAt, upper: admission.clock.after },
  ];
  const requireForward = (before, after) =>
    assert.ok(
      BigInt(after.acceptedPayloadBytes) >= BigInt(before.acceptedPayloadBytes) &&
        after.lastAcceptedAt >= before.lastAcceptedAt &&
        after.leaseDeadline >= before.leaseDeadline,
      'Known-order native observation regressed across proofs',
    );
  for (const row of rows) {
    samples.push({
      lower: row.nativeReadStartedAt,
      upper: row.nativeReadFinishedAt,
      sample: {
        id: row.nativeProbeId,
        campaign: row.nativeProbeCampaign,
        stage: row.nativeProbeStage,
        publishingGeneration: row.nativePublishingGeneration,
        bitRate: 12000000,
        startedAt: row.nativeStartedAt,
        leaseDeadline: row.nativeLeaseDeadline,
        lastAcceptedAt: row.nativeLastAcceptedAt,
        acceptedPayloadBytes: row.acceptedPayloadBytes,
      },
    });
  }
  for (const [i, entry] of samples.entries()) {
    const { sample } = entry;
    sameID(sample.id, binding.initial.id);
    for (const key of ['campaign', 'stage', 'publishingGeneration', 'bitRate', 'startedAt'])
      assert.equal(sample[key], binding.initial[key], 'Cross-proof native owner mismatch');
    for (const prior of samples.slice(0, i)) {
      if (version === 5) assertNativeProbeStateOrder(prior.sample, sample);
      assertRepeatedNativeAcceptanceConsistent(prior.sample, sample);
      if (entry.lower !== undefined && prior.upper <= entry.lower)
        requireForward(prior.sample, sample);
      if (prior.lower !== undefined && entry.upper <= prior.lower)
        requireForward(sample, prior.sample);
    }
  }
}

/** Join both original admission witnesses using raw independent evidence.
 * This proves measured admission and owned native application, not subsequent
 * media health, recovery or permission to enable production upgrades. */
export function qualifyRepeatedNativeAdmissions({
  candidateProof,
  nativeProbe,
  format,
  snapshot,
  liveIDs,
  startupFormat,
  intervals,
  records,
  workerRecords,
  lifecycle,
  quality,
}) {
  const scope = snapshot.scope;
  const candidates = qualifyRepeatedNativeCandidateMeasurements(candidateProof, {
    scope,
    nativeProbe,
    format,
    snapshot,
    liveIDs,
  });
  const applications = qualifyMeasuredNativeLifecycle({
    lifecycle,
    quality,
    format,
    snapshot,
    startupFormat,
    liveIDs,
    sequence: 'repeated240',
  });
  const retirements = qualifyRepeatedProbeRetirements(nativeProbe, {
    lifecycle,
    quality,
    candidateProof,
  });
  const intervalQualification = qualifyRepeatedNativeReceiverIntervals({
    intervals,
    records,
    scope,
    nativeProbe,
    workerRecords,
    lifecycle,
    quality,
    candidateProof,
  });
  const decisions = quality.events.filter((e) => e.kind === 'candidate');
  assert.equal(decisions.length, 2);
  const campaigns = candidates.campaigns.map((candidate, index) => {
    const decision = decisions[index],
      scalar = decision.candidate;
    const witness = qualifyRepeatedCandidateWitness({
      witness: decision.candidateAdmission,
      candidateProof: candidateProof.campaigns[index].measurement,
      candidate,
      intervals,
      intervalQualification,
      nativeProof: nativeProbe,
      campaign: String(index + 1),
      quality,
      candidateEnvelopeVersion: candidateProof.formatVersion,
    });
    reconcileAdmissionAcceptance(
      candidateProof.campaigns[index].measurement.probeBinding,
      decision.candidateAdmission,
      intervals.intervals.filter(
        (row) => row.nativeProbeCampaign === candidate.campaign && row.nativeProbeStage === 3,
      ),
      candidateProof.formatVersion,
    );
    assert.equal(witness.headroomQualified, true, 'Admission lacks 25% measured padding headroom');
    const application = applications.applications[index * 2];
    const retirement = retirements.campaigns[index];
    sameID(candidate.id, scalar.id);
    sameID(scalar.attemptID, scope.publishingAttemptID);
    sameID(application.candidateID, candidate.id);
    sameID(application.requestID, retirement.profileRequestID);
    assert.equal(application.fromRevision, candidate.appliedRevision);
    assert.equal(retirement.appliedRevision, candidate.appliedRevision);
    assert.equal(retirement.campaign, candidate.campaign);
    assert.equal(application.target, candidate.profile);
    assert.equal(scalar.appliedRevision, candidate.appliedRevision);
    assert.equal(scalar.baselineProfileID, candidate.liveProfile);
    assert.equal(scalar.baselineVideoBitrate, 350000);
    assert.equal(scalar.profileID, candidate.profile);
    assert.equal(scalar.videoBitrate, 600000);
    assert.equal(scalar.measuredStart, candidate.startedAt);
    assert.equal(scalar.measuredEnd, candidate.endedAt);
    for (const key of [
      'evaluatedAt',
      'validUntil',
      'candidateTransportBitsPerSecond',
      'deliveredPaddingBitsPerSecond',
    ])
      assert.equal(
        scalar[key],
        witness[key],
        `Candidate scalar ${key} differs from captured witness`,
      );
    assert.ok(
      witness.evaluatedAt <= decision.evaluatedAt &&
        decision.evaluatedAt <= application.application.admittedAt &&
        application.application.admittedAt <= application.requestedAt &&
        application.requestedAt <= decision.action.validUntil &&
        decision.action.validUntil <= witness.validUntil,
      'Admission or dispatch exceeds captured authority',
    );
    return {
      ...witness,
      candidateID: candidate.id,
      profileRequestID: application.requestID,
      applicationID: application.applicationID,
      requestedAt: application.requestedAt,
      acknowledgedAt: application.acknowledgedAt,
      admissionQualified: true,
    };
  });
  return {
    mode: 'repeated',
    scope,
    campaigns,
    admissionQualified: true,
    mediaHealthQualified: false,
    recoveryQualified: false,
    repeatedPolicyQualified: false,
    upgradeAuthorized: false,
  };
}
