import assert from 'node:assert/strict';
import { qualifyOwnedNativeCandidateMeasurements } from './owned-native-candidate-measurements.mjs';
import { qualifyOwnedNativeReceiverIntervals } from './owned-native-receiver-intervals.mjs';
import { qualifyCandidateWitnessLoad } from './measured-candidate-witness.mjs';
import { expandQualityEvidence } from './quality-evidence-dictionary.mjs';

const check = (value, message) => assert.ok(value, `Owned admission/application: ${message}`);
const time = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e12;
const id = (s) => {
  check(
    typeof s === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(s),
    'invalid UUID',
  );
  return s.toLowerCase();
};
const sameID = (a, b) => assert.equal(id(a), id(b));
const normalizeReceipt = (r, native = false) => ({
  acceptedAt: r.acceptedAt,
  bitRate: r.bitRate,
  configurationID: id(r.configurationID),
  encoderSessionID: id(r.encoderSessionID),
  generation: native ? r.publishingGeneration : r.generation,
  lastSubmittedPTS: native ? r.lastSubmittedSourcePTS : r.lastSubmittedPTS,
});
// The owned audit alone adds campaign/publication totals. Compare every field
// of the actual wire probe, including the frozen recovery observation.
const probeWire = (p) => ({
  id: id(p.id),
  ...Object.fromEntries(
    [
      'acceptedPayloadBytes',
      'bitRate',
      'campaign',
      'lastAcceptedAt',
      'leaseDeadline',
      'policy',
      'publishingGeneration',
      'reason',
      'recoveryObservation',
      'stage',
      'startedAt',
    ].map((k) => [k, p[k]]),
  ),
});
const sameProbe = (a, b) =>
  assert.deepEqual(probeWire(a), probeWire(b), 'Owned admission/application: probe mismatch');
const ordered = (...values) =>
  check(
    values.every(time) && values.every((v, i) => i === 0 || values[i - 1] <= v),
    'invalid chronology',
  );

function nativeApplications(lifecycle, quality, format, snapshot, scope, publishingGeneration) {
  const audit = lifecycle;
  check(
    audit && Buffer.byteLength(JSON.stringify(audit)) <= 512 * 1024,
    'missing or oversized lifecycle',
  );
  assert.equal(audit.formatVersion, 1);
  assert.equal(audit.isClosed, true);
  assert.equal(audit.invalid, false);
  assert.equal(audit.overflow, false);
  assert.deepEqual(audit.scope, scope);
  assert.equal(audit.profileRequestLimit, 16);
  assert.equal(audit.bitRateRequestLimit, 48);
  check(
    Array.isArray(audit.profileRequests) && audit.profileRequests.length <= 16,
    'unbounded profile requests',
  );
  check(
    Array.isArray(audit.bitRateRequests) && audit.bitRateRequests.length <= 48,
    'unbounded bitrate requests',
  );
  ordered(snapshot.monotonicAnchor, audit.closedAt, snapshot.captureDetachedAt + 2);
  const bounded = (...at) => {
    ordered(...at);
    for (const v of at) ordered(snapshot.monotonicAnchor, v, audit.closedAt);
  };
  const configurations = quality.events.flatMap((row, index) =>
    ['bootstrap', 'applied'].includes(row.kind) ? [{ row, index }] : [],
  );
  assert.equal(audit.profileRequests.length, configurations.length - 1);
  assert.equal(audit.bitRateRequests.length, configurations.length);
  const ids = new Set();
  const unique = (value) => {
    const key = id(value);
    check(!ids.has(key), 'reused lifecycle request/application');
    ids.add(key);
  };
  audit.bitRateRequests.forEach((rate, index) => {
    unique(rate.requestID);
    assert.equal(rate.outcome, 'completed');
    assert.equal(rate.failure, null);
    assert.equal(rate.profileLinkUnambiguous, true);
    const q = configurations[index].row;
    bounded(rate.requestedAt, rate.receipt.acceptedAt, rate.completedAt, q.acknowledgedAt, q.at);
    assert.equal(rate.receipt.publishingGeneration, publishingGeneration);
    assert.equal(rate.targetBitRate, rate.receipt.bitRate);
    assert.deepEqual(normalizeReceipt(rate.receipt, true), normalizeReceipt(q.receipt));
    if (index === 0) assert.equal(rate.profileRequestID, null);
    else sameID(rate.profileRequestID, audit.profileRequests[index - 1].requestID);
  });
  return audit.profileRequests.map((request, index) => {
    unique(request.requestID);
    const { row: q, index: qualityEventIndex } = configurations[index + 1],
      application = q.application,
      rate = audit.bitRateRequests[index + 1],
      terminal = request.terminalProbeRead;
    unique(application.id);
    assert.equal(request.outcome, 'completed');
    assert.equal(request.failure, null);
    assert.equal(request.targetProfile, q.profileID);
    assert.equal(request.targetProfile, q.action.profileID);
    assert.deepEqual(request.receipt, q.profileReceipt);
    assert.deepEqual(request.receipt, format.receipts[index]);
    sameID(rate.receipt.encoderSessionID, request.receipt.encoderSessionID);
    bounded(
      application.admittedAt,
      request.requestedAt,
      request.receipt.acknowledgedAt,
      request.completedAt,
      terminal.startedAt,
      terminal.completedAt,
      rate.requestedAt,
      rate.receipt.acceptedAt,
      rate.completedAt,
      q.acknowledgedAt,
      q.at,
    );
    check(request.requestedAt < q.action.validUntil, 'native request after advice expiry');
    check(q.acknowledgedAt <= application.completionDeadline, 'late application acknowledgement');
    if (q.action.kind === 'trial') {
      sameID(request.candidateMeasurementID, application.candidateID);
      for (const k of ['authorityPermitted', 'probeAuthorityPermitted', 'currentProbeActive'])
        assert.equal(request[k], true);
    } else {
      // The currently supported original downward application has no candidate
      // authority. Its retained terminal probe is checked against raw history.
      check(['reset', 'decrease'].includes(q.action.kind), 'unsupported downward application');
      assert.equal(application.candidateID, null);
      assert.equal(request.candidateMeasurementID, null);
      for (const k of ['authorityPermitted', 'probeAuthorityPermitted', 'currentProbeActive'])
        assert.equal(request[k], false);
      assert.equal(request.currentProbe, null);
      assert.deepEqual(request.probeBinding, {
        boundAt: null,
        candidateCompletedAt: null,
        observation: null,
      });
    }
    return {
      request,
      rate,
      row: q,
      qualityEventIndex,
      profileRequestIndex: index,
      bitRateRequestIndex: index + 1,
    };
  });
}

