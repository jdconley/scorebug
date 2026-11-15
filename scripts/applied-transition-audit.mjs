import assert from 'node:assert/strict';

const auditOnly = new Set([
  'admittedAt',
  'completionDeadline',
  'profileRequestedAt',
  'rateRequestedAt',
]);
const cadenceFields = new Set([
  'cadenceReceiptID',
  'cadenceEvaluatedAt',
  'cadenceAgeState',
  'cadenceSampleAgeSeconds',
  'cadenceMaximumSampleAgeSeconds',
  'cadenceServerAgeSeconds',
  'cadenceRequestSeconds',
  'cadenceResidenceSeconds',
  'cadenceReceiptPreviouslyConsumed',
  'cadenceRequiresRevalidation',
  'cadenceStalled',
  'cadenceProgressAgeMs',
  'cadenceLastFreshPTS',
]);
for (const field of cadenceFields) auditOnly.add(field);
function cadenceWitness(r) {
  const fields = Object.keys(r).filter((k) => k.startsWith('cadence'));
  if (!fields.length) return; // Older closed audits remain readable.
  assert(
    fields.every((k) => cadenceFields.has(k)),
    'Unknown cadence witness field',
  );
  assert.equal(r.input, 'cadenceRejected');
  assert.equal(r.reasons, 'telemetryInvalidated');
  assert(
    typeof r.error === 'string' && r.error.length > 0 && r.error.length <= 80,
    'Missing cadence error',
  );
  assert(['reset', 'rollback'].includes(r.kind));
  uuid(r.cadenceReceiptID);
  assert.equal(time(r.cadenceEvaluatedAt), time(r.at), 'Detached cadence evaluation');
  assert.equal(time(r.cadenceMaximumSampleAgeSeconds), 0.25);
  for (const field of [
    'cadenceReceiptPreviouslyConsumed',
    'cadenceRequiresRevalidation',
    'cadenceStalled',
  ])
    assert(['true', 'false'].includes(r[field]), 'Invalid cadence boolean');
  if (r.error === 'freshness')
    assert(
      r.cadenceReceiptPreviouslyConsumed === 'false' || r.cadenceRequiresRevalidation === 'true',
    );
  function duration(value, maximum = 1e13) {
    assert(typeof value === 'string' && /^(?:0|[1-9]\d*)(?:\.\d+)?(?:e[+-]?\d+)?$/i.test(value));
    const n = Number(value);
    assert(Number.isFinite(n) && n >= 0 && n <= maximum);
    return n;
  }
  // Core bounds the report age in integer milliseconds before constructing a
  // Duration. Swift serializes each Duration as Double(seconds) + its fraction;
  // allow only binary64 rounding at that large boundary, not a wider age budget.
  const maximumAgeSeconds = Number.MAX_SAFE_INTEGER / 1000;
  const tolerance = (...values) => Number.EPSILON * Math.max(1, ...values) * 8;
  const withinAgeCeiling = (value) =>
    value <= maximumAgeSeconds + tolerance(value, maximumAgeSeconds);
  const server = duration(r.cadenceServerAgeSeconds),
    request = duration(r.cadenceRequestSeconds);
  assert(
    withinAgeCeiling(server) && withinAgeCeiling(request),
    'Cadence component exceeds producer ceiling',
  );
  assert(withinAgeCeiling(server + request), 'Cadence age at receipt exceeds producer ceiling');
  assert(
    ['available', 'beforeReceipt', 'statusExpired', 'ageOverflow'].includes(r.cadenceAgeState),
  );
  if (r.cadenceAgeState === 'beforeReceipt') assert.equal(r.cadenceResidenceSeconds, undefined);
  else duration(r.cadenceResidenceSeconds);
  const sum =
    r.cadenceResidenceSeconds === undefined
      ? undefined
      : server + request + duration(r.cadenceResidenceSeconds);
  if (r.cadenceAgeState === 'ageOverflow') {
    // Below this rounding band overflow is impossible. Inside the band the
    // serialized scalars cannot distinguish either side of the exact limit.
    assert(
      sum >= maximumAgeSeconds - tolerance(sum, maximumAgeSeconds),
      'Cadence overflow contradicts component sum',
    );
  }
  if (r.cadenceAgeState === 'available') {
    const total = duration(r.cadenceSampleAgeSeconds);
    assert(
      withinAgeCeiling(total) && withinAgeCeiling(sum),
      'Available cadence exceeds producer ceiling',
    );
    assert(Math.abs(total - sum) <= tolerance(total, sum), 'Cadence age decomposition disagrees');
    if (r.error === 'freshness')
      assert(total > 0.25, 'Fresh cadence cannot explain freshness rejection');
  } else assert.equal(r.cadenceSampleAgeSeconds, undefined, 'Unavailable cadence has a total');
  const progressAge = duration(r.cadenceProgressAgeMs, Number.MAX_SAFE_INTEGER);
  assert.equal(r.cadenceStalled === 'true', progressAge >= 1000);
  assert(
    typeof r.cadenceLastFreshPTS === 'string' && /^-?(0|[1-9]\d*)$/.test(r.cadenceLastFreshPTS),
  );
  const pts = BigInt(r.cadenceLastFreshPTS);
  assert(pts >= -9007199254740991n && pts <= 9007199254740991n);
}
const uuid = (value) =>
  assert(
    typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value),
    'Noncanonical UUID',
  );
