import assert from 'node:assert/strict';

const check = (condition, message) => assert.ok(condition, `Measured probe retirement: ${message}`);
const time = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value);
const sameID = (a, b) => uuid(a) && uuid(b) && a.toLowerCase() === b.toLowerCase();
const count = (value) => {
  check(typeof value === 'string' && /^(0|[1-9][0-9]{0,7})$/.test(value), 'invalid counter');
  const n = BigInt(value);
  check(n <= 16n * 1024n * 1024n && n % 1316n === 0n, 'counter outside aligned budget');
  return n;
};
const observationKeys = [
  'acceptedPayloadBytes',
  'bitRate',
  'id',
  'lastAcceptedAt',
  'leaseDeadline',
  'publishingGeneration',
  'reason',
  'stage',
  'startedAt',
];
function sameObservation(a, b) {
  for (const key of observationKeys)
    check(
      key === 'id' ? sameID(a?.[key], b?.[key]) : a?.[key] === b?.[key],
      `probe ${key} mismatch`,
    );
}

/** Correlates profile cancellation with raw lifecycle/quality ownership. The caller
 * still validates every native campaign snapshot and independently qualifies the
 * complete lifecycle, candidate admission, and measured policy. No raw event is
 * created here; terminal read provenance remains separate from probe events. */
