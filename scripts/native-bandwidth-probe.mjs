import assert from 'node:assert/strict';
import { qualifyMeasuredProbeRetirement } from './measured-probe-retirement.mjs';
import {
  nativeCandidateHeadroom,
  candidateHeadroomStageRates,
} from './native-candidate-headroom.mjs';

export function nativeBandwidthProbe({
  environment,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds,
  liveProfile,
}) {
  const combined = nativeCandidateHeadroom(environment);
  const mode = environment.SCOREBUG_TEST_BANDWIDTH_PROBE;
  if (mode === undefined) return null;
  assert.ok(
    ['renew', 'expire', 'staged'].includes(mode) &&
      streaming &&
      requireProcessing &&
      requirePublication &&
      Number.isSafeInteger(holdSeconds) &&
      holdSeconds >= 90 &&
      holdSeconds <= 600 &&
      liveProfile === (combined ? '240p30' : '540p30') &&
      environment.SCOREBUG_TEST_LIVE_PROFILE === liveProfile &&
      (combined || environment.SCOREBUG_TEST_CANDIDATE_PROFILE === undefined) &&
      environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16' &&
      environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1' &&
      [
        'SCOREBUG_TEST_NATIVE_QUALITY',
        'SCOREBUG_TEST_NATIVE_CONFIRMATION',
        'SCOREBUG_TEST_ADAPTIVE_PROFILES',
        'SCOREBUG_TEST_PROFILE_TRANSITIONS',
        'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
      ].every((key) => environment[key] === undefined),
    'Bandwidth probe requires exclusive fixed540p full-pipeline structured-motion qualification and bounded hold',
  );
  return mode;
}
const reasons = new Set([
  'leaseExpired',
  'timeLimit',
  'byteLimit',
  'invalidClock',
  'unavailableStatistics',
  'transportPressure',
  'transportBackpressure',
  'transportFailed',
  'cancelled',
  'finished',
  'closed',
  'replaced',
]);
const uuid = (value) =>
  typeof value === 'string' &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
function counter(value) {
  assert.ok(typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value), 'Malformed counter');
  const parsed = BigInt(value);
  assert.ok(parsed <= 18446744073709551615n);
  return parsed;
}
function time(value) {
  assert.ok(
    typeof value === 'number' && Number.isFinite(value) && value >= 0,
    'Invalid monotonic time',
  );
}