function uint(value) {
  assert(
    typeof value === 'string' && /^(0|[1-9]\d*)$/.test(value) && value.length <= 20,
    'Invalid unsigned integer',
  );
  const result = BigInt(value);
  assert(result <= 18446744073709551615n, 'Integer overflow');
  return result;
}
function time(value) {
  assert(
    typeof value === 'string' && /^(?:0|[1-9]\d*)(?:\.\d+)?(?:e[+-]?\d+)?$/i.test(value),
    'Invalid time',
  );
  const result = Number(value);
  assert(Number.isFinite(result) && result >= 0 && result <= 1e12, 'Nonfinite or unbounded time');
  return result;
}
function pts(value) {
  assert(
    typeof value === 'string' && /^-?(0|[1-9]\d*)\/[1-9]\d*$/.test(value),
    'Invalid exact source PTS',
  );
  const [n, d] = value.split('/').map(BigInt);
  assert(
    n >= -9223372036854775808n && n <= 9223372036854775807n && d <= 2147483647n,
    'Source PTS overflow',
  );
  return [n, d];
}
const comparePTS = (a, b) => {
  const [an, ad] = pts(a),
    [bn, bd] = pts(b);
  return an * bd - bn * ad;
};
function ordered(...times) {
  assert(
    times.every((t, i) => !i || t >= times[i - 1]),
    'Noncausal application timestamps',
  );
}
function hostTime(value) {
  assert(
    typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12,
    'Invalid phase uptime',
  );
  return value;
}

/** Successful-ACK diagnostic evidence only. Does not qualify media, prove native
 * effects that did not ACK, or replace transport/packet and media validators. */
