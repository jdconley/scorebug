import assert from 'node:assert/strict';
import { qualifyRepeatedNativeBandwidthProbe } from './repeated-native-bandwidth-probe.mjs';
import {
  qualifyNativeProbeReadInterval,
  assertNativeProbeStateOrder,
} from './native-probe-read-interval.mjs';

const check = (condition, message) => assert.ok(condition, `Repeated probe retirement: ${message}`);
const time = (value) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12;
const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value);
const sameID = (a, b) => uuid(a) && uuid(b) && a.toLowerCase() === b.toLowerCase();
const count = (value) => {
  check(typeof value === 'string' && /^(0|[1-9][0-9]{0,7})$/.test(value), 'malformed native count');
  const n = Number(value);
  check(n <= 16 * 1024 * 1024 && n % 1316 === 0, 'native count outside aligned budget');
  return n;
};
const observationKeys = [
  'id',
  'campaign',
  'stage',
  'bitRate',
  'publishingGeneration',
  'startedAt',
  'leaseDeadline',
  'lastAcceptedAt',
  'acceptedPayloadBytes',
  'reason',
];
function sameObservation(a, b) {
  check(a && b, 'missing native observation');
  for (const key of observationKeys)
    check(key === 'id' ? sameID(a[key], b[key]) : a[key] === b[key], `probe ${key} mismatch`);
}
// Admission receipts serialize UUIDs in lowercase, while quality receipts use
// native uuidString. Compare identities semantically without altering raw proof.
function sameReceipt(actual, expected, context) {
  check(
    actual &&
      expected &&
      sameID(actual.configurationID, expected.configurationID) &&
      sameID(actual.encoderSessionID, expected.encoderSessionID),
    `${context} receipt identity mismatch`,
  );
  for (const key of ['generation', 'bitRate', 'acceptedAt', 'lastSubmittedPTS'])
    assert.deepEqual(
      actual[key],
      expected[key],
      `Repeated probe retirement: ${context} receipt ${key} mismatch`,
    );
}

const checkpoint = (sample) =>
  Math.max(sample.leaseDeadline - 0.3, sample.lastAcceptedAt ?? sample.startedAt);

// Check either interpolation direction. Equal accepted bytes cannot invent a
// newer acceptance timestamp merely because the lease has been renewed.
function reconcileSamples(a, b) {
  const na = count(a.acceptedPayloadBytes),
    nb = count(b.acceptedPayloadBytes);
  if (na === nb) {
    check(a.lastAcceptedAt === b.lastAcceptedAt, 'acceptance timestamp changed without bytes');
    return;
  }
  const [before, after, delta] = na < nb ? [a, b, nb - na] : [b, a, na - nb];
  const at = checkpoint(before);
  check(
    after.lastAcceptedAt >= at &&
      (delta / 1316) * 10880 <= (after.lastAcceptedAt - at) * before.bitRate + 10881,
    'interpolated acceptance exceeds one-message token allowance',
  );
}

function validateActive(value, at, stage, events, read) {
  check(value && time(at), 'missing active observation');
  for (const key of ['id', 'campaign', 'stage', 'bitRate', 'publishingGeneration', 'startedAt'])
    check(
      key === 'id' ? sameID(value[key], stage[key]) : value[key] === stage[key],
      `active ${key} mismatch`,
    );
  check(
    value.reason === null &&
      [value.lastAcceptedAt, value.leaseDeadline].every(time) &&
      value.startedAt <= value.lastAcceptedAt &&
      value.lastAcceptedAt <= at &&
      at < value.leaseDeadline &&
      checkpoint(value) <= at + 1e-6,
    'active observation outside its lease',
  );
  const accepted = count(value.acceptedPayloadBytes);
  check(accepted > 0 && accepted <= stage.acceptedPayloadBytes, 'active counter outside campaign');
  check(
    (accepted / 1316) * 10880 <= (value.lastAcceptedAt - value.startedAt) * value.bitRate + 1,
    'active observation exceeds lifetime pacing',
  );
  const renewal = events.find(
    (event) => event.sample.leaseDeadline === value.leaseDeadline && event.sample.reason === null,
  );
  check(
    renewal &&
      accepted >= count(renewal.sample.acceptedPayloadBytes) &&
      value.lastAcceptedAt >= (renewal.sample.lastAcceptedAt ?? value.startedAt),
    'active observation precedes its native lease renewal',
  );
  if (read) qualifyNativeProbeReadInterval(value, { ...read, usedAt: at, events });
  for (const event of events) {
    reconcileSamples(value, event.sample);
    if (event.observedAt <= at)
      check(
        event.sample.reason === null &&
          (read ||
            (count(event.sample.acceptedPayloadBytes) <= accepted &&
              event.sample.leaseDeadline <= value.leaseDeadline)),
        'active observation follows native withdrawal or regresses history',
      );
  }
}