/** Validates local native acceptance/lease evidence, never receiver capacity. */
export function qualifyNativeBandwidthProbe(
  proof,
  { mode, scope, publishingGeneration, candidateHeadroom = false, measuredRetirement },
) {
  assert.equal(typeof candidateHeadroom, 'boolean');
  assert.ok(!candidateHeadroom || mode === 'staged');
  assert.ok(
    measuredRetirement === undefined || (mode === 'staged' && candidateHeadroom),
    'Measured retirement requires staged candidate headroom',
  );
  if (mode === 'staged')
    return qualifyStagedNativeBandwidthProbe(proof, {
      scope,
      publishingGeneration,
      candidateHeadroom,
      measuredRetirement,
    });
  assert.ok(['renew', 'expire'].includes(mode));
  assert.equal(proof.formatVersion, 1);
  assert.equal(proof.isClosed, true);
  assert.equal(proof.invalid, false);
  assert.equal(proof.mode, mode);
  assert.ok(['completed', 'withdrawn'].includes(proof.result));
  assert.deepEqual(proof.scope, scope);
  assert.ok(uuid(scope.publishingAttemptID));
  assert.equal(proof.publishingGeneration, publishingGeneration);
  assert.ok(counter(publishingGeneration) > 0n);
  assert.ok(Array.isArray(proof.events) && proof.events.length >= 2 && proof.events.length <= 602);
  let prior,
    priorTime = -1,
    first,
    accepted = 0n;
  for (const [index, event] of proof.events.entries()) {
    for (const key of ['stage', 'campaignStartedAt', 'totalAcceptedPayloadBytes'])
      assert.ok(!Object.hasOwn(event.sample, key), 'v1 probe cannot contain staged metadata');
    assert.equal(
      event.phase,
      index === 0
        ? 'began'
        : index === proof.events.length - 1
          ? 'final'
          : mode === 'renew'
            ? 'renewed'
            : 'observed',
    );
    const value = event.sample;
    time(event.observedAt);
    time(value.startedAt);
    time(value.leaseDeadline);
    assert.ok(event.observedAt >= priorTime && value.startedAt <= event.observedAt);
    assert.ok(uuid(value.id));
    assert.equal(value.publishingGeneration, publishingGeneration);
    assert.equal(value.bitRate, 1_000_000);
    assert.ok(
      value.leaseDeadline > value.startedAt && value.leaseDeadline <= value.startedAt + 60.3 + 1e-6,
    );
    const bytes = counter(value.acceptedPayloadBytes);
    assert.ok(bytes <= 16n * 1024n * 1024n && bytes % 1316n === 0n && bytes >= accepted);
    assert.equal(value.lastAcceptedAt === null, bytes === 0n);
    if (value.lastAcceptedAt !== null) {
      time(value.lastAcceptedAt);
      assert.ok(
        value.lastAcceptedAt >= value.startedAt &&
          value.lastAcceptedAt <= event.observedAt &&
          value.lastAcceptedAt <= value.leaseDeadline,
        'Future or late native acceptance',
      );
      // Seven TS packets plus the native probe's accounted transport overhead.
      assert.ok(
        Number(bytes / 1316n) * 1360 * 8 <=
          (value.lastAcceptedAt - value.startedAt) * value.bitRate + 1,
        'Acceptance exceeds paced accounting budget',
      );
    }
    assert.ok(value.reason === null || reasons.has(value.reason));
    if (value.reason === 'leaseExpired')
      assert.ok(event.observedAt >= value.leaseDeadline, 'Lease has not expired');
    if (prior) {
      assert.equal(value.id, first.id);
      assert.equal(value.startedAt, first.startedAt);
      assert.ok(value.leaseDeadline >= prior.leaseDeadline);
      if (value.leaseDeadline > prior.leaseDeadline) {
        assert.equal(event.phase, 'renewed', 'Only renewal may advance the lease');
        const renewedAt = value.leaseDeadline - 0.3;
        assert.ok(
          renewedAt <= event.observedAt + 1e-6 && renewedAt >= priorTime - 1e-6,
          'Renewal native instant is inconsistent with observations',
        );
        assert.ok(renewedAt < prior.leaseDeadline, 'Renewal cannot revive an expired lease');
      }
      if (mode === 'expire') assert.equal(value.leaseDeadline, first.leaseDeadline);
      if (prior.lastAcceptedAt !== null) assert.ok(value.lastAcceptedAt >= prior.lastAcceptedAt);
      if (prior.reason !== null) {
        assert.equal(value.reason, prior.reason);
        assert.equal(bytes, accepted);
      }
    } else {
      first = value;
      assert.ok(Math.abs(value.leaseDeadline - value.startedAt - 0.3) < 1e-6);
    }
    prior = value;
    priorTime = event.observedAt;
    accepted = bytes;
  }
  assert.ok(accepted > 0n, 'Probe did not produce native acceptance evidence');
  assert.notEqual(prior.reason, null, 'Final probe is still active');
  if (mode === 'expire') assert.equal(prior.reason, 'leaseExpired');
  if (proof.result === 'completed') assert.equal(prior.reason, 'cancelled');
  return {
    mode,
    id: first.id,
    publishingGeneration,
    acceptedPayloadBytes: Number(accepted),
    lastAcceptedAt: prior.lastAcceptedAt,
    reason: prior.reason,
    eventCount: proof.events.length,
    receiverCapacityQualified: false,
  };
}

