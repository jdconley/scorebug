import assert from 'node:assert/strict';

export function nativeBandwidthProbe({ environment, streaming, requireProcessing, requirePublication, holdSeconds, liveProfile }) {
  const mode = environment.SCOREBUG_TEST_BANDWIDTH_PROBE;
  if (mode === undefined) return null;
  assert.ok(['renew', 'expire'].includes(mode) && streaming && requireProcessing && requirePublication &&
    Number.isSafeInteger(holdSeconds) && holdSeconds >= 90 && holdSeconds <= 600 &&
    liveProfile === '540p30' && environment.SCOREBUG_TEST_LIVE_PROFILE === '540p30' &&
    environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16' && environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1' &&
    ['SCOREBUG_TEST_NATIVE_QUALITY', 'SCOREBUG_TEST_NATIVE_CONFIRMATION', 'SCOREBUG_TEST_ADAPTIVE_PROFILES',
      'SCOREBUG_TEST_PROFILE_TRANSITIONS', 'SCOREBUG_TEST_SOURCE_CADENCE_PACING'].every(key => environment[key] === undefined),
  'Bandwidth probe requires exclusive fixed540p full-pipeline structured-motion qualification and bounded hold');
  return mode;
}
const reasons = new Set(['leaseExpired', 'timeLimit', 'byteLimit', 'invalidClock', 'unavailableStatistics',
  'transportPressure', 'transportBackpressure', 'transportFailed', 'cancelled', 'finished', 'closed', 'replaced']);
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
function counter(value) {
  assert.ok(typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value), 'Malformed counter');
  const parsed = BigInt(value); assert.ok(parsed <= 18446744073709551615n); return parsed;
}
function time(value) { assert.ok(typeof value === 'number' && Number.isFinite(value) && value >= 0, 'Invalid monotonic time'); }

/** Validates local native acceptance/lease evidence, never receiver capacity. */
export function qualifyNativeBandwidthProbe(proof, { mode, scope, publishingGeneration }) {
  assert.ok(['renew', 'expire'].includes(mode));
  assert.equal(proof.formatVersion, 1); assert.equal(proof.isClosed, true); assert.equal(proof.invalid, false);
  assert.equal(proof.mode, mode); assert.ok(['completed', 'withdrawn'].includes(proof.result));
  assert.deepEqual(proof.scope, scope); assert.ok(uuid(scope.publishingAttemptID));
  assert.equal(proof.publishingGeneration, publishingGeneration); assert.ok(counter(publishingGeneration) > 0n);
  assert.ok(Array.isArray(proof.events) && proof.events.length >= 2 && proof.events.length <= 602);
  let prior, priorTime = -1, first, accepted = 0n;
  for (const [index, event] of proof.events.entries()) {
    assert.equal(event.phase, index === 0 ? 'began' : index === proof.events.length - 1 ? 'final' : mode === 'renew' ? 'renewed' : 'observed');
    const value = event.sample; time(event.observedAt); time(value.startedAt); time(value.leaseDeadline);
    assert.ok(event.observedAt >= priorTime && value.startedAt <= event.observedAt);
    assert.ok(uuid(value.id)); assert.equal(value.publishingGeneration, publishingGeneration); assert.equal(value.bitRate, 1_000_000);
    assert.ok(value.leaseDeadline > value.startedAt && value.leaseDeadline <= value.startedAt + 60.3 + 1e-6);
    const bytes = counter(value.acceptedPayloadBytes);
    assert.ok(bytes <= 16n * 1024n * 1024n && bytes % 1316n === 0n && bytes >= accepted);
    assert.equal(value.lastAcceptedAt === null, bytes === 0n);
    if (value.lastAcceptedAt !== null) {
      time(value.lastAcceptedAt);
      assert.ok(value.lastAcceptedAt >= value.startedAt && value.lastAcceptedAt <= event.observedAt &&
        value.lastAcceptedAt <= value.leaseDeadline, 'Future or late native acceptance');
      // Seven TS packets plus the native probe's accounted transport overhead.
      assert.ok(Number(bytes / 1316n) * 1360 * 8 <= (value.lastAcceptedAt - value.startedAt) * value.bitRate + 1,
        'Acceptance exceeds paced accounting budget');
    }
    assert.ok(value.reason === null || reasons.has(value.reason));
    if (value.reason === 'leaseExpired') assert.ok(event.observedAt >= value.leaseDeadline, 'Lease has not expired');
    if (prior) {
      assert.equal(value.id, first.id); assert.equal(value.startedAt, first.startedAt);
      assert.ok(value.leaseDeadline >= prior.leaseDeadline);
      if (value.leaseDeadline > prior.leaseDeadline) {
        assert.equal(event.phase, 'renewed', 'Only renewal may advance the lease');
        const renewedAt = value.leaseDeadline - 0.3;
        assert.ok(renewedAt <= event.observedAt + 1e-6 && renewedAt >= priorTime - 1e-6,
          'Renewal native instant is inconsistent with observations');
        assert.ok(renewedAt < prior.leaseDeadline, 'Renewal cannot revive an expired lease');
      }
      if (mode === 'expire') assert.equal(value.leaseDeadline, first.leaseDeadline);
      if (prior.lastAcceptedAt !== null) assert.ok(value.lastAcceptedAt >= prior.lastAcceptedAt);
      if (prior.reason !== null) { assert.equal(value.reason, prior.reason); assert.equal(bytes, accepted); }
    } else {
      first = value;
      assert.ok(Math.abs(value.leaseDeadline - value.startedAt - 0.3) < 1e-6);
    }
    prior = value; priorTime = event.observedAt; accepted = bytes;
  }
  assert.ok(accepted > 0n, 'Probe did not produce native acceptance evidence');
  assert.notEqual(prior.reason, null, 'Final probe is still active');
  if (mode === 'expire') assert.equal(prior.reason, 'leaseExpired');
  if (proof.result === 'completed') assert.equal(prior.reason, 'cancelled');
  return { mode, id: first.id, publishingGeneration, acceptedPayloadBytes: Number(accepted),
    lastAcceptedAt: prior.lastAcceptedAt, reason: prior.reason, eventCount: proof.events.length,
    receiverCapacityQualified: false };
}