export function verifyAppliedTransitionAudit(audit, phase) {
  return verify(audit, phase, false);
}
/** Explicit physical-v3 contract; still requires a sampled ACK and collapse. */
export function verifyPhysicalAppliedTransitionAudit(audit, phase) {
  return verify(audit, phase, true);
}
function verify(audit, phase, physical) {
  assert.equal(audit?.formatVersion, 1);
  assert.equal(audit.scope, 'successful applications only');
  assert.equal(audit.closed, true, 'Audit not closed');
  assert.equal(audit.overflow, false, 'Incomplete audit');
  assert.equal(audit.maximumRecords, 16);
  assert.equal(audit.maximumRecordBytes, 8192);
  uuid(audit.attemptID);
  const timing = audit.timingContract;
  const budget = {
    'strict1500-v1': 1500,
    'broadcast-reliability2000-v1': 2000,
    'broadcast-reliability3000-v1': 3000,
    'broadcast-reliability3000-v3': 3000,
    'broadcast-reliability6000-v1': 6000,
  }[timing?.profileId];
  assert(budget, 'Unknown timing profile');
  assert.deepEqual(timing, {
    formatVersion: 1,
    scope: 'ordinary-successful-applications',
    profileId: timing.profileId,
    decoderBudgetMs: budget,
    maximumCaptureWindowEvaluationAgeMs:
      budget + (timing.profileId === 'broadcast-reliability3000-v3' ? 1250 : 500),
    maximumCompletedDecoderWindowReportAgeMs: 2000,
    maximumCadenceDeliveryReportAgeMs:
      timing.profileId === 'broadcast-reliability3000-v3' ? 1000 : 250,
    decoderStallThresholdMs: 1000,
  });
  assert(
    Array.isArray(audit.records) && audit.records.length > 0 && audit.records.length <= 16,
    'Missing/unbounded records',
  );
  const byID = new Map();
  let previous;
  const changes = [];
  for (const r of audit.records) {
    assert(
      r && !Array.isArray(r) && Object.values(r).every((v) => typeof v === 'string'),
      'Record must contain scalar strings',
    );
    // Producer uses JSONSerialization withoutEscapingSlashes. All emitted keys and
    // values are ASCII numeric/enum diagnostics; reject other encodings rather than
    // silently disagree about the producer's byte limit.
    const encoded = JSON.stringify(r);
    assert(!/[^\x20-\x7e]/.test(encoded), 'Unsupported record encoding');
    assert(Buffer.byteLength(encoded) <= 8192, 'Oversized record');
    cadenceWitness(r);
    uuid(r.applicationID);
    uuid(r.attemptID);
    uuid(r.rateEncoder);
    if (r.candidateID) uuid(r.candidateID);
    assert.equal(r.attemptID, audit.attemptID);
    assert(!byID.has(r.applicationID), 'Duplicate application');
    const from = uint(r.fromRevision),
      revision = uint(r.revision);
    assert.equal(from, previous ? uint(previous.revision) : 0n, 'Missing successful revision');
    assert.equal(revision, from + 1n);
    uint(r.sequence);
    if (r.causeSequence !== undefined) uint(r.causeSequence);
    assert(
      ['trial', 'increase', 'decrease', 'reset', 'rollback'].includes(r.kind),
      'Unsupported advice kind',
    );
    assert(
      typeof r.input === 'string' && typeof r.reasons === 'string' && r.profile.length > 0,
      'Missing cause/profile',
    );
    const cause = time(r.at),
      admitted = time(r.admittedAt),
      deadline = time(r.completionDeadline),
      rateRequested = time(r.rateRequestedAt),
      native = time(r.nativeAt),
      ack = time(r.ackAt);
    ordered(cause, admitted, rateRequested, native, ack, deadline);
    // Core constructs this exact binary64 sum at admission. Recommendation
    // expiry is a separate boundary and cannot extend the application deadline.
    assert.equal(deadline, admitted + 2, 'Changed Core application deadline');
    assert(admitted <= time(r.validUntil), 'Expired admission');
    assert.equal(uint(r.nativeBitrate), uint(r.bitrate));
    assert(uint(r.bitrate) > 0n);
    uint(r.rateGeneration);
    pts(r.ratePTS);
    if (r.profileRequestedAt !== undefined) {
      ordered(admitted, time(r.profileRequestedAt), time(r.profileNativeAt), rateRequested);
      uuid(r.oldEncoder);
      uuid(r.newEncoder);
      assert.notEqual(r.oldEncoder, r.newEncoder);
      assert.equal(r.newEncoder, r.rateEncoder);
      assert.equal(r.profileGeneration, r.rateGeneration);
      assert(uint(r.formatWidth) > 0n && uint(r.formatHeight) > 0n);
      assert(comparePTS(r.newPTS, r.oldPTS) > 0n, 'Nonincreasing replacement source boundary');
      assert(comparePTS(r.ratePTS, r.newPTS) >= 0n, 'Rate receipt before replacement source');
    } else {
      for (const key of [
        'profileNativeAt',
        'formatWidth',
        'formatHeight',
        'profileGeneration',
        'oldEncoder',
        'newEncoder',
        'oldPTS',
        'newPTS',
      ])
        assert.equal(r[key], undefined, 'Partial profile receipt');
    }
    if (previous) {
      ordered(time(previous.ackAt), admitted);
      assert.equal(r.rateGeneration, previous.rateGeneration, 'Changed publication generation');
      assert.equal(
        r.oldEncoder ?? r.rateEncoder,
        previous.rateEncoder,
        'Broken encoder continuity',
      );
      assert(comparePTS(r.oldPTS ?? r.ratePTS, previous.ratePTS) >= 0n, 'Source moved backwards');
      if (r.profileRequestedAt === undefined)
        assert.equal(r.profile, previous.profile, 'Profile changed without receipt');
    }
    changes.push({
      revision: r.revision,
      applicationID: r.applicationID,
      kind: r.kind,
      profile: r.profile,
      bitrate: Number(r.bitrate),
      causeAt: cause,
      admittedAt: admitted,
      nativeAt: native,
      ackAt: ack,
      applicationMs: (ack - admitted) * 1000,
      profileReplacementMs:
        r.profileRequestedAt === undefined
          ? null
          : (time(r.profileNativeAt) - time(r.profileRequestedAt)) * 1000,
      isDescent: previous ? uint(r.bitrate) < uint(previous.bitrate) : false,
    });
    byID.set(r.applicationID, r);
    previous = r;
  }
  assert.equal(phase?.formatVersion, physical ? 3 : 2);
  assert.equal(phase.contract, physical ? 'physical-recovery720-v1' : 'recovery720');
  if (physical) assert.equal(phase.captureSource, 'physical-camera');
  assert(Array.isArray(phase.samples) && phase.samples.length > 0, 'Missing UI witnesses');
  const observed = new Set();
  for (const sample of phase.samples) {
    const diagnostic =
      typeof sample.diagnostic === 'string' ? JSON.parse(sample.diagnostic) : sample.diagnostic;
    if (!diagnostic?.appliedTransition) continue;
    assert.equal(diagnostic.policyAttemptID, audit.attemptID, 'Foreign sampled attempt');
    assert.equal(diagnostic.timingProfileID, timing.profileId);
    const witness =
      typeof diagnostic.appliedTransition === 'string'
        ? JSON.parse(diagnostic.appliedTransition)
        : diagnostic.appliedTransition;
    const r = byID.get(witness.applicationID);
    assert(r, 'Sampled ACK absent from audit');
    assert.deepEqual(
      witness,
      Object.fromEntries(Object.entries(r).filter(([k]) => !auditOnly.has(k))),
      'Sample disagrees with audit',
    );
    assert.equal(diagnostic.policyAppliedRevision, r.revision, 'Sample revision disagrees');
    ordered(hostTime(sample.readStartedUptimeSeconds), hostTime(sample.readEndedUptimeSeconds));
    assert(time(r.ackAt) <= sample.readEndedUptimeSeconds, 'Sample predates ACK');
    observed.add(r.applicationID);
  }
  assert(observed.size > 0, 'No sampled ACK witness');
  const constraints = phase.exchanges?.filter((e) => e.operation === 'constrain');
  assert.equal(constraints?.length, 1, 'Expected one constrain request');
  const exchange = constraints[0];
  const start = hostTime(exchange.requestStartedUptimeSeconds),
    end = hostTime(exchange.responseEndedUptimeSeconds);
  ordered(start, end);
  assert.equal(exchange.response?.phase, 'constrained');
  assert.equal(exchange.response.sequence, exchange.sequence);
  assert.equal(exchange.response.rateBitsPerSecond, 750000);
  const descent = changes.find((c) => c.isDescent && c.nativeAt >= start);
  assert(descent, 'No completed descent after constrain request');
  const interval = (at) => [(at - end) * 1000, (at - start) * 1000];
  return {
    formatVersion: 1,
    traceValid: true,
    diagnosticOnly: true,
    mediaQualified: false,
    scope: audit.scope,
    attemptID: audit.attemptID,
    timingProfileID: timing.profileId,
    recordCount: audit.records.length,
    sampledApplications: observed.size,
    changes,
    firstDescent: {
      ...descent,
      clockBinding:
        'native-clock request/response interval; not packet arrival or server-clock synchronization',
      causeAfterConstrainRequestMs: interval(descent.causeAt),
      admissionAfterConstrainRequestMs: interval(descent.admittedAt),
      nativeCompletionAfterConstrainRequestMs: interval(descent.nativeAt),
      ackAfterConstrainRequestMs: interval(descent.ackAt),
    },
  };
}
