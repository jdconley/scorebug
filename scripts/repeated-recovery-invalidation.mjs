import assert from 'node:assert/strict';
import { qualifyCadenceAuditEnvelope } from './cadence-audit-envelope.mjs';

const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e12;
const uint = (n) => Number.isSafeInteger(n) && n >= 0;
const uuid = (s) =>
  typeof s === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(s);
const identifier = (s) => {
  assert(typeof s === 'string' && uuid(s.toLowerCase()), 'Invalid native identity');
  return s.toLowerCase();
};
// Only representation-scale outward rounding; no freshness/clock tolerance.
const rounding = (...values) => 4 * Number.EPSILON * Math.max(1, ...values.map(Math.abs));
function equalNumber(actual, expected, ...operands) {
  assert(finite(actual) && finite(expected));
  assert(
    Math.abs(actual - expected) <= rounding(actual, expected, ...operands),
    'Timing arithmetic mismatch',
  );
}
function keys(value, expected) {
  assert(value && typeof value === 'object' && !Array.isArray(value), 'Missing diagnostic object');
  assert.deepEqual(
    Object.keys(value).sort(),
    [...expected].sort(),
    'Unsupported rejection metadata',
  );
}
function ttl(row) {
  const server = Date.parse(row.response.serverTime),
    expires = Date.parse(row.response.status.expiresAt);
  assert(Number.isFinite(server) && Number.isFinite(expires));
  const value = Math.max(0, Math.min(5, (expires - server) / 1000));
  assert(value > 0, 'Expired cadence status');
  return value;
}
function cadenceWindow(window, duration, progress) {
  if (window == null) return;
  assert.equal(window.valid, true);
  assert(
    uint(window.sequence) &&
      window.sequence > 0 &&
      window.sequence <= Number.MAX_SAFE_INTEGER / duration,
  );
  assert.equal(window.durationMs, duration);
  assert(finite(window.ageMs));
  let total = 0;
  for (const key of ['freshFrames', 'duplicateFrames', 'reorderedFrames']) {
    assert(uint(window[key]));
    total += window[key];
    assert(uint(total));
  }
  if (window.freshFrames === 0) {
    assert.equal(window.firstPTS, null);
    assert.equal(window.lastPTS, null);
  } else {
    assert(uint(window.firstPTS) && uint(window.lastPTS));
    assert(
      window.freshFrames === 1
        ? window.firstPTS === window.lastPTS
        : window.firstPTS < window.lastPTS,
    );
    assert(window.lastPTS <= progress.lastFreshPTS);
  }
}
function reportEvidence(row, scope, { stale = false } = {}) {
  for (const key of [
    'receivedUptime',
    'evaluatedUptime',
    'requestSeconds',
    'residenceSeconds',
    'sampleAgeSeconds',
  ])
    assert(finite(row[key]), `Invalid report ${key}`);
  assert(row.evaluatedUptime >= row.receivedUptime);
  const elapsed = row.evaluatedUptime - row.receivedUptime;
  assert(
    row.residenceSeconds + rounding(row.evaluatedUptime, row.receivedUptime) >= elapsed,
    'Residence excludes audit uptime interval',
  );
  assert.equal(row.expectedAttempt, identifier(scope.publishingAttemptID));
  const status = row.response?.status,
    observation = status?.observation,
    publication = status?.publication;
  assert.equal(status?.state, 'producing_output');
  assert.equal(status.gameId, scope.matchID);
  assert.equal(status.generation, scope.broadcastGeneration);
  assert.equal(observation?.gameId, scope.matchID);
  assert.equal(observation.generation, scope.broadcastGeneration);
  assert.equal(observation.state, 'producing_output');
  assert(typeof status.workerId === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(status.workerId));
  assert(uuid(status.workerEpoch) && uint(observation.attempt) && observation.attempt > 0);
  for (const key of ['readerId', 'publisherId', 'publishingAttemptId'])
    assert(uuid(publication?.[key]));
  assert.notEqual(publication.readerId, publication.publisherId);
  assert.equal(publication.publishingAttemptId, row.expectedAttempt);
  assert.equal(publication.clock?.convention, 'mpegts-ingress-origin-90k-v1');
  assert(
    typeof publication.clock.originPTS === 'string' &&
      /^(0|[1-9][0-9]*)$/.test(publication.clock.originPTS),
  );
  assert(BigInt(publication.clock.originPTS) < 1n << 33n);
  assert.equal(observation.decodedVideo?.clock, 'mpegts-pts-90k-v1');
  const cadence = observation.decoderCadence,
    progress = cadence?.progress;
  assert.equal(cadence?.formatVersion, 1);
  assert.equal(cadence.ended, false);
  assert.equal(cadence.invalidReason, null);
  assert(uuid(cadence.scopeID));
  assert(
    uint(progress?.lastFreshPTS) && finite(progress.ageMs) && progress.ageMs < 1000,
    'Non-benign cadence progress',
  );
  assert.equal(progress.stalled, false);
  cadenceWindow(cadence.oneSecond, 1000, progress);
  cadenceWindow(cadence.twoSeconds, 2000, progress);
  if (cadence.twoSeconds != null) {
    const one = cadence.oneSecond,
      two = cadence.twoSeconds;
    assert(one && (one.sequence === two.sequence * 2 || one.sequence === two.sequence * 2 + 1));
    assert(Math.abs(one.sequence * 1000 + one.ageMs - (two.sequence * 2000 + two.ageMs)) <= 0.001);
  } else if (cadence.oneSecond != null) assert.equal(cadence.oneSecond.sequence, 1);
  assert(uint(status.decoderCadenceAgeUpperBoundMs));
  const serverAge = status.decoderCadenceAgeUpperBoundMs / 1000;
  const rawAge = serverAge + row.requestSeconds + row.residenceSeconds;
  equalNumber(row.sampleAgeSeconds, rawAge);
  assert(stale ? rawAge > 0.25 : rawAge <= 0.25, 'Raw cadence freshness mismatch');
  assert.equal(row.observedStall, stale ? null : false);
  assert(row.requestSeconds + row.residenceSeconds < ttl(row), 'Expired audited cadence');
  return {
    serverAge,
    progress,
    owner: {
      workerID: status.workerId,
      workerEpoch: status.workerEpoch,
      workerAttempt: observation.attempt,
      publication,
      decoderScopeID: cadence.scopeID,
    },
  };
}
function validateTiming(row, trace, session, serverAge) {
  const timing = row.timing;
  const stages = [
    'controlStartedUptime',
    'statusRequestStartedUptime',
    'responseReceivedUptime',
    'probeReadStartedUptime',
    'probeReadFinishedUptime',
    'auditEvaluatedUptime',
  ];
  const durations = [
    'maintenanceSeconds',
    'statusHTTPSeconds',
    'responseProcessingSeconds',
    'nativeProbeSeconds',
    'postProbeProcessingSeconds',
  ];
  keys(timing, [...stages, ...durations]);
  const values = stages.map((key) => timing[key]);
  assert(values.every(finite));
  for (let i = 1; i < values.length; i++) {
    assert(values[i] >= values[i - 1], 'Reversed audit timing stage');
    equalNumber(timing[durations[i - 1]], values[i] - values[i - 1], values[i], values[i - 1]);
  }
  assert.equal(timing.responseReceivedUptime, row.receivedUptime);
  assert.equal(timing.auditEvaluatedUptime, row.evaluatedUptime);
  const Q = timing.statusRequestStartedUptime,
    R = row.receivedUptime;
  const D = row.requestSeconds,
    E = session.evaluatedAt,
    C = trace.caughtAt;
  assert(D <= R - Q + rounding(Q, R, D), 'Request duration escapes uptime bracket');
  assert(
    row.residenceSeconds <= trace.selectedAt - Q - D + rounding(trace.selectedAt, Q, D),
    'Residence exceeds selection bracket',
  );
  assert(C - Q < ttl(row), 'Status expired by catch');
  const lower = serverAge + D + E - R,
    upper = serverAge + C - Q;
  const tolerance = rounding(serverAge, D, E, R, C, Q);
  assert(finite(session.sampleAgeSeconds) && lower <= upper + tolerance);
  assert(
    session.sampleAgeSeconds > 0.25,
    'Fresh diagnostic cannot explain cadence-freshness rejection',
  );
  // Audit's ContinuousClock sample precedes MainActor selection; session's
  // ContinuousClock sample follows E. The same helper must age by at least
  // this intervening uptime interval, independent of the wider clock bracket.
  const elapsedLower = row.sampleAgeSeconds + (E - trace.selectedAt);
  assert(
    session.sampleAgeSeconds +
      rounding(session.sampleAgeSeconds, row.sampleAgeSeconds, E, trace.selectedAt) >=
      elapsedLower,
    'Diagnostic sample age excludes elapsed time after selection',
  );
  assert(
    session.sampleAgeSeconds >= lower - tolerance && session.sampleAgeSeconds <= upper + tolerance,
    'Diagnostic sample age outside independent bracket',
  );
}
function matchSource(source, owner, scope) {
  assert(source, 'Missing source ownership evidence');
  assert.equal(identifier(source.attemptID), identifier(scope.publishingAttemptID));
  for (const key of ['workerID', 'workerEpoch', 'workerAttempt'])
    assert.equal(source[key], owner[key], 'Source owner mismatch');
  assert.equal(source.readerID, owner.publication.readerId, 'Source reader mismatch');
}

