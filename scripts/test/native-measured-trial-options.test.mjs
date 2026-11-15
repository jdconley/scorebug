import assert from 'node:assert/strict';
import test from 'node:test';
import { nativeMeasuredTrial } from '../native-measured-trial.mjs';
import { nativeCandidateProfile } from '../native-candidate-measurement.mjs';
import { nativeBandwidthProbe } from '../native-bandwidth-probe.mjs';
import { fixtureDeliveryDeadline } from '../native-streaming-options.mjs';

const options = () => ({
  environment: {
    SCOREBUG_TEST_MEASURED_TRIAL: '1',
    SCOREBUG_TEST_CANDIDATE_HEADROOM: '1',
    SCOREBUG_TEST_CANDIDATE_PROFILE: '360p30',
    SCOREBUG_TEST_BANDWIDTH_PROBE: 'staged',
    SCOREBUG_TEST_LIVE_PROFILE: '240p30',
    SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
    SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1500',
  },
  streaming: true,
  requirePublication: true,
  requireProcessing: true,
  holdSeconds: 90,
  liveProfile: '240p30',
});

test('measured trial is explicit and preserves the native240 and candidate360 route', () => {
  assert.equal(nativeMeasuredTrial({ environment: {} }), false);
  const o = options();
  assert.equal(nativeMeasuredTrial(o), true);
  assert.equal(
    fixtureDeliveryDeadline({
      environment: o.environment,
      decoderStall: false,
      measuredTrial: true,
    }),
    1.5,
  );
  assert.equal(nativeCandidateProfile(o), '360p30');
  assert.equal(nativeBandwidthProbe(o), 'staged');
  for (const holdSeconds of [90, 600])
    assert.equal(nativeMeasuredTrial({ ...o, holdSeconds }), true);
});

test('measured trial rejects incomplete or contradictory qualification routes', () => {
  for (const [key, values] of Object.entries({
    SCOREBUG_TEST_MEASURED_TRIAL: ['', '0', 'true'],
    SCOREBUG_TEST_CANDIDATE_HEADROOM: [undefined, '', '0'],
    SCOREBUG_TEST_CANDIDATE_PROFILE: [undefined, '540p30', '1080p30'],
    SCOREBUG_TEST_BANDWIDTH_PROBE: [undefined, 'renew', 'expire'],
    SCOREBUG_TEST_LIVE_PROFILE: [undefined, '360p30'],
    SCOREBUG_TEST_MOTION_FIXTURE: [undefined, '1'],
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: [undefined, '0'],
    SCOREBUG_TEST_NATIVE_QUALITY: ['1'],
    SCOREBUG_TEST_NATIVE_CONFIRMATION: ['1'],
    SCOREBUG_TEST_ADAPTIVE_PROFILES: ['1'],
    SCOREBUG_TEST_PROFILE_TRANSITIONS: ['1'],
    SCOREBUG_TEST_SOURCE_CADENCE_PACING: ['1'],
    SCOREBUG_TEST_UPLINK_PROXY_PORT: ['1234'],
    SCOREBUG_TEST_UPLINK_PROFILE: ['passthrough'],
    SCOREBUG_TEST_DECODER_STALL: ['1'],
    SCOREBUG_TEST_CADENCE_REPORTS: ['1'],
    SCOREBUG_TEST_DELIVERY_DEADLINE_MS: [undefined, '1000', '1500.0'],
    SCOREBUG_TEST_DEADLINE_RESETS: ['1'],
  }))
    for (const value of values) {
      const o = options();
      o.environment[key] = value;
      assert.throws(() => nativeMeasuredTrial(o), `${key}=${value}`);
    }
  for (const [key, values] of Object.entries({
    streaming: [false],
    requirePublication: [false],
    requireProcessing: [false],
    holdSeconds: [89, 601, 90.5, '90', NaN],
    liveProfile: ['360p30', '1080p30'],
  }))
    for (const value of values) {
      assert.throws(() => nativeMeasuredTrial({ ...options(), [key]: value }), `${key}=${value}`);
    }
});
