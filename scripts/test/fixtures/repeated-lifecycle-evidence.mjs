import { repeatedCandidateFixture } from './repeated-candidate-evidence.mjs';

const id = (n) => `cccccccc-cccc-4ccc-8ccc-${String(n).padStart(12, '0')}`;
const observation = (sample) => {
  const { campaignStartedAt, totalAcceptedPayloadBytes, ...value } = sample;
  return structuredClone(value);
};
const normalizedRate = (r) => ({
  acceptedAt: r.acceptedAt,
  bitRate: r.bitRate,
  configurationID: r.configurationID,
  encoderSessionID: r.encoderSessionID,
  generation: r.publishingGeneration,
  lastSubmittedPTS: r.lastSubmittedSourcePTS,
});

/** Synthetic raw exports for two actual receipt chains on one publication clock.
 * No receiver capacity, healthy recovery, or policy success is manufactured here.
 */
export function repeatedLifecycleFixture() {
  const f = repeatedCandidateFixture();
  const { nativeProbe: probe, ...media } = f.options;
  const candidateProof = f.proof;
  const { scope, format, snapshot } = media;
  function shiftMeasurement(value, key = '') {
    if (Array.isArray(value)) return value.map((v) => shiftMeasurement(v));
    if (value && typeof value === 'object') {
      if ('timescale' in value && 'value' in value)
        return { ...value, value: String(BigInt(value.value) + BigInt(5 * value.timescale)) };
      return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, shiftMeasurement(v, k)]));
    }
    return typeof value === 'number' && key.endsWith('At') ? value + 5 : value;
  }
  for (const [index, campaign] of probe.campaigns.entries()) {
    const first = campaign.events.find((e) => e.sample.stage === 3).sample;
    campaign.events = campaign.events.filter((e) => e.sample.stage !== 3 || e.phase === 'replaced');
    for (let n = 1; n <= 124; n++) {
      const at = first.startedAt + n * 0.1;
      campaign.events.push({
        phase: 'renewed',
        observedAt: at + 0.001,
        sample: {
          ...first,
          leaseDeadline: at + 0.3,
          acceptedPayloadBytes: String(n * 1316),
          totalAcceptedPayloadBytes: String(5264 + n * 1316),
          lastAcceptedAt: at - 0.01,
        },
      });
    }
    const terminal = { ...campaign.events.at(-1).sample, reason: 'cancelled' };
    campaign.events.push(
      { phase: 'observed', observedAt: 130 + index * 60, sample: terminal },
      { phase: 'final', observedAt: 130.02 + index * 60, sample: { ...terminal } },
    );
    campaign.status = 'withdrawn';
    const row = candidateProof.campaigns[index];
    row.measurement = shiftMeasurement(row.measurement);
    const p = row.measurement;
    p.publisherStartedAt = 100;
    const renewals = campaign.events.filter((e) => e.sample.stage === 3 && e.phase === 'renewed');
    p.probeBinding.initial = {
      ...observation(renewals[56].sample),
      observedAt: renewals[56].observedAt,
    };
    p.probeBinding.final = {
      ...observation(renewals[119].sample),
      observedAt: renewals[119].observedAt,
    };
    p.probeBinding.boundAt = p.probeBinding.initial.observedAt;
    p.probeBinding.completedAt = p.probeBinding.final.observedAt + 0.001;
    p.closedAt = p.probeBinding.completedAt + 0.01;
  }
  // The lifecycle serializer names this timestamp dequeuedAt; the media replay
  // additionally retains observedAt for its frame timing checks.
  for (const frame of format.compressedFrames) {
    frame.dequeuedAt = frame.observedAt;
    frame.sourceCadencePaced = true;
  }
  const first = format.compressedFrames[0];
  const startup = {
    profile: '240p30',
    width: 426,
    height: 240,
    publishingGeneration: format.publishingGeneration,
    encoderSessionID: format.encoderSessions[0].encoderSessionID,
    firstSourcePTS: first.sourcePTS,
    submittedAt: 99.99,
    completedAt: 100,
    observedAt: first.dequeuedAt,
  };
  const startupFormat = {
    formatVersion: 1,
    isClosed: true,
    invalid: true,
    scope,
    frames: format.frames,
    publishingGeneration: format.publishingGeneration,
    profile: '240p30',
    width: 426,
    height: 240,
    firstSourcePTS: first.sourcePTS,
    lastSourcePTS: format.compressedFrames.at(-1).sourcePTS,
    startup,
    firstEncoding: {
      encoderSessionID: startup.encoderSessionID,
      configurationID: null,
      configuredBitRate: null,
      sourcePTS: first.sourcePTS,
      outputPTS: first.sourcePTS,
      submittedAt: startup.submittedAt,
      completedAt: startup.completedAt,
    },
    firstCompressed: {
      bytes: first.byteCount,
      codec: 0x61766331,
      dequeuedAt: first.dequeuedAt,
      height: 240,
      width: 426,
      isSync: true,
      publishingGeneration: format.publishingGeneration,
      sourcePTS: first.sourcePTS,
      valid: true,
      wasEncoded: true,
    },
  };
  const initialRate = {
    requestID: id(1),
    profileRequestID: null,
    requestedAt: 100.04,
    completedAt: 100.06,
    targetBitRate: 350000,
    outcome: 'completed',
    failure: null,
    profileLinkUnambiguous: true,
    receipt: {
      acceptedAt: 100.05,
      bitRate: 350000,
      configurationID: probe.campaigns[0].context.configurationID,
      encoderSessionID: startup.encoderSessionID,
      publishingGeneration: format.publishingGeneration,
      lastSubmittedSourcePTS: first.sourcePTS,
    },
  };
  const bootstrap = {
    kind: 'bootstrap',
    at: 100.11,
    acknowledgedAt: 100.1,
    closed: false,
    profileID: '240p30',
    revision: '0',
    receipt: normalizedRate(initialRate.receipt),
  };
  const quality = {
    formatVersion: 4,
    overflow: false,
    measuredSourceEvaluationEnabled: true,
    events: [bootstrap],
  };
  const lifecycle = {
    formatVersion: 1,
    isClosed: true,
    invalid: false,
    overflow: false,
    scope,
    closedAt: 252,
    profileRequestLimit: 16,
    bitRateRequestLimit: 48,
    profileRequests: [],
    bitRateRequests: [initialRate],
  };
  for (const [index, receipt] of format.receipts.entries()) {
    const trial = index % 2 === 0;
    const campaignIndex = Math.floor(index / 2),
      campaign = probe.campaigns[campaignIndex];
    const p = candidateProof.campaigns[campaignIndex].measurement;
    const current = campaign.events.findLast((e) => e.phase === 'renewed').sample;
    const at = 130 + index * 30;
    const application = {
      id: id(20 + index),
      attemptID: scope.publishingAttemptID,
      candidateID: trial ? p.measurement.id : null,
      fromRevision: String(index),
      admittedAt: at - 0.03,
      completionDeadline: at + 1.97,
      windowSequence: String(100 + index),
    };
    const action = {
      kind: trial ? 'trial' : 'reset',
      candidateID: application.candidateID,
      fromRevision: application.fromRevision,
      profileID: receipt.profile,
      bitRate: trial ? 600000 : 350000,
      validUntil: at + 0.1,
    };
    const row = {
      requestID: id(10 + index),
      targetProfile: receipt.profile,
      requestedAt: at - 0.02,
      completedAt: at + 0.105,
      receipt,
      outcome: 'completed',
      failure: null,
      candidateMeasurementID: p.measurement.id,
      authorityPermitted: trial,
      probeAuthorityPermitted: trial,
      currentProbeActive: trial,
      currentProbe: observation(current),
      probeBinding: {
        boundAt: p.probeBinding.boundAt,
        candidateCompletedAt: p.probeBinding.completedAt,
        observation: observation(p.probeBinding.initial),
      },
      terminalProbeRead: {
        startedAt: at + 0.11,
        completedAt: at + 0.12,
        observation: observation(campaign.events.at(-1).sample),
      },
    };
    delete row.probeBinding.observation.observedAt;
    const rate = {
      requestID: id(30 + index),
      profileRequestID: row.requestID,
      targetBitRate: action.bitRate,
      requestedAt: at + 0.13,
      completedAt: at + 0.15,
      outcome: 'completed',
      failure: null,
      profileLinkUnambiguous: true,
      receipt: {
        acceptedAt: at + 0.14,
        bitRate: action.bitRate,
        configurationID: index === 1 ? probe.campaigns[1].context.configurationID : id(50 + index),
        encoderSessionID: receipt.encoderSessionID,
        publishingGeneration: format.publishingGeneration,
        lastSubmittedSourcePTS: receipt.firstNewSourcePTS,
      },
    };
    const applied = {
      kind: 'applied',
      at: at + 0.17,
      acknowledgedAt: at + 0.16,
      closed: false,
      profileID: receipt.profile,
      revision: String(index + 1),
      action,
      application,
      profileReceipt: receipt,
      receipt: normalizedRate(rate.receipt),
    };
    lifecycle.profileRequests.push(row);
    lifecycle.bitRateRequests.push(rate);
    quality.events.push(applied);
    if (trial)
      quality.events.push({
        ...structuredClone(applied),
        kind: 'candidate',
        at: at + 0.18,
        evaluatedAt: at - 0.04,
        state: 'healthy',
        reasons: ['trialRecommended'],
        candidate: {
          id: p.measurement.id,
          attemptID: scope.publishingAttemptID,
          appliedRevision: String(index),
          baselineProfileID: '240p30',
          baselineVideoBitrate: 350000,
          profileID: '360p30',
          videoBitrate: 600000,
          measuredStart: p.measurement.startedAt,
          measuredEnd: p.measurement.endedAt,
          evaluatedAt: at - 0.05,
          validUntil: current.leaseDeadline,
        },
        // Retirement consumes only these ownership fields. Receiver intervals and
        // headroom are intentionally absent; this is not a full admission fixture.
        candidateAdmission: {
          probe: observation(current),
          binding: observation(row.probeBinding.observation),
          boundAt: row.probeBinding.boundAt,
          completedAt: row.probeBinding.candidateCompletedAt,
          measurement: { id: p.measurement.id },
          applied: {
            revision: String(index),
            attemptID: scope.publishingAttemptID,
            profileID: '240p30',
            videoBitrate: 350000,
            acknowledgedAt:
              index === 0
                ? bootstrap.acknowledgedAt
                : quality.events.find((e) => e.kind === 'applied' && e.revision === '2')
                    .acknowledgedAt,
            receipt:
              index === 0
                ? bootstrap.receipt
                : quality.events.find((e) => e.kind === 'applied' && e.revision === '2').receipt,
          },
        },
      });
  }
  probe.campaigns[1].context.acknowledgedAt = quality.events.find(
    (e) => e.kind === 'applied' && e.revision === '2',
  ).acknowledgedAt;
  return { ...media, probe, candidateProof, lifecycle, quality, startupFormat };
}