/** Prove only explicit raw stale-receipt invalidations in minimum recovery.
 * Original indices are retained. No window, duration, health or authority is
 * awarded here; policy integration must independently clear/rebuild recovery. */
export function qualifyRepeatedRecoveryInvalidations({ quality, cadenceReports, scope }) {
  const reports = qualifyCadenceAuditEnvelope(cadenceReports, { cadenceAuditMode: 'repeated' });
  assert.equal(quality?.formatVersion, 4);
  assert.equal(quality.overflow, false);
  for (const flag of [
    'decoderStallEnabled',
    'measuredSourceEvaluationEnabled',
    'deadlineFailuresEnabled',
  ])
    assert.equal(quality[flag], true);
  const events = quality.events;
  assert(Array.isArray(events) && events.length >= 2 && events.length <= 512);
  assert.equal(events[0].kind, 'bootstrap');
  assert.equal(events.at(-1).kind, 'stopped');
  assert.equal(events.at(-1).closed, true);
  identifier(scope.publishingAttemptID);
  const receiptIndexes = new Map();
  let lastReportAt = -1;
  for (const [index, row] of reports.entries()) {
    assert(
      finite(row.evaluatedUptime) && row.evaluatedUptime > lastReportAt,
      'Report time reversal',
    );
    lastReportAt = row.evaluatedUptime;
    if (row.cadenceReceiptID != null) {
      assert(uuid(row.cadenceReceiptID), 'Noncanonical cadence receipt');
      const indexes = receiptIndexes.get(row.cadenceReceiptID) ?? [];
      indexes.push(index);
      receiptIndexes.set(row.cadenceReceiptID, indexes);
    }
  }
  const result = [],
    used = new Set();
  let current,
    lastAt = -1,
    previousCaughtAt = 0,
    evaluationFloor = 0;
  for (const [eventIndex, event] of events.entries()) {
    assert(finite(event.at) && event.at >= lastAt, 'Event time reversal');
    lastAt = event.at;
    if (event.kind === 'applied') current = event;
    if (event.kind !== 'rejected') {
      if (finite(event.evaluatedAt)) evaluationFloor = Math.max(evaluationFloor, event.evaluatedAt);
      if (event.kind === 'applied' && finite(event.acknowledgedAt))
        evaluationFloor = Math.max(evaluationFloor, event.acknowledgedAt);
      continue;
    }
    keys(event, [
      'kind',
      'reason',
      'at',
      'closed',
      'revision',
      'profileID',
      'receipt',
      'application',
      'profileReceipt',
      'acknowledgedAt',
      'evaluationDiagnostic',
    ]);
    assert.equal(event.reason, 'cadence-freshness');
    assert.equal(event.closed, false);
    assert(
      current && ['2', '4'].includes(current.revision),
      'Rejection outside acknowledged minimum recovery',
    );
    assert.equal(current.closed, false);
    assert.equal(current.action?.kind, 'reset');
    assert.equal(current.action.fromRevision, String(Number(current.revision) - 1));
    assert.equal(current.application.fromRevision, current.action.fromRevision);
    assert.equal(current.profileID, '240p30');
    assert.equal(current.receipt.bitRate, 350000);
    assert.equal(current.application.candidateID, null);
    assert.equal(identifier(current.application.attemptID), identifier(scope.publishingAttemptID));
    for (const key of [
      'revision',
      'profileID',
      'receipt',
      'application',
      'profileReceipt',
      'acknowledgedAt',
    ])
      assert.deepEqual(event[key], current[key], 'Rejected input changed current reset ownership');
    const trace = event.evaluationDiagnostic,
      session = trace?.session;
    keys(trace, ['selectedAt', 'dispatchedAt', 'caughtAt', 'session']);
    keys(session, [
      'kind',
      'cadenceReceiptID',
      'evaluatedAt',
      'sampleAgeSeconds',
      'sourceAgeSeconds',
      'sourceKey',
    ]);
    assert.equal(session.kind, 'cadence');
    assert.equal(session.sourceKey, null);
    assert.equal(session.sourceAgeSeconds, null);
    const receiptID = session.cadenceReceiptID;
    assert(uuid(receiptID) && !used.has(receiptID), 'Duplicate or invalid rejection receipt');
    used.add(receiptID);
    const matches = receiptIndexes.get(receiptID);
    assert.equal(matches?.length, 1, 'Rejection must join one original cadence receipt');
    const reportIndex = matches[0],
      report = reports[reportIndex],
      before = reports[reportIndex - 1],
      after = reports[reportIndex + 1];
    assert(before && after, 'Missing adjacent cadence evidence');
    const times = [
      report.evaluatedUptime,
      trace.selectedAt,
      trace.dispatchedAt,
      session.evaluatedAt,
      trace.caughtAt,
      event.at,
    ];
    assert(times.every(finite));
    for (let i = 1; i < times.length; i++)
      assert(times[i] >= times[i - 1], 'Reversed rejection timing');
    // Helper assignment and audit recording finish synchronously on MainActor,
    // as does the provider read following selectedAt. A later report may have
    // arrived earlier while awaiting its native join, but cannot be audited yet.
    assert(
      trace.selectedAt < after.evaluatedUptime,
      'Selected cadence receipt was superseded before selection',
    );
    // The driver owns one serial in-flight cycle. A later selection cannot
    // precede completion of the preceding rejected invocation's catch boundary.
    assert(previousCaughtAt <= trace.selectedAt, 'Rejected invocation overlaps previous catch');
    previousCaughtAt = trace.caughtAt;
    assert(finite(current.acknowledgedAt) && current.acknowledgedAt <= trace.selectedAt);
    assert(session.evaluatedAt >= evaluationFloor, 'Rejection evaluator clock reversal');
    evaluationFloor = session.evaluatedAt;
    assert(
      report.evaluatedUptime - before.evaluatedUptime <= 0.5 &&
        after.evaluatedUptime - report.evaluatedUptime <= 0.5,
      'Missing adjacent fresh cadence coverage',
    );
    const prior = reportEvidence(before, scope),
      stale = reportEvidence(report, scope, { stale: true }),
      next = reportEvidence(after, scope);
    assert.deepEqual(stale.owner, prior.owner, 'Previous cadence owner mismatch');
    assert.deepEqual(stale.owner, next.owner, 'Next cadence owner mismatch');
    assert(
      prior.progress.lastFreshPTS < stale.progress.lastFreshPTS,
      'Stale report did not advance PTS',
    );
    assert(next.progress.lastFreshPTS >= stale.progress.lastFreshPTS, 'Following PTS regressed');
    const priorSource = events.slice(0, eventIndex).findLast((e) => e.source)?.source;
    const nextSource = events.slice(eventIndex + 1).find((e) => e.source)?.source;
    matchSource(priorSource, stale.owner, scope);
    matchSource(nextSource, stale.owner, scope);
    validateTiming(report, trace, session, stale.serverAge);
    result.push({
      eventIndex,
      reportIndex,
      receiptID,
      revision: event.revision,
      evaluatedAt: session.evaluatedAt,
      caughtAt: trace.caughtAt,
      nextReportIndex: reportIndex + 1,
      availableAt: after.evaluatedUptime,
    });
  }
  return result;
}
