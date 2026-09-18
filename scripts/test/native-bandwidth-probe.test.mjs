import assert from 'node:assert/strict';
import test from 'node:test';
import { nativeBandwidthProbe, qualifyNativeBandwidthProbe } from '../native-bandwidth-probe.mjs';
const scope = { recordingID: 'r', matchID: 'm', broadcastGeneration: 1,
  publishingAttemptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', appliedProfileRevision: '1' };
function options() { return { environment: { SCOREBUG_TEST_BANDWIDTH_PROBE: 'renew',
  SCOREBUG_TEST_LIVE_PROFILE: '540p30', SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
  SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1' }, streaming: true, requireProcessing: true,
  requirePublication: true, holdSeconds: 90, liveProfile: '540p30' }; }
function fixture(mode = 'renew') {
  const first = { id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', publishingGeneration: '7', bitRate: 1_000_000,
    startedAt: 10, leaseDeadline: 10.3, acceptedPayloadBytes: '0', lastAcceptedAt: null, reason: null };
  const next = { ...first, leaseDeadline: mode === 'renew' ? 10.4 : 10.3,
    acceptedPayloadBytes: '1316', lastAcceptedAt: 10.05, reason: mode === 'expire' ? 'leaseExpired' : null };
  return { formatVersion: 1, isClosed: true, invalid: false, mode,
    result: mode === 'expire' ? 'withdrawn' : 'completed', scope, publishingGeneration: '7', events: [
      { phase: 'began', observedAt: 10.001, sample: first },
      { phase: mode === 'renew' ? 'renewed' : 'observed', observedAt: mode === 'renew' ? 10.101 : 10.301, sample: next },
      { phase: 'final', observedAt: 90, sample: { ...next, reason: next.reason ?? 'cancelled' } },
    ] };
}
const qualify = (value, mode = 'renew') => qualifyNativeBandwidthProbe(value, { mode, scope, publishingGeneration: '7' });
test('probe option is absent by default and modes require fixed-profile full pipeline', () => {
  assert.equal(nativeBandwidthProbe({ ...options(), environment: {} }), null);
  for (const mode of ['renew', 'expire']) {
    const o = options(); o.environment.SCOREBUG_TEST_BANDWIDTH_PROBE = mode;
    assert.equal(nativeBandwidthProbe(o), mode);
  }
  for (const key of ['streaming', 'requireProcessing', 'requirePublication'])
    assert.throws(() => nativeBandwidthProbe({ ...options(), [key]: false }));
  for (const key of ['SCOREBUG_TEST_NATIVE_QUALITY', 'SCOREBUG_TEST_NATIVE_CONFIRMATION',
    'SCOREBUG_TEST_ADAPTIVE_PROFILES', 'SCOREBUG_TEST_PROFILE_TRANSITIONS', 'SCOREBUG_TEST_SOURCE_CADENCE_PACING']) {
    const o = options(); o.environment[key] = '1'; assert.throws(() => nativeBandwidthProbe(o));
  }
  for (const bad of ['', '1', 'true', ' renew']) {
    const o = options(); o.environment.SCOREBUG_TEST_BANDWIDTH_PROBE = bad;
    assert.throws(() => nativeBandwidthProbe(o));
  }
  for (const holdSeconds of [89, 601, 90.5, NaN]) assert.throws(() => nativeBandwidthProbe({ ...options(), holdSeconds }));
});
test('closed accepted probe proof stays explicitly local-only', () => {
  for (const mode of ['renew', 'expire']) {
    const result = qualify(fixture(mode), mode);
    assert.equal(result.acceptedPayloadBytes, 1316);
    assert.equal(result.receiverCapacityQualified, false);
    assert.equal(result.mode, mode);
  }
});
const mutations = {
  open: x => { x.isClosed = false; }, invalid: x => { x.invalid = true; },
  failed: x => { x.result = 'operationFailed'; }, wrongScope: x => { x.scope = { ...scope, recordingID: 'other' }; },
  wrongGeneration: x => { x.publishingGeneration = '8'; }, wrongID: x => { x.events[1].sample.id = scope.publishingAttemptID; },
  wrongRate: x => { x.events[1].sample.bitRate = 2_000_000; }, nonfinite: x => { x.events[1].observedAt = NaN; },
  futureAcceptance: x => { x.events[1].sample.lastAcceptedAt = 11; }, lateAcceptance: x => { x.events[2].sample.lastAcceptedAt = 10.5; },
  fractionalCounter: x => { x.events[1].sample.acceptedPayloadBytes = '1.5'; },
  nonPacketCounter: x => { x.events[1].sample.acceptedPayloadBytes = '1317'; },
  counterReversal: x => { x.events[2].sample.acceptedPayloadBytes = '0'; x.events[2].sample.lastAcceptedAt = null; },
  timestampReversal: x => { x.events[1].observedAt = 10; },
  deadlineReversal: x => { x.events[2].sample.leaseDeadline = 10.3; },
  liveFinal: x => { x.events[2].sample.reason = null; },
  unboundedEvents: x => { x.events = Array(603).fill(x.events[0]); },
  malformedID: x => { for (const e of x.events) e.sample.id = 'not-uuid'; },
  reasonRevival: x => { x.events[1].sample.reason = 'transportPressure'; },
  impossibleRate: x => { for (const e of x.events.slice(1)) e.sample.acceptedPayloadBytes = '131600'; },
  missingAcceptance: x => { for (const e of x.events) { e.sample.acceptedPayloadBytes = '0'; e.sample.lastAcceptedAt = null; } },
};
for (const [name, mutate] of Object.entries(mutations)) test(`rejects ${name} proof`, () => {
  const value = fixture(); mutate(value); assert.throws(() => qualify(value));
});
test('expiry requires elapsed lease and no renew events', () => {
  const value = fixture('expire'); value.events[1].observedAt = 10.2;
  assert.throws(() => qualify(value, 'expire'));
  const renewed = fixture('expire'); renewed.events[1].phase = 'renewed';
  assert.throws(() => qualify(renewed, 'expire'));
});
test('renewal cannot claim a future native instant or revive an expired lease', () => {
  const future = fixture();
  for (const event of future.events.slice(1)) event.sample.leaseDeadline = 11.4;
  assert.throws(() => qualify(future), /renew/i);
  const revived = fixture();
  revived.events[1].observedAt = 10.401;
  for (const event of revived.events.slice(1)) event.sample.leaseDeadline = 10.7;
  assert.throws(() => qualify(revived), /renew/i);
});
test('terminal observation cannot silently renew a lease', () => {
  const value = fixture(); value.events[2].sample.leaseDeadline = 10.5;
  assert.throws(() => qualify(value));
});

test('new lower fixed profiles do not inherit the fixed540 probe admission', () => {
  for (const profile of ['360p30', '240p30']) {
    const input = options();
    input.liveProfile = profile;
    input.environment.SCOREBUG_TEST_LIVE_PROFILE = profile;
    assert.throws(() => nativeBandwidthProbe(input));
  }
});

test('single-campaign harness rejects repeated mode until multi-cycle replay exists', () => {
  const o = options();
  o.environment.SCOREBUG_TEST_BANDWIDTH_PROBE = 'repeated';
  assert.throws(() => nativeBandwidthProbe(o));
  const proof = { ...fixture(), formatVersion: 3, mode: 'repeated', campaigns: [] };
  assert.throws(() => qualify(proof, 'repeated'));
});