/** Whole original owned evidence, with captured admission and native application
 * correspondence only. Candidate cost and receiver coverage are replayed here;
 * no supplied summaries, legacy rewrites, recovery or media authority. */
export function qualifyOwnedNativeAdmissionApplication(input) {
  check(input && typeof input === 'object', 'missing inputs');
  assert.deepEqual(
    Reflect.ownKeys(input).sort(),
    [
      'rawOwned',
      'quality',
      'format',
      'snapshot',
      'liveIDs',
      'intervals',
      'records',
      'workerRecords',
      'lifecycle',
      'scope',
      'publishingGeneration',
      'timingProfile',
    ].sort(),
    'Owned admission/application: exact complete inputs required',
  );
  const {
    rawOwned,
    quality,
    format,
    snapshot,
    liveIDs,
    intervals,
    records,
    workerRecords,
    lifecycle,
    scope,
    publishingGeneration,
    timingProfile,
  } = input;
  const costs = qualifyOwnedNativeCandidateMeasurements(rawOwned, {
    quality,
    format,
    snapshot,
    liveIDs,
    scope,
    publishingGeneration,
    timingProfile,
  });
  const coverage = qualifyOwnedNativeReceiverIntervals({
    rawOwned,
    intervals,
    records,
    workerRecords,
    scope,
    publishingGeneration,
    timingProfile,
  });
  const q = expandQualityEvidence(quality),
    applications = nativeApplications(lifecycle, q, format, snapshot, scope, publishingGeneration);
  const decisions = q.events.flatMap((row, index) =>
    row.kind === 'candidate' ? [{ row, index }] : [],
  );
  const usedDecisions = new Set(),
    usedApplications = new Set();
  const attempts = costs.attempts.map((attempt) => {
    const events = attempt.eventIndices.map((index) => ({ index, row: rawOwned.events[index] }));
    if (!attempt.measurement) {
      check(
        events.every(
          ({ row }) =>
            !['applicationID', 'candidateID'].some((k) => Object.hasOwn(row, k)) &&
            (!Object.hasOwn(row, 'receipt') ||
              ['registered', 'contextCaptured'].includes(row.kind)),
        ),
        'failed owner carries application evidence',
      );
      return { ...attempt, admission: null, application: null };
    }
    check(
      attempt.terminal === 'settledAcknowledged',
      'unsupported unacknowledged joined candidate',
    );
    const candidate = attempt.measurement,
      raw = rawOwned.events[attempt.candidateJoinedEventIndex].measurement;
    const matches = decisions.filter(({ row }) => id(row.candidate.id) === id(candidate.id));
    check(matches.length === 1, 'candidate lacks unique original quality decision');
    const { row: decision, index: qualityEventIndex } = matches[0],
      w = decision.candidateAdmission;
    check(!usedDecisions.has(qualityEventIndex), 'reused quality candidate');
    usedDecisions.add(qualityEventIndex);
    const joinedApplications = applications.filter(
      ({ row }) =>
        row.application.candidateID !== null &&
        id(row.application.candidateID) === id(candidate.id),
    );
    check(joinedApplications.length === 1, 'candidate lacks unique native application');
    const application = joinedApplications[0],
      { request, row: applied } = application,
      a = applied.application;
    check(!usedApplications.has(application.profileRequestIndex), 'reused native application');
    usedApplications.add(application.profileRequestIndex);
    check(application.qualityEventIndex < qualityEventIndex, 'candidate precedes applied event');
    const nextApplied = applications.find(
      (x) => x.qualityEventIndex > application.qualityEventIndex,
    );
    check(
      !nextApplied || qualityEventIndex < nextApplied.qualityEventIndex,
      'candidate crosses subsequent application',
    );
    for (const k of [
      'revision',
      'profileID',
      'acknowledgedAt',
      'receipt',
      'profileReceipt',
      'application',
      'action',
    ])
      assert.deepEqual(decision[k], applied[k]);
    assert.equal(w?.formatVersion, 2);
    assert.equal(w.convention, 'measured-candidate-ipv4-recovery-v1');
    assert.deepEqual(
      { ...w.measurement, id: id(w.measurement.id) },
      {
        endedAt: raw.endedAt,
        firstInputAt: raw.encoding.frames[0].admittedAt,
        id: id(raw.id),
        lastInputAt: raw.encoding.frames.at(-1).admittedAt,
        profile: raw.profile,
        publishingGeneration,
        scope,
        sourceDuration: candidate.sourceDuration,
        startedAt: raw.startedAt,
        submissionDuration: candidate.submissionDuration,
        transportBytes: candidate.transport.transportBytes,
        transportMessageCount: candidate.transport.transportMessageCount,
      },
    );
    const baseline = q.events[attempt.baselineQualityEventIndex],
      wa = w.applied;
    assert.equal(wa.revision, attempt.appliedRevision);
    assert.equal(wa.profileID, '240p30');
    assert.equal(wa.videoBitrate, 350000);
    sameID(wa.attemptID, scope.publishingAttemptID);
    assert.equal(wa.acknowledgedAt, baseline.acknowledgedAt);
    assert.deepEqual(normalizeReceipt(wa.receipt), normalizeReceipt(baseline.receipt));
    const bound = rawOwned.events[attempt.candidateBoundEventIndex],
      binding = request.probeBinding;
    assert.deepEqual(Object.keys(binding).sort(), [
      'boundAt',
      'candidateCompletedAt',
      'observation',
    ]);
    assert.equal(w.boundAt, bound.boundAt);
    assert.equal(w.boundAt, binding.boundAt);
    assert.equal(w.completedAt, binding.candidateCompletedAt);
    sameProbe(w.binding, bound.snapshot);
    sameProbe(w.binding, binding.observation);
    ordered(
      baseline.acknowledgedAt,
      w.boundAt,
      raw.startedAt,
      raw.endedAt,
      rawOwned.events[attempt.candidateJoinedEventIndex].at,
      w.completedAt,
      w.clock.before,
      w.clock.after,
      decision.evaluatedAt,
      a.admittedAt,
    );
    check(w.clock.after - raw.endedAt <= 2, 'stale candidate');
    check(w.binding.startedAt + 0.5 <= w.boundAt, 'binding lacks sustained stage');
    assert.equal(w.binding.campaign, attempt.campaign);
    assert.equal(w.binding.stage, 3);
    assert.equal(w.binding.bitRate, 12000000);
    const stage = coverage.attempts
      .find((x) => x.ownerID === attempt.ownerID)
      .stages.find((s) => s.stage === 3);
    check(stage, 'missing native third stage');
    const snapshots = stage.snapshotEventIndices.map((index) => ({
      index,
      row: rawOwned.events[index],
    }));
    // The owned publisher caches an atomic renewed snapshot, rather than
    // exporting a final candidate read. Require the actual latest renewal.
    const cached = snapshots
      .filter(({ row }) => row.kind === 'renewed' && row.at <= w.clock.before)
      .at(-1);
    check(cached, 'missing admission probe renewal');
    sameProbe(w.probe, cached.row.snapshot);
    sameProbe(w.probe, request.currentProbe);
    ordered(cached.row.at, w.clock.before, w.clock.after, request.requestedAt);
    check(
      request.requestedAt < w.probe.leaseDeadline &&
        w.probe.leaseDeadline - w.clock.after <= 0.300001,
      'expired admission probe',
    );
    check(
      w.clock.after < stage.retirementRequestedAt &&
        request.requestedAt < stage.retirementRequestedAt,
      'retired probe used for application',
    );
    const terminal = snapshots.at(-1);
    sameProbe(request.terminalProbeRead.observation, terminal.row.snapshot);
    ordered(terminal.row.at, request.terminalProbeRead.startedAt);
    const admission = qualifyCandidateWitnessLoad({
      witness: w,
      intervals,
      intervalQualification: coverage,
      campaign: attempt.campaign,
      policy: 'recovery-budget-v1',
      completionAt: w.completedAt,
    });
    check(admission.headroomQualified, 'candidate lacks 25% headroom');
    const c = decision.candidate;
    sameID(c.id, candidate.id);
    sameID(c.attemptID, scope.publishingAttemptID);
    for (const [key, value] of Object.entries({
      appliedRevision: attempt.appliedRevision,
      baselineProfileID: '240p30',
      baselineVideoBitrate: 350000,
      profileID: raw.profile,
      videoBitrate: 600000,
      measuredStart: raw.startedAt,
      measuredEnd: raw.endedAt,
      evaluatedAt: w.evaluatedAt,
      validUntil: w.validUntil,
      candidateTransportBitsPerSecond: admission.candidateTransportBitsPerSecond,
      deliveredPaddingBitsPerSecond: admission.deliveredPaddingBitsPerSecond,
    }))
      assert.equal(c[key], value);
    assert.equal(applied.action.kind, 'trial');
    check(applied.action.validUntil <= w.validUntil, 'action exceeds captured admission');
    const transfer = events.filter((e) => e.row.kind === 'applicationTransferred'),
      acks = events.filter((e) => e.row.kind === 'acknowledged');
    check(
      transfer.length === 1 && acks.length === 1,
      'missing application transfer/acknowledgement',
    );
    const t = transfer[0],
      ack = acks[0];
    sameID(t.row.applicationID, a.id);
    sameID(ack.row.applicationID, a.id);
    sameID(t.row.candidateID, candidate.id);
    assert.equal(a.fromRevision, attempt.appliedRevision);
    assert.equal(ack.row.currentAppliedRevision, applied.revision);
    assert.equal(t.row.admittedAt, a.admittedAt);
    assert.equal(t.row.completionDeadline, a.completionDeadline);
    assert.deepEqual(normalizeReceipt(ack.row.receipt, true), normalizeReceipt(applied.receipt));
    ordered(
      a.admittedAt,
      t.row.at,
      request.requestedAt,
      rawOwned.events[attempt.candidateRetiredEventIndex].at,
      rawOwned.events[attempt.cleanupEventIndex].at,
      request.receipt.acknowledgedAt,
      application.rate.completedAt,
      applied.acknowledgedAt,
      ack.row.at,
      applied.at,
      decision.at,
    );
    return {
      ...attempt,
      admission: { ...admission, qualityEventIndex, probeEventIndex: cached.index },
      application: {
        applicationID: id(a.id),
        candidateID: id(candidate.id),
        profileRequestIndex: application.profileRequestIndex,
        bitRateRequestIndex: application.bitRateRequestIndex,
        qualityEventIndex: application.qualityEventIndex,
        transferEventIndex: t.index,
        acknowledgementEventIndex: ack.index,
        fromRevision: a.fromRevision,
        revision: applied.revision,
        nativeApplicationCorrespondenceQualified: true,
      },
    };
  });
  assert.equal(usedDecisions.size, decisions.length, 'Unowned quality candidate');
  assert.equal(
    usedApplications.size,
    applications.filter((x) => x.row.action.kind === 'trial').length,
    'Unowned trial application',
  );
  // Even downward applications must preserve the original terminal audit.
  for (const { request, row } of applications.filter((x) => x.row.action.kind !== 'trial')) {
    const terminal = rawOwned.events
      .filter((e) => e.kind === 'retired' && e.at <= request.requestedAt)
      .at(-1);
    check(terminal, 'reset lacks historical terminal probe');
    sameProbe(request.terminalProbeRead.observation, terminal.snapshot);
    check(row.application.fromRevision !== '0', 'reset without prior trial');
  }
  return {
    ...costs,
    attempts,
    candidateAdmissionQualified: true,
    nativeApplicationCorrespondenceQualified: true,
    admissionQualified: true,
    receiverCapacityQualified: false,
    mediaQualified: false,
    recoveryQualified: false,
    retryPolicyQualified: false,
    upgradeAuthorized: false,
    trialConfirmed: false,
  };
}
