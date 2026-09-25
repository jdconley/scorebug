import assert from 'node:assert/strict';

export const ownedMeasurementLifecycleArtifact = [
  'owned-measurement-lifecycle.json',
  8 * 1024 * 1024,
];
const settlements = new Set([
  'settledFailure',
  'settledApplicationRejection',
  'retiredObsolete',
  'settledAcknowledged',
]);
const kinds = new Set([
  'registered',
  'contextRequested',
  'contextCaptured',
  'allocationRequested',
  'allocationRejected',
  'allocated',
  'renewalRequested',
  'renewalRejected',
  'renewed',
  'retirementRequested',
  'retired',
  'candidateBound',
  'candidateStartRequested',
  'candidateStarted',
  'candidateJoined',
  'candidateRetired',
  'failed',
  'cleanupFailed',
  'cleanupJoined',
  'applicationTransferred',
  'applicationRejected',
  'policyState',
  'acknowledged',
  ...settlements,
]);
const check = (condition, message) => assert.ok(condition, `Owned measurement history: ${message}`);
const clock = (value) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12;
const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value);
const uint = (value) =>
  typeof value === 'string' &&
  /^(0|[1-9][0-9]{0,19})$/.test(value) &&
  BigInt(value) <= 18446744073709551615n;

/** Index the original, bounded event stream without filtering or rebasing it.
 * This checks the envelope and Session-owner sequencing only. It does not
 * validate native snapshots, candidate costs, health holds, application receipts,
 * or media, and grants no retry/capacity/upgrade permission. The complete replay
 * must independently consume every indexed event and cross-check those inputs.
 */
export function indexOwnedMeasurementHistory(raw, options = {}) {
  check(options && typeof options === 'object' && !Array.isArray(options), 'invalid options');
  check(
    Reflect.ownKeys(options).every((key) => key === 'scope'),
    'unknown option',
  );
  check(raw && typeof raw === 'object' && !Array.isArray(raw), 'missing audit');
  check(raw.formatVersion === 1, 'requires explicit format 1');
  check(raw.isClosed === true && raw.overflow === false, 'requires closed complete audit');
  check(raw.maximumAttempts === 16 && raw.maximumEvents === 4096, 'changed evidence bounds');
  check(clock(raw.closedAt), 'invalid close time');
  check(options.scope && uuid(options.scope.publishingAttemptID), 'missing expected publication');
  assert.deepEqual(raw.scope, options.scope, 'Owned measurement history: scope mismatch');
  check(
    Array.isArray(raw.events) && raw.events.length > 0 && raw.events.length <= 4096,
    'event count outside bounds',
  );
  const attempts = [],
    owners = new Set();
  let previousAt = -1,
    current;
  for (const [index, event] of raw.events.entries()) {
    check(event && typeof event === 'object' && !Array.isArray(event), 'invalid event');
    check(event.ordinal === String(index + 1), 'missing, reordered or noncanonical event ordinal');
    check(
      clock(event.at) && event.at >= previousAt && event.at <= raw.closedAt,
      'event clock outside history',
    );
    check(
      clock(event.coreRegisteredAt) && event.coreRegisteredAt <= event.at,
      'invalid registration time',
    );
    check(uint(event.appliedRevision) && uuid(event.ownerID), 'invalid owner identity');
    check(kinds.has(event.kind), 'unknown event kind');
    check(event.kind !== 'cleanupFailed', 'cleanup did not join');
    const ownerID = event.ownerID.toLowerCase();
    if (event.kind === 'registered') {
      check(!current || current.terminal, 'new registration before prior settlement');
      check(!owners.has(ownerID), 'reused Session owner');
      check(attempts.length < 16, 'attempt budget exhausted');
      // Registration itself must happen after the previous settlement. An event
      // with a new timestamp cannot re-label an old Core registration.
      check(event.coreRegisteredAt >= previousAt, 'registration overlaps previous owner');
      owners.add(ownerID);
      current = {
        ownerID,
        coreRegisteredAt: event.coreRegisteredAt,
        appliedRevision: event.appliedRevision,
        eventIndices: [],
        registeredEventIndex: index,
        cleanupEventIndex: null,
        settlementEventIndex: null,
        terminal: null,
      };
      attempts.push(current);
    } else {
      // Session publishes its changed policy after recording exact settlement.
      // That read-only observation retains ownership; it cannot reopen work.
      check(current && (!current.terminal || event.kind === 'policyState'), 'event outside active Session owner');
      check(
        ownerID === current.ownerID &&
          event.coreRegisteredAt === current.coreRegisteredAt &&
          event.appliedRevision === current.appliedRevision,
        'changed registered ownership',
      );
    }
    if (event.kind === 'cleanupJoined') {
      check(current.cleanupEventIndex === null, 'duplicate cleanup join');
      current.cleanupEventIndex = index;
    } else if (settlements.has(event.kind)) {
      check(current.cleanupEventIndex !== null, 'settlement before cleanup join');
      current.settlementEventIndex = index;
      current.terminal = event.kind;
    } else {
      check(
        current.cleanupEventIndex === null ||
          ['acknowledged', 'applicationTransferred', 'applicationRejected', 'policyState'].includes(event.kind),
        'new measurement work after cleanup join',
      );
    }
    current.eventIndices.push(index);
    previousAt = event.at;
  }
  // Session stop discards its private policy after joining native work. It need
  // not fabricate a failure settlement for that final, never-reused owner.
  if (!current.terminal) {
    check(current.cleanupEventIndex !== null, 'final owner did not join before stop');
    current.terminal = 'stopped';
  }
  return {
    eventCount: raw.events.length,
    closedAt: raw.closedAt,
    attempts,
    nativeProbeQualified: false,
    retryPolicyQualified: false,
    mediaQualified: false,
  };
}
