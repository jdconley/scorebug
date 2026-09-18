import assert from 'node:assert/strict';
import { qualifyRepeatedNativeBandwidthProbe } from './repeated-native-bandwidth-probe.mjs';
import { qualifyNativeProfileTransitions } from './native-profile-transitions.mjs';
import { qualifyNativeCandidateMeasurement } from './native-candidate-measurement.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';

const check = (condition, message) => assert.ok(condition, `Repeated native candidate: ${message}`);
const time = (value) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12;
const counter = (value) => {
  check(
    typeof value === 'string' && /^(0|[1-9][0-9]{0,7})$/.test(value),
    'malformed native byte count',
  );
  const n = Number(value);
  check(n <= 16 * 1024 * 1024 && n % 1316 === 0, 'native byte count outside aligned budget');
  return n;
};

function qualifyBinding(binding, measurement, closedAt, campaign, rawCampaign) {
  const stage = campaign.stages[2];
  const events = rawCampaign.events.filter((event) => event.sample.stage === 3);
  check(binding && typeof binding === 'object', 'missing native binding');
  for (const at of [binding.boundAt, binding.completedAt]) check(time(at), 'invalid binding time');
  check(
    stage.startedAt + 0.5 <= binding.boundAt &&
      binding.boundAt <= measurement.startedAt &&
      measurement.endedAt <= binding.completedAt &&
      binding.completedAt <= closedAt,
    'binding does not contain the measurement',
  );
  const terminalAt = Math.min(
    ...events
      .filter((event) => event.sample.reason !== null)
      .map((event) => event.retirementRequestedAt ?? event.observedAt),
  );
  check(binding.completedAt < terminalAt, 'binding extends into retired native ownership');
  // A read can lag behind its actor snapshot. Anchor the available token
  // budget to the latest provable native instant, not the read's observedAt.
  const checkPacing = (before, after, message) => {
    const delta = counter(after.acceptedPayloadBytes) - counter(before.acceptedPayloadBytes);
    if (delta === 0) return;
    const checkpointAt = Math.max(
      before.leaseDeadline - 0.3,
      before.lastAcceptedAt ?? stage.startedAt,
    );
    check(
      delta > 0 &&
        after.lastAcceptedAt >= checkpointAt &&
        (delta / 1316) * 10880 <= (after.lastAcceptedAt - checkpointAt) * stage.bitRate + 10881,
      message,
    );
  };
  let previous;
  for (const [index, observation] of [binding.initial, binding.final].entries()) {
    check(
      observation &&
        typeof observation.id === 'string' &&
        observation.id.toLowerCase() === stage.id,
      'binding names a different native stage',
    );
    for (const [key, expected] of Object.entries({
      campaign: campaign.campaign,
      publishingGeneration: stage.publishingGeneration,
      stage: 3,
      bitRate: stage.bitRate,
      startedAt: stage.startedAt,
      reason: null,
    }))
      assert.equal(
        observation[key],
        expected,
        `Repeated native candidate: binding ${key} mismatch`,
      );
    for (const at of [
      observation.observedAt,
      observation.leaseDeadline,
      observation.lastAcceptedAt,
    ])
      check(time(at), 'invalid native observation time');
    check(
      observation.startedAt <= observation.lastAcceptedAt &&
        observation.lastAcceptedAt <= observation.observedAt &&
        observation.observedAt < observation.leaseDeadline &&
        observation.leaseDeadline - 0.3 <= observation.observedAt + 1e-6,
      'native observation outside live lease',
    );
    if (index === 0) assert.equal(observation.observedAt, binding.boundAt);
    else
      check(
        measurement.endedAt <= observation.observedAt &&
          observation.observedAt <= binding.completedAt,
        'final observation outside completion',
      );
    const accepted = counter(observation.acceptedPayloadBytes);
    check(
      accepted > 0 && accepted <= stage.acceptedPayloadBytes,
      'binding exceeds native acceptance',
    );
    const renewal = events.find(
      (event) => event.sample.leaseDeadline === observation.leaseDeadline,
    );
    check(renewal && renewal.sample.reason === null, 'unobserved live binding lease');
    check(
      accepted >= counter(renewal.sample.acceptedPayloadBytes) &&
        observation.lastAcceptedAt >= (renewal.sample.lastAcceptedAt ?? stage.startedAt),
      'binding counters precede native lease renewal',
    );
    check(
      (accepted / 1316) * 10880 <=
        (observation.lastAcceptedAt - stage.startedAt) * stage.bitRate + 1,
      'binding acceptance exceeds native pacing',
    );
    for (const event of events) {
      const n = counter(event.sample.acceptedPayloadBytes),
        last = event.sample.lastAcceptedAt;
      if (n === accepted)
        assert.equal(
          last,
          observation.lastAcceptedAt,
          'Native acceptance timestamp changed without bytes',
        );
      if (last === observation.lastAcceptedAt)
        assert.equal(n, accepted, 'Native count changed without acceptance');
      else if (last === null || last < observation.lastAcceptedAt)
        check(n <= accepted, 'binding counter regresses native history');
      else check(n >= accepted, 'binding counter exceeds native history');
      if (accepted > n)
        checkPacing(
          event.sample,
          observation,
          'binding acceptance exceeds one-message native token allowance',
        );
      else if (n > accepted)
        checkPacing(
          observation,
          event.sample,
          'native acceptance after binding exceeds one-message token allowance',
        );
      if (event.observedAt <= observation.observedAt) {
        check(
          event.sample.reason === null &&
            n <= accepted &&
            event.sample.leaseDeadline <= observation.leaseDeadline,
          'binding predates observed native ownership',
        );
      }
      // Native reads and candidate reads share the monotonic clock. Future
      // accepted payload cannot appear in an earlier candidate observation.
      if (last !== null && last > observation.observedAt)
        check(n > accepted, 'binding borrows future native acceptance');
    }
    if (previous) {
      check(
        accepted >= counter(previous.acceptedPayloadBytes) &&
          observation.lastAcceptedAt >= previous.lastAcceptedAt &&
          observation.leaseDeadline >= previous.leaseDeadline,
        'binding counters or lease regress across measurement',
      );
      if (accepted === counter(previous.acceptedPayloadBytes))
        assert.equal(
          observation.lastAcceptedAt,
          previous.lastAcceptedAt,
          'Binding acceptance timestamp changed without bytes',
        );
      checkPacing(
        previous,
        observation,
        'binding endpoints exceed one-message native token allowance',
      );
    }
    previous = observation;
  }
  return {
    probeId: stage.id,
    stage: 3,
    boundAt: binding.boundAt,
    completedAt: binding.completedAt,
  };
}