/** Replays causal native cancellation for two original trial requests. This
 * scalar boundary does not qualify candidate cost, receiver headroom, decoded
 * health, recovery, trial confirmation, or production upgrade permission. */
export function qualifyRepeatedProbeRetirements(
  proof,
  { lifecycle, quality, candidateProof } = {},
) {
  if (candidateProof !== undefined)
    check([4, 5].includes(candidateProof?.formatVersion), 'unknown candidate envelope');
  const bracketed = candidateProof?.formatVersion === 5;
  check(
    lifecycle?.formatVersion === 1 &&
      lifecycle.isClosed === true &&
      lifecycle.invalid === false &&
      lifecycle.overflow === false &&
      time(lifecycle.closedAt),
    'invalid closed lifecycle',
  );
  check(
    lifecycle.profileRequestLimit === 16 &&
      Array.isArray(lifecycle.profileRequests) &&
      lifecycle.profileRequests.length === 4,
    'requires exactly four original profile requests',
  );
  const native = qualifyRepeatedNativeBandwidthProbe(proof, {
    scope: lifecycle.scope,
    publishingGeneration: proof?.publishingGeneration,
  });
  if (bracketed) {
    check(
      candidateProof.isClosed === true &&
        candidateProof.maximumCampaigns === 2 &&
        Array.isArray(candidateProof.campaigns) &&
        candidateProof.campaigns.length === 2,
      'missing closed v5 candidate envelope',
    );
    assert.deepEqual(
      candidateProof.scope,
      lifecycle.scope,
      'Candidate read interval publication mismatch',
    );
  }
  check(
    quality?.formatVersion === 4 &&
      quality.overflow === false &&
      quality.measuredSourceEvaluationEnabled === true &&
      Array.isArray(quality.events) &&
      quality.events.length > 0 &&
      quality.events.length <= 512,
    'invalid raw measured quality',
  );
  const bootstraps = quality.events.filter((event) => event.kind === 'bootstrap');
  check(
    bootstraps.length === 1 && quality.events[0] === bootstraps[0],
    'requires exactly one original first-event bootstrap',
  );
  const bootstrap = bootstraps[0],
    baseline = native.campaigns[0];
  check(
    bootstrap.closed === false &&
      bootstrap.revision === '0' &&
      bootstrap.profileID === '240p30' &&
      bootstrap.receipt?.bitRate === 350000 &&
      bootstrap.receipt.generation === native.publishingGeneration &&
      sameID(bootstrap.receipt.encoderSessionID, baseline.context.encoderSessionID) &&
      sameID(bootstrap.receipt.configurationID, baseline.context.configurationID),
    'bootstrap baseline ownership mismatch',
  );
  check(
    [bootstrap.at, bootstrap.acknowledgedAt, bootstrap.receipt.acceptedAt].every(
      (value) => time(value) && value <= lifecycle.closedAt,
    ) &&
      bootstrap.receipt.acceptedAt <= bootstrap.acknowledgedAt &&
      bootstrap.acknowledgedAt <= bootstrap.at &&
      bootstrap.at < baseline.campaignStartedAt &&
      bootstrap.acknowledgedAt === baseline.context.acknowledgedAt,
    'bootstrap baseline chronology mismatch',
  );
  const candidates = quality.events.filter((event) => event.kind === 'candidate'),
    applications = quality.events.filter((event) => event.kind === 'applied');
  check(
    candidates.length === 2 && applications.length === 4,
    'requires two candidates and four applications',
  );
  const ownedIDs = new Set(),
    candidateIDs = new Set(),
    encoderIDs = new Set(),
    configurationIDs = new Set();
  const unique = (value, set, message) => {
    check(uuid(value) && !set.has(value.toLowerCase()), message);
    set.add(value.toLowerCase());
  };
  unique(native.campaigns[0].context.encoderSessionID, encoderIDs, 'invalid original encoder');
  unique(
    native.campaigns[0].context.configurationID,
    configurationIDs,
    'invalid original configuration',
  );
  const bounded = (value) =>
    check(time(value) && value <= lifecycle.closedAt, 'time outside closed lifecycle');
  for (const campaign of native.campaigns) bounded(campaign.joinedObservedAt);
  let previousApplication;
  for (const [index, applied] of applications.entries()) {
    const request = lifecycle.profileRequests[index],
      app = applied.application,
      action = applied.action,
      receipt = request.receipt,
      terminal = request.terminalProbeRead,
      trial = index % 2 === 0,
      target = trial ? '360p30' : '240p30',
      bitRate = trial ? 600000 : 350000;
    check(
      applied.closed === false &&
        applied.revision === String(index + 1) &&
        applied.profileID === target &&
        action?.kind === (trial ? 'trial' : 'reset') &&
        action.profileID === target &&
        action.bitRate === bitRate &&
        action.fromRevision === String(index) &&
        app?.fromRevision === String(index),
      'application revision or profile mismatch',
    );
    check(
      sameID(app.attemptID, lifecycle.scope.publishingAttemptID),
      'foreign application attempt',
    );
    unique(request.requestID, ownedIDs, 'reused profile request identity');
    unique(app.id, ownedIDs, 'reused application identity');
    check(
      request.targetProfile === target &&
        request.outcome === 'completed' &&
        request.failure === null &&
        receipt &&
        terminal?.observation &&
        applied.receipt,
      'missing completed native application',
    );
    for (const at of [
      app.admittedAt,
      app.completionDeadline,
      action.validUntil,
      request.requestedAt,
      receipt.acknowledgedAt,
      request.completedAt,
      terminal.startedAt,
      terminal.completedAt,
      applied.receipt.acceptedAt,
      applied.acknowledgedAt,
      applied.at,
    ])
      bounded(at);
    check(
      Math.abs(app.completionDeadline - app.admittedAt - 2) < 1e-6 &&
        app.admittedAt <= request.requestedAt &&
        request.requestedAt < action.validUntil &&
        request.requestedAt <= receipt.acknowledgedAt &&
        receipt.acknowledgedAt <= request.completedAt &&
        request.completedAt <= terminal.startedAt &&
        terminal.startedAt <= terminal.completedAt &&
        terminal.completedAt <= applied.receipt.acceptedAt &&
        applied.receipt.acceptedAt <= applied.acknowledgedAt &&
        applied.acknowledgedAt <= app.completionDeadline &&
        applied.acknowledgedAt <= applied.at,
      'application outside native completion bounds',
    );
    check(
      receipt.profile === target &&
        receipt.publishingGeneration === proof.publishingGeneration &&
        receipt.width === (trial ? 640 : 426) &&
        receipt.height === (trial ? 360 : 240),
      'profile receipt target mismatch',
    );
    assert.deepEqual(
      applied.profileReceipt,
      receipt,
      'Repeated probe retirement: applied profile receipt mismatch',
    );
    check(
      sameID(
        receipt.previousEncoderSessionID,
        previousApplication?.profileReceipt.encoderSessionID ??
          native.campaigns[0].context.encoderSessionID,
      ),
      'profile receipt chain mismatch',
    );
    unique(receipt.encoderSessionID, encoderIDs, 'reused native encoder');
    unique(applied.receipt.configurationID, configurationIDs, 'reused native configuration');
    check(
      applied.receipt.bitRate === bitRate &&
        applied.receipt.generation === proof.publishingGeneration &&
        sameID(applied.receipt.encoderSessionID, receipt.encoderSessionID),
      'rate receipt ownership mismatch',
    );
    if (previousApplication)
      check(
        app.admittedAt > previousApplication.at &&
          request.requestedAt > lifecycle.profileRequests[index - 1].terminalProbeRead.completedAt,
        'application overlaps earlier request',
      );
    if (trial) {
      check(
        request.authorityPermitted === true &&
          request.probeAuthorityPermitted === true &&
          request.currentProbeActive === true &&
          sameID(app.candidateID, request.candidateMeasurementID) &&
          sameID(action.candidateID, app.candidateID),
        'trial lacks current native authority',
      );
      unique(app.candidateID, candidateIDs, 'reused trial measurement');
    } else {
      check(
        action.candidateID === null &&
          app.candidateID === null &&
          request.authorityPermitted === false &&
          request.probeAuthorityPermitted === false &&
          request.currentProbeActive === false,
        'reset cannot claim trial authority',
      );
      check(
        request.candidateMeasurementID === null ||
          sameID(
            request.candidateMeasurementID,
            lifecycle.profileRequests[index - 1].candidateMeasurementID,
          ),
        'foreign reset historical measurement',
      );
    }
    previousApplication = applied;
  }
  const campaigns = native.campaigns.map((campaign, index) => {
    const raw = proof.campaigns[index],
      events = raw.events.filter((event) => event.sample.stage === 3),
      stage = campaign.stages[2],
      request = lifecycle.profileRequests[index * 2],
      resetRequest = lifecycle.profileRequests[index * 2 + 1],
      trial = candidates[index],
      applied = applications[index * 2],
      reset = applications[index * 2 + 1],
      candidate = trial.candidate,
      app = trial.application,
      action = trial.action,
      binding = request.probeBinding,
      current = request.currentProbe,
      terminal = request.terminalProbeRead,
      lastLive = events.filter((event) => event.sample.reason === null).at(-1),
      firstCancelled = events.find((event) => event.sample.reason !== null),
      final = events.at(-1);
    check(
      campaign.status === 'withdrawn' &&
        campaign.context.appliedRevision === String(index * 2) &&
        stage.terminalPhase === 'final' &&
        final.phase === 'final' &&
        final.sample.reason === 'cancelled',
      'campaign lacks joined profile cancellation',
    );
    const cancelledBy = Math.min(
      firstCancelled?.observedAt ?? Infinity,
      request.receipt.acknowledgedAt,
      terminal.startedAt,
    );
    check(
      lastLive?.phase === 'renewed' &&
        firstCancelled &&
        checkpoint(lastLive.sample) <= cancelledBy &&
        final.sample.leaseDeadline - 0.3 <= cancelledBy &&
        firstCancelled.observedAt >= request.requestedAt,
      'native cancellation does not bracket its own request',
    );
    sameObservation(terminal.observation, final.sample);
    sameObservation(resetRequest.terminalProbeRead.observation, final.sample);
    check(
      trial.closed === false &&
        trial.revision === applied.revision &&
        trial.profileID === applied.profileID,
      'candidate trial ownership mismatch',
    );
    for (const key of ['action', 'application', 'profileReceipt', 'receipt'])
      assert.deepEqual(
        trial[key],
        applied[key],
        `Repeated probe retirement: candidate ${key} mismatch`,
      );
    check(
      candidate &&
        sameID(candidate.id, request.candidateMeasurementID) &&
        sameID(candidate.attemptID, lifecycle.scope.publishingAttemptID) &&
        candidate.appliedRevision === campaign.context.appliedRevision &&
        candidate.profileID === '360p30' &&
        candidate.videoBitrate === 600000 &&
        candidate.baselineProfileID === '240p30' &&
        candidate.baselineVideoBitrate === 350000,
      'candidate publication, revision, or profile mismatch',
    );
    check(binding?.observation && current, 'missing bound or current native observation');
    for (const at of [
      binding.boundAt,
      binding.candidateCompletedAt,
      candidate.measuredStart,
      candidate.measuredEnd,
      candidate.evaluatedAt,
      candidate.validUntil,
      trial.evaluatedAt,
      trial.acknowledgedAt,
      trial.at,
    ])
      bounded(at);
    check(
      stage.startedAt + 0.5 <= binding.boundAt &&
        binding.boundAt <= candidate.measuredStart &&
        candidate.measuredStart < candidate.measuredEnd &&
        candidate.measuredEnd <= binding.candidateCompletedAt &&
        binding.candidateCompletedAt <= candidate.evaluatedAt &&
        candidate.evaluatedAt <= trial.evaluatedAt &&
        trial.evaluatedAt <= app.admittedAt &&
        request.requestedAt - candidate.evaluatedAt <= 0.25 &&
        action.validUntil <= candidate.validUntil &&
        candidate.validUntil <= current.leaseDeadline &&
        trial.acknowledgedAt === applied.acknowledgedAt &&
        trial.at >= trial.acknowledgedAt &&
        trial.at >= terminal.completedAt,
      'candidate outside owned trial chronology',
    );
    // The admission read is cached. Independent same-owner renewals can occur
    // before native cancellation; raw replay validates their lease provenance.
    check(
      current.leaseDeadline <= final.sample.leaseDeadline &&
        lastLive.sample.leaseDeadline <= final.sample.leaseDeadline &&
        request.requestedAt < current.leaseDeadline &&
        binding.observation.leaseDeadline <= current.leaseDeadline,
      'request lacks a valid cached native lease through dispatch',
    );
    let initialRead, currentRead;
    if (bracketed) {
      const row = candidateProof.campaigns[index],
        p = row?.measurement,
        m = p?.measurement,
        b = p?.probeBinding;
      check(
        row?.campaign === campaign.campaign &&
          row.appliedRevision === campaign.context.appliedRevision &&
          row.started === true &&
          p?.formatVersion === 3 &&
          p.isClosed === true &&
          p.invalidReason === null &&
          sameID(m?.id, candidate.id),
        'candidate read interval identity mismatch',
      );
      assert.deepEqual(
        p.scope,
        lifecycle.scope,
        'Candidate measurement read interval scope mismatch',
      );
      check(
        b &&
          b.initial &&
          b.final &&
          b.boundAt === binding.boundAt &&
          b.completedAt === binding.candidateCompletedAt &&
          m.startedAt === candidate.measuredStart &&
          m.endedAt === candidate.measuredEnd &&
          b.initial.observedAt === b.boundAt &&
          time(p.closedAt) &&
          b.completedAt <= p.closedAt &&
          time(b.final.observedAt) &&
          m.endedAt <= b.final.readStartedAt &&
          b.final.observedAt <= b.completedAt,
        'candidate read interval chronology mismatch',
      );
      sameObservation(b.initial, binding.observation);
      validateActive(b.final, b.final.observedAt, stage, events, b.final);
      assertNativeProbeStateOrder(b.initial, b.final);
      assertNativeProbeStateOrder(b.final, current);
      check(
        count(b.final.acceptedPayloadBytes) <= count(current.acceptedPayloadBytes) &&
          b.final.leaseDeadline <= current.leaseDeadline &&
          b.final.lastAcceptedAt <= current.lastAcceptedAt,
        'admission read precedes final candidate snapshot',
      );
      initialRead = b.initial;
      // This is a separately cached read. Never reuse the final read bracket.
      currentRead = { readStartedAt: b.completedAt, readFinishedAt: candidate.evaluatedAt };
    }
    validateActive(binding.observation, binding.boundAt, stage, events, initialRead);
    validateActive(current, candidate.evaluatedAt, stage, events, currentRead);
    check(
      count(current.acceptedPayloadBytes) >= count(binding.observation.acceptedPayloadBytes) &&
        current.lastAcceptedAt >= binding.observation.lastAcceptedAt,
      'active binding regresses',
    );
    reconcileSamples(binding.observation, current);
    // Dispatch precedes entry to the native actor. Cancellation is joined before
    // the profile receipt, so an in-flight send may complete in this real bracket.
    check(
      final.sample.lastAcceptedAt <= cancelledBy &&
        final.sample.lastAcceptedAt < final.sample.leaseDeadline,
      'acceptance after joined profile cancellation',
    );
    const admission = trial.candidateAdmission;
    check(admission?.applied && admission.measurement, 'missing original admission witness');
    sameObservation(admission.probe, current);
    sameObservation(admission.binding, binding.observation);
    check(
      admission.boundAt === binding.boundAt &&
        admission.completedAt === binding.candidateCompletedAt &&
        sameID(admission.measurement.id, candidate.id) &&
        admission.applied.revision === campaign.context.appliedRevision &&
        sameID(admission.applied.attemptID, lifecycle.scope.publishingAttemptID) &&
        admission.applied.profileID === '240p30' &&
        admission.applied.videoBitrate === 350000 &&
        admission.applied.acknowledgedAt === campaign.context.acknowledgedAt,
      'admission ownership mismatch',
    );
    check(
      admission.applied.receipt?.generation === proof.publishingGeneration &&
        admission.applied.receipt.bitRate === 350000 &&
        sameID(admission.applied.receipt.encoderSessionID, campaign.context.encoderSessionID) &&
        sameID(admission.applied.receipt.configurationID, campaign.context.configurationID),
      'admission baseline receipt mismatch',
    );
    check(
      quality.events.indexOf(reset) > quality.events.indexOf(trial) &&
        reset.application.admittedAt > Math.max(trial.at, applied.at, terminal.completedAt),
      'reset precedes its trial',
    );
    if (index > 0) {
      const previousReset = applications[index * 2 - 1],
        previousRequest = lifecycle.profileRequests[index * 2 - 1];
      check(
        quality.events.indexOf(trial) > quality.events.indexOf(previousReset) &&
          quality.events.indexOf(applied) > quality.events.indexOf(previousReset) &&
          campaign.campaignStartedAt > previousReset.at &&
          campaign.campaignStartedAt > previousRequest.terminalProbeRead.completedAt &&
          campaign.context.acknowledgedAt === previousReset.acknowledgedAt &&
          sameID(campaign.context.encoderSessionID, previousReset.receipt.encoderSessionID) &&
          sameID(campaign.context.configurationID, previousReset.receipt.configurationID),
        'new campaign precedes or substitutes prior reset',
      );
      sameReceipt(admission.applied.receipt, previousReset.receipt, 'reset baseline');
    } else {
      sameReceipt(admission.applied.receipt, bootstrap.receipt, 'bootstrap baseline');
    }
    return {
      campaign: campaign.campaign,
      appliedRevision: campaign.context.appliedRevision,
      probeId: stage.id,
      stage: 3,
      publishingGeneration: native.publishingGeneration,
      retirementKind: 'profile-request-terminal-read',
      profileRequestID: request.requestID,
      retirementRequestedAt: request.requestedAt,
      retiredObservedAt: terminal.completedAt,
      rawTerminalObservedAt: firstCancelled.observedAt,
      joinedObservedAt: campaign.joinedObservedAt,
      resetProfileRequestID: resetRequest.requestID,
    };
  });
  return {
    mode: 'repeated',
    scope: lifecycle.scope,
    publishingGeneration: native.publishingGeneration,
    campaigns,
    receiverCapacityQualified: false,
    admissionQualified: false,
    recoveryQualified: false,
    repeatedPolicyQualified: false,
    upgradeAuthorized: false,
  };
}