export function qualifyMeasuredProbeRetirement(proof, { lifecycle, quality } = {}) {
  check(proof.result === 'operationFailed', 'requires raw operationFailed result');
  check(
    lifecycle?.formatVersion === 1 &&
      lifecycle.isClosed === true &&
      lifecycle.invalid === false &&
      lifecycle.overflow === false,
    'invalid lifecycle',
  );
  assert.deepEqual(
    lifecycle.scope,
    proof.scope,
    'Measured probe retirement: lifecycle scope mismatch',
  );
  check(
    Array.isArray(lifecycle.profileRequests) && lifecycle.profileRequests.length === 1,
    'requires exactly one profile request',
  );
  check(
    quality?.formatVersion === 4 &&
      quality.overflow === false &&
      quality.measuredSourceEvaluationEnabled === true,
    'invalid measured quality context',
  );
  check(
    Array.isArray(quality.events) && quality.events.length > 0 && quality.events.length <= 512,
    'quality events outside bounds',
  );
  const candidates = quality.events.filter((e) => e.kind === 'candidate');
  const applications = quality.events.filter((e) => e.kind === 'applied');
  check(
    candidates.length === 1 && applications.length === 1,
    'requires one owned trial and application',
  );
  const trial = candidates[0],
    applied = applications[0],
    request = lifecycle.profileRequests[0];
  const action = trial.action,
    application = trial.application,
    candidate = trial.candidate;
  check(
    action?.kind === 'trial' &&
      trial.closed === false &&
      applied.closed === false &&
      uuid(application?.id),
    'missing open owned trial',
  );
  check(
    sameID(candidate?.id, request.candidateMeasurementID) &&
      sameID(action.candidateID, candidate.id) &&
      sameID(application.candidateID, candidate.id),
    'candidate ownership mismatch',
  );
  check(
    sameID(application.attemptID, proof.scope.publishingAttemptID) &&
      sameID(candidate.attemptID, application.attemptID),
    'attempt ownership mismatch',
  );
  check(
    action.fromRevision === application.fromRevision &&
      candidate.appliedRevision === application.fromRevision &&
      /^[0-9]+$/.test(application.fromRevision),
    'revision ownership mismatch',
  );
  check(
    trial.revision === String(BigInt(application.fromRevision) + 1n) &&
      applied.revision === trial.revision,
    'applied revision mismatch',
  );
  check(
    action.profileID === candidate.profileID &&
      action.profileID === request.targetProfile &&
      trial.profileID === action.profileID &&
      applied.profileID === action.profileID,
    'target profile mismatch',
  );
  assert.deepEqual(
    applied.application,
    application,
    'Measured probe retirement: application mismatch',
  );
  assert.deepEqual(applied.action, action, 'Measured probe retirement: trial action mismatch');
  check(
    uuid(request.requestID) &&
      request.authorityPermitted === true &&
      request.probeAuthorityPermitted === true &&
      request.currentProbeActive === true &&
      request.outcome === 'completed' &&
      request.failure === null,
    'profile request lacks pre-authority or completion',
  );
  const terminal = request.terminalProbeRead,
    current = request.currentProbe,
    binding = request.probeBinding;
  check(
    terminal && current && binding?.observation && request.receipt,
    'missing native observations',
  );
  for (const value of [
    application.admittedAt,
    application.completionDeadline,
    action.validUntil,
    trial.evaluatedAt,
    trial.at,
    applied.at,
    trial.acknowledgedAt,
    applied.acknowledgedAt,
    request.requestedAt,
    request.completedAt,
    request.receipt.acknowledgedAt,
    terminal.startedAt,
    terminal.completedAt,
    lifecycle.closedAt,
    binding.boundAt,
    binding.candidateCompletedAt,
    candidate.measuredStart,
    candidate.measuredEnd,
    candidate.evaluatedAt,
    candidate.validUntil,
  ])
    check(time(value), 'invalid chronology time');
  check(
    Math.abs(application.completionDeadline - application.admittedAt - 2) < 1e-6,
    'application deadline must be two seconds',
  );
  check(
    binding.boundAt <= candidate.measuredStart &&
      candidate.measuredStart < candidate.measuredEnd &&
      candidate.measuredEnd <= binding.candidateCompletedAt &&
      binding.candidateCompletedAt <= candidate.evaluatedAt &&
      candidate.evaluatedAt <= trial.evaluatedAt &&
      trial.evaluatedAt <= application.admittedAt &&
      application.admittedAt <= request.requestedAt &&
      request.requestedAt < action.validUntil &&
      action.validUntil <= candidate.validUntil,
    'request outside owned trial bounds',
  );
  check(
    request.requestedAt - candidate.evaluatedAt <= 0.25,
    'current pre-authority snapshot is stale',
  );
  check(
    request.requestedAt <= request.receipt.acknowledgedAt &&
      request.receipt.acknowledgedAt <= request.completedAt &&
      request.completedAt <= terminal.startedAt &&
      terminal.startedAt <= terminal.completedAt &&
      terminal.completedAt <= application.completionDeadline &&
      terminal.completedAt <= lifecycle.closedAt,
    'terminal read outside request/deadline bracket',
  );
  check(
    request.receipt.acknowledgedAt <= trial.acknowledgedAt &&
      trial.acknowledgedAt === applied.acknowledgedAt &&
      trial.acknowledgedAt <= application.completionDeadline &&
      trial.at >= terminal.completedAt &&
      applied.at >= terminal.completedAt &&
      trial.at >= trial.acknowledgedAt &&
      applied.at >= applied.acknowledgedAt,
    'quality acknowledgment chronology mismatch',
  );
  check(
    request.receipt.profile === action.profileID &&
      request.receipt.publishingGeneration === proof.publishingGeneration,
    'profile receipt target mismatch',
  );
  assert.deepEqual(
    trial.profileReceipt,
    request.receipt,
    'Measured probe retirement: trial receipt mismatch',
  );
  assert.deepEqual(
    applied.profileReceipt,
    request.receipt,
    'Measured probe retirement: applied receipt mismatch',
  );
  const final = proof.events.at(-1),
    previous = proof.events.at(-2);
  check(
    final?.phase === 'final' &&
      previous?.phase === 'renewed' &&
      previous.sample.stage === 3 &&
      previous.observedAt <= request.requestedAt &&
      terminal.completedAt <= final.observedAt,
    'terminal evidence does not bracket native final',
  );
  sameObservation(terminal.observation, final.sample);
  check(terminal.observation.reason === 'cancelled', 'terminal probe was not profile-cancelled');
  for (const key of ['id', 'stage', 'bitRate', 'publishingGeneration', 'startedAt']) {
    for (const value of [current, binding.observation])
      check(
        key === 'id' ? sameID(value[key], final.sample[key]) : value[key] === final.sample[key],
        `active probe ${key} mismatch`,
      );
  }
  check(
    current.reason === null &&
      binding.observation.reason === null &&
      current.stage === 3 &&
      current.bitRate === 12_000_000,
    'probe is not active candidate stage',
  );
  check(
    current.leaseDeadline === previous.sample.leaseDeadline &&
      current.leaseDeadline === final.sample.leaseDeadline &&
      request.requestedAt < current.leaseDeadline &&
      candidate.validUntil <= current.leaseDeadline,
    'request lacks current unchanged lease',
  );
  check(
    proof.events.some(
      (e) => e.sample.stage === 3 && e.sample.leaseDeadline === binding.observation.leaseDeadline,
    ),
    'binding lease missing from raw campaign',
  );
  check(
    binding.boundAt < binding.observation.leaseDeadline &&
      binding.observation.leaseDeadline <= current.leaseDeadline,
    'binding outside active lease',
  );
  const admission = trial.candidateAdmission;
  check(admission, 'missing raw admission witness');
  sameObservation(admission.probe, current);
  sameObservation(admission.binding, binding.observation);
  check(
    admission.boundAt === binding.boundAt &&
      admission.completedAt === binding.candidateCompletedAt &&
      sameID(admission.measurement?.id, candidate.id),
    'admission binding mismatch',
  );
  // Intermediate active observations must agree with every raw snapshot and
  // obey the same accounted token budgets; they are never capacity evidence.
  for (const [value, at] of [
    [binding.observation, binding.boundAt],
    [current, candidate.evaluatedAt],
  ]) {
    const n = count(value.acceptedPayloadBytes);
    check(
      time(value.lastAcceptedAt) &&
        value.startedAt <= value.lastAcceptedAt &&
        value.lastAcceptedAt <= at &&
        value.lastAcceptedAt < value.leaseDeadline &&
        value.leaseDeadline - 0.3 <= at + 1e-6,
      'active observation timestamp outside lease',
    );
    check(
      Number(n / 1316n) * 10880 <= (value.lastAcceptedAt - value.startedAt) * value.bitRate + 1,
      'active observation exceeds paced budget',
    );
    for (const event of proof.events.filter((e) => e.sample.stage === 3)) {
      const sample = event.sample,
        other = count(sample.acceptedPayloadBytes);
      if (sample.lastAcceptedAt === value.lastAcceptedAt)
        check(other === n, 'active counter timestamp mismatch');
      else if (sample.lastAcceptedAt === null || sample.lastAcceptedAt < value.lastAcceptedAt)
        check(other <= n, 'active counter regression');
      else check(other >= n, 'active counter ahead of final');
      if (event.observedAt <= at) {
        check(sample.reason === null && other <= n, 'active observation follows withdrawal');
        const checkpoint = Math.max(
          sample.leaseDeadline - 0.3,
          sample.lastAcceptedAt ?? sample.startedAt,
        );
        check(
          value.lastAcceptedAt >= checkpoint &&
            Number((n - other) / 1316n) * 10880 <=
              (value.lastAcceptedAt - checkpoint) * value.bitRate + 10881,
          'active observation exceeds token budget',
        );
      }
    }
  }
  check(
    current.lastAcceptedAt <= request.requestedAt &&
      final.sample.lastAcceptedAt <= terminal.startedAt &&
      final.sample.lastAcceptedAt < current.leaseDeadline,
    'acceptance outside terminal read or lease',
  );
  return {
    retirementKind: 'profile-request-terminal-read',
    profileRequestID: request.requestID,
    retirementRequestedAt: request.requestedAt,
    retiredObservedAt: terminal.completedAt,
  };
}