function qualifyStagedNativeBandwidthProbe(
  proof,
  { scope, publishingGeneration, candidateHeadroom, measuredRetirement },
) {
  const check = (condition, message) => assert.ok(condition, `Staged probe: ${message}`);
  const finiteTime = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
  const bytes = (value) => {
    check(
      typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value),
      'malformed decimal counter',
    );
    const count = BigInt(value);
    check(
      count <= 16n * 1024n * 1024n && count % 1316n === 0n,
      'counter exceeds aligned campaign budget',
    );
    return count;
  };
  check(
    proof?.formatVersion === 2 && proof.mode === 'staged',
    'requires explicit version 2 and staged mode',
  );
  check(
    proof.isClosed === true &&
      proof.invalid === false &&
      (proof.result === 'completed' ||
        (measuredRetirement !== undefined && proof.result === 'operationFailed')),
    'requires closed completed valid proof',
  );
  assert.deepEqual(proof.scope, scope, 'Staged probe: publication scope mismatch');
  check(uuid(scope?.publishingAttemptID), 'invalid publication attempt UUID');
  check(
    typeof publishingGeneration === 'string' &&
      /^[1-9][0-9]*$/.test(publishingGeneration) &&
      BigInt(publishingGeneration) <= 18446744073709551615n &&
      proof.publishingGeneration === publishingGeneration,
    'invalid or mismatched publishing generation',
  );
  check(
    Array.isArray(proof.events) && proof.events.length >= 10 && proof.events.length <= 607,
    'event count outside bounds',
  );

  const retirement =
    measuredRetirement === undefined
      ? null
      : qualifyMeasuredProbeRetirement(proof, measuredRetirement);
  const stages = [];
  let cursor = 0,
    priorTime = -1,
    origin,
    cumulative = 0n,
    lastRetired;
  const rates = candidateHeadroom ? candidateHeadroomStageRates : [500_000, 1_000_000, 2_000_000];
  for (const [index, bitRate] of rates.entries()) {
    const stage = index + 1;
    const tokenCheckpoints = [];
    let first,
      prior,
      priorBytes = 0n,
      priorTotal = cumulative;
    // Check raw snapshots before deriving any stage summary. Native acceptance
    // is local evidence only; no receiver or capacity claim follows from it.
    const read = (phase) => {
      const event = proof.events[cursor++];
      check(
        event?.phase === phase && event.sample && typeof event.sample === 'object',
        `expected ${phase} for stage ${stage}`,
      );
      const value = event.sample;
      const terminalRead = phase === 'final' && retirement;
      const retired = phase === 'retired' || terminalRead;
      const observedAt = terminalRead ? retirement.retiredObservedAt : event.observedAt;
      check(
        finiteTime(event.observedAt) && observedAt >= priorTime && observedAt <= event.observedAt,
        'nonmonotonic observation',
      );
      check(
        value.stage === stage &&
          value.bitRate === bitRate &&
          value.publishingGeneration === publishingGeneration,
        'stage, offered rate, or generation mismatch',
      );
      check(uuid(value.id), 'malformed probe UUID');
      check(
        finiteTime(value.startedAt) &&
          value.startedAt <= observedAt &&
          finiteTime(value.campaignStartedAt),
        'invalid start or campaign time',
      );
      if (origin === undefined) origin = value.startedAt;
      check(
        value.campaignStartedAt === origin &&
          value.startedAt >= origin &&
          value.startedAt < origin + 60,
        'changed campaign origin or stage outside campaign',
      );
      check(
        finiteTime(value.leaseDeadline) &&
          value.leaseDeadline > value.startedAt &&
          value.leaseDeadline <= origin + 60.3 + 1e-6,
        'invalid lease deadline',
      );
      const accepted = bytes(value.acceptedPayloadBytes),
        total = bytes(value.totalAcceptedPayloadBytes);
      check(
        total >= accepted &&
          accepted >= priorBytes &&
          total >= priorTotal &&
          total - priorTotal === accepted - priorBytes,
        'inconsistent local and cumulative byte deltas',
      );
      check(
        (value.lastAcceptedAt === null) === (accepted === 0n),
        'acceptance timestamp and count disagree',
      );
      if (accepted > 0n) {
        check(
          finiteTime(value.lastAcceptedAt) &&
            value.lastAcceptedAt >= value.startedAt &&
            value.lastAcceptedAt <= observedAt &&
            value.lastAcceptedAt < value.leaseDeadline &&
            value.lastAcceptedAt < origin + 60,
          'acceptance outside observation, lease, or campaign',
        );
        // Native starts with zero tokens and accounts seven TS packets plus
        // transport overhead. Elapsed time cannot fund more than this amount.
        check(
          Number(accepted / 1316n) * 1360 * 8 <=
            (value.lastAcceptedAt - value.startedAt) * bitRate + 1,
          'acceptance exceeds paced accounting budget',
        );
      }
      check(
        value.reason === (retired ? 'cancelled' : null),
        'unexpected active or retirement reason',
      );
      if (phase === 'retired') {
        check(
          finiteTime(event.retirementRequestedAt) &&
            event.retirementRequestedAt >= priorTime &&
            event.retirementRequestedAt <= event.observedAt,
          'retirement request outside observation bracket',
        );
      } else
        check(
          !Object.hasOwn(event, 'retirementRequestedAt'),
          'retirement request on non-retirement event',
        );
      if (prior) {
        check(
          value.id.toLowerCase() === first.id.toLowerCase() && value.startedAt === first.startedAt,
          'changed current-stage identity',
        );
        if (accepted === priorBytes)
          check(
            value.lastAcceptedAt === prior.lastAcceptedAt,
            'changed timestamp without acceptance',
          );
        else {
          // Every earlier snapshot bounds its entire following window by one
          // token plus elapsed offered-rate credit. Keeping all checkpoints
          // prevents each observation from granting a fresh token allowance.
          // The proof's 607-event cap bounds this quadratic comparison.
          for (const checkpoint of tokenCheckpoints)
            check(
              value.lastAcceptedAt >= checkpoint.at &&
                Number((accepted - checkpoint.accepted) / 1316n) * 1360 * 8 <=
                  (value.lastAcceptedAt - checkpoint.at) * bitRate + 1360 * 8 + 1,
              'acceptance exceeds one-message token budget',
            );
        }
        if (phase === 'renewed') {
          const renewedAt = value.leaseDeadline - 0.3;
          check(
            value.leaseDeadline >= prior.leaseDeadline &&
              renewedAt >= priorTime - 1e-6 &&
              renewedAt <= event.observedAt + 1e-6 &&
              renewedAt < prior.leaseDeadline &&
              renewedAt < origin + 60,
            'renewal instant outside observations, old lease, or campaign',
          );
        } else check(value.leaseDeadline === prior.leaseDeadline, 'only renewal may change lease');
      } else {
        check(
          accepted === 0n && total === cumulative,
          'stage must start empty at exact prior retired total',
        );
        check(
          Math.abs(value.leaseDeadline - value.startedAt - 0.3) < 1e-6,
          'stage must start with a 300-ms lease',
        );
        if (lastRetired)
          check(
            value.id.toLowerCase() !== lastRetired.sample.id.toLowerCase() &&
              value.startedAt >= lastRetired.observedAt,
            'replacement reuses current identity or overlaps prior retirement',
          );
        first = value;
      }
      // Native renewal and acceptance precede the locked snapshot. observedAt
      // is recorded after an async hop, so it cannot anchor this budget.
      tokenCheckpoints.push({
        at: Math.max(value.leaseDeadline - 0.3, value.lastAcceptedAt ?? first.startedAt),
        accepted,
      });
      prior = value;
      priorBytes = accepted;
      priorTotal = total;
      priorTime = observedAt;
      return event;
    };
    read(stage === 1 ? 'began' : 'replaced');
    let renewals = 0;
    while (proof.events[cursor]?.phase === 'renewed') {
      read('renewed');
      renewals++;
    }
    check(renewals > 0, 'every stage requires a renewal');
    lastRetired = read(stage === 3 && retirement ? 'final' : 'retired');
    check(priorBytes > 0n, 'every stage requires positive acceptance');
    cumulative = priorTotal;
    stages.push({
      stage,
      id: first.id.toLowerCase(),
      publishingGeneration,
      bitRate,
      startedAt: first.startedAt,
      campaignStartedAt: origin,
      acceptedPayloadBytes: Number(priorBytes),
      totalAcceptedPayloadBytes: Number(cumulative),
      lastAcceptedAt: prior.lastAcceptedAt,
      ...(stage === 3 && retirement
        ? retirement
        : {
            retirementRequestedAt: lastRetired.retirementRequestedAt,
            retiredObservedAt: lastRetired.observedAt,
          }),
      reason: 'cancelled',
    });
  }
  const final = retirement ? lastRetired : proof.events[cursor++];
  check(
    final?.phase === 'final' && cursor === proof.events.length,
    'requires exactly one final event after three retirements',
  );
  check(
    finiteTime(final.observedAt) &&
      final.observedAt >= priorTime &&
      !Object.hasOwn(final, 'retirementRequestedAt'),
    'invalid final observation',
  );
  assert.deepEqual(
    final.sample,
    lastRetired.sample,
    'Staged probe: final snapshot differs from last retirement',
  );
  return {
    mode: 'staged',
    ...(candidateHeadroom ? { schedule: 'candidate-headroom-v1' } : {}),
    publishingGeneration,
    acceptedPayloadBytes: Number(cumulative),
    totalAcceptedPayloadBytes: Number(cumulative),
    stages,
    eventCount: proof.events.length,
    receiverCapacityQualified: false,
  };
}