/** Independently replays the original v4 envelope and raw native dependencies.
 * Candidate cost and baseline continuity do not establish receiver headroom,
 * recovery, admission, trial confirmation, or production upgrade permission. */
export function qualifyRepeatedNativeCandidateMeasurements(
  proof,
  { scope, nativeProbe, format, snapshot, liveIDs } = {},
) {
  check(
    proof?.formatVersion === 4 && proof.isClosed === true && proof.maximumCampaigns === 2,
    'requires a closed v4 two-campaign envelope',
  );
  assert.deepEqual(proof.scope, scope, 'Repeated native candidate: publication scope mismatch');
  assert.deepEqual(format?.scope, scope, 'Repeated native candidate: media scope mismatch');
  check(
    Array.isArray(proof.campaigns) && proof.campaigns.length === 2,
    'requires exactly two campaigns',
  );
  const native = qualifyRepeatedNativeBandwidthProbe(nativeProbe, {
    scope,
    publishingGeneration: format.publishingGeneration,
  });
  const media = qualifyNativeProfileTransitions(format, snapshot, liveIDs, {
    sequence: 'repeated240',
    requireFrameEvidence: true,
  });
  const decoded = new Set(liveIDs),
    nativeFrames = new Map(
      format.compressedFrames.map((frame) => [fixtureFrameID(frame.sourcePTS), frame]),
    ),
    measurementIDs = new Set(),
    encoderIDs = new Set(
      format.encoderSessions.map((encoder) => encoder.encoderSessionID.toLowerCase()),
    );
  let previous;
  const campaigns = proof.campaigns.map((row, index) => {
    const accepted = native.campaigns[index],
      baselinePhaseIndex = index * 2,
      baseline = media.phases[baselinePhaseIndex],
      rawBaseline = format.phases[baselinePhaseIndex];
    check(
      row.campaign === accepted.campaign && row.started === true,
      'campaign mismatch or operations never started',
    );
    assert.equal(
      row.appliedRevision,
      accepted.context.appliedRevision,
      'Repeated native candidate: stale applied revision',
    );
    assert.equal(
      accepted.context.encoderSessionID.toLowerCase(),
      baseline.encoderSessionID.toLowerCase(),
      'Repeated native candidate: readiness names a different baseline encoder',
    );
    const p = row.measurement,
      m = p?.measurement;
    const candidate = qualifyNativeCandidateMeasurement(p, {
      scope,
      profile: '360p30',
      liveProfile: '240p30',
      requiredFormatVersion: 3,
      format: { ...baseline, scope, publishingGeneration: media.publishingGeneration },
    });
    check(
      accepted.context.acknowledgedAt <= m.startedAt &&
        rawBaseline.firstObservedAt <= m.startedAt &&
        m.endedAt <= format.phases[baselinePhaseIndex + 1].firstObservedAt,
      'measurement outside its actual baseline phase',
    );
    check(
      p.publisherStartedAt <= rawBaseline.firstObservedAt,
      'publisher clock starts after baseline',
    );
    const id = candidate.id.toLowerCase(),
      encoderID = candidate.encoderSessionID.toLowerCase();
    check(!measurementIDs.has(id), 'reused measurement identity');
    check(!encoderIDs.has(encoderID), 'reused candidate or live encoder identity');
    measurementIDs.add(id);
    encoderIDs.add(encoderID);
    for (let frameID = candidate.firstFrame; frameID <= candidate.lastFrame; frameID++) {
      check(
        frameID >= baseline.firstFrame &&
          frameID <= baseline.lastFrame &&
          nativeFrames.has(frameID),
        'candidate source frame missing from native baseline',
      );
      check(decoded.has(frameID), 'candidate source frame missing from decoded live media');
    }
    const binding = qualifyBinding(
      p.probeBinding,
      m,
      p.closedAt,
      accepted,
      nativeProbe.campaigns[index],
    );
    if (previous) {
      assert.equal(
        p.publisherStartedAt,
        previous.proof.publisherStartedAt,
        'Repeated native candidate: changed publication clock',
      );
      check(
        m.startedAt > previous.proof.closedAt &&
          m.startedAt > native.campaigns[index - 1].joinedObservedAt &&
          m.startedAt >= accepted.campaignStartedAt &&
          binding.boundAt > previous.proof.closedAt,
        'new measurement overlaps previous campaign ownership',
      );
      check(candidate.firstFrame > previous.candidate.lastFrame, 'reused candidate source window');
    }
    previous = { proof: p, candidate };
    return {
      ...candidate,
      campaign: row.campaign,
      appliedRevision: row.appliedRevision,
      baselinePhaseIndex,
      baselineEncoderSessionID: baseline.encoderSessionID,
      publishingGeneration: media.publishingGeneration,
      startedAt: m.startedAt,
      endedAt: m.endedAt,
      closedAt: p.closedAt,
      ...binding,
    };
  });
  return {
    formatVersion: 4,
    scope,
    publishingGeneration: media.publishingGeneration,
    campaigns,
    receiverCapacityQualified: false,
    admissionQualified: false,
    recoveryQualified: false,
    repeatedPolicyQualified: false,
    upgradeAuthorized: false,
  };
}
