import { qualifyCadenceAuditEnvelope } from './cadence-audit-envelope.mjs';
import assert from 'node:assert/strict';
const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0;
export function nativeCadenceReports({
  environment,
  streaming,
  requirePublication,
  requireProcessing,
  holdSeconds,
}) {
  const flag = environment.SCOREBUG_TEST_CADENCE_REPORTS;
  if (flag === undefined) return false;
  assert(
    flag === '1' &&
      streaming &&
      requirePublication &&
      requireProcessing &&
      Number.isInteger(holdSeconds) &&
      holdSeconds >= 90 &&
      holdSeconds <= 120,
    'Cadence reports require explicit streaming/publication/processing and 90–120 seconds',
  );
  assert(
    environment.SCOREBUG_TEST_LIVE_PROFILE === '240p30' &&
      environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16' &&
      environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1',
    'Cadence reports require fixed240 structured motion/direct recording',
  );
  for (const key of [
    'SCOREBUG_TEST_NATIVE_QUALITY',
    'SCOREBUG_TEST_PROFILE_TRANSITIONS',
    'SCOREBUG_TEST_ADAPTIVE_PROFILES',
    'SCOREBUG_TEST_BANDWIDTH_PROBE',
    'SCOREBUG_TEST_UPLINK_PROFILE',
  ])
    assert(!environment[key], `Cadence reports cannot combine ${key}`);
  return true;
}
/** Reconcile historical native helper execution. This is reporting freshness,
 * not source-frame health, capacity, or a measured stall-to-reset latency. */
export function qualifyNativeCadenceReports({ audit, scope, cadenceAuditMode = 'legacy' }) {
  qualifyCadenceAuditEnvelope(audit, { cadenceAuditMode });
  let previous = -1,
    firstUsable,
    known = 0;
  for (const row of audit.rows) {
    for (const key of ['receivedUptime', 'evaluatedUptime', 'requestSeconds', 'residenceSeconds'])
      assert(finite(row[key]), `Invalid ${key}`);
    assert(
      row.evaluatedUptime >= row.receivedUptime && row.evaluatedUptime >= previous,
      'Clock reversal',
    );
    previous = row.evaluatedUptime;
    assert.equal(
      row.expectedAttempt,
      scope.publishingAttemptID.toLowerCase(),
      'Wrong expected attempt',
    );
    const status = row.response.status;
    assert.equal(status.gameId, scope.matchID);
    assert.equal(status.generation, scope.broadcastGeneration);
    if (row.sampleAgeSeconds === null) {
      assert.equal(row.observedStall, null);
      continue;
    }
    assert(finite(row.sampleAgeSeconds), 'Invalid helper age');
    assert.equal(status.state, 'producing_output');
    assert.equal(status.publication?.publishingAttemptId, row.expectedAttempt, 'Wrong publication');
    assert.equal(status.observation?.gameId, scope.matchID);
    assert.equal(status.observation?.generation, scope.broadcastGeneration);
    const cadence = status.observation.decoderCadence;
    assert(
      cadence?.formatVersion === 1 &&
        cadence.ended === false &&
        cadence.invalidReason === null &&
        cadence.progress,
      'Invalid cadence',
    );
    assert(
      finite(cadence.progress.ageMs) &&
        Number.isSafeInteger(cadence.progress.lastFreshPTS) &&
        cadence.progress.lastFreshPTS >= 0,
      'Invalid progress',
    );
    assert.equal(cadence.progress.stalled, cadence.progress.ageMs >= 1000);
    assert(
      Number.isSafeInteger(status.decoderCadenceAgeUpperBoundMs) &&
        status.decoderCadenceAgeUpperBoundMs >= 0,
      'Missing server bound',
    );
    const expected =
      status.decoderCadenceAgeUpperBoundMs / 1000 + row.requestSeconds + row.residenceSeconds;
    assert(Math.abs(row.sampleAgeSeconds - expected) < 1e-8, 'Helper bound does not reconcile');
    assert.equal(
      row.observedStall,
      expected <= 0.25 ? cadence.progress.stalled : null,
      'Observed stall differs from fresh worker evidence',
    );
    known++;
    firstUsable ??= row.evaluatedUptime;
  }
  assert(known > 0, 'No native helper evidence');
  const start = firstUsable + 5,
    end = audit.rows.at(-1).evaluatedUptime;
  assert(end - start >= 30, 'Insufficient settled coverage');
  const rows = audit.rows.filter((r) => r.evaluatedUptime >= start);
  const fresh = rows.filter((r) => r.sampleAgeSeconds !== null && r.sampleAgeSeconds <= 0.25);
  const fraction = fresh.length / rows.length;
  assert(fraction >= 0.95, 'Fewer than 95% of settled reports fit the freshness budget');
  let last = start,
    maximumGap = 0;
  for (const r of fresh) {
    maximumGap = Math.max(maximumGap, r.evaluatedUptime - last);
    last = r.evaluatedUptime;
  }
  maximumGap = Math.max(maximumGap, end - last);
  assert(maximumGap <= 0.5, 'Gap between usable reports exceeds 500 ms');
  const ages = rows
    .map((r) => r.sampleAgeSeconds)
    .filter(finite)
    .sort((a, b) => a - b);
  return {
    reportCount: audit.rows.length,
    knownHelperCount: known,
    settledReportCount: rows.length,
    settledCoverageSeconds: end - start,
    withinBudgetFraction: fraction,
    maximumUsableGapSeconds: maximumGap,
    minimumAgeSeconds: ages[0],
    p95AgeSeconds: ages[Math.ceil(ages.length * 0.95) - 1],
    maximumAgeSeconds: ages.at(-1),
    reportingFreshnessQualified: true,
    controlledStallResponseQualified: false,
  };
}
