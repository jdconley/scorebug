import assert from 'node:assert/strict';
import test from 'node:test';
import * as recovery from '../native-measured-recovery.mjs';
import { nativeMeasuredTrial } from '../native-measured-trial.mjs';
import { nativeCandidateHeadroom } from '../native-candidate-headroom.mjs';
import { nativeCandidateProfile } from '../native-candidate-measurement.mjs';
import { nativeBandwidthProbe } from '../native-bandwidth-probe.mjs';

const options = () => ({
  environment: {
    SCOREBUG_TEST_MEASURED_RECOVERY: 'repeated',
    SCOREBUG_TEST_MEASURED_TRIAL: '1',
    SCOREBUG_TEST_CANDIDATE_HEADROOM: '1',
    SCOREBUG_TEST_CANDIDATE_PROFILE: '360p30',
    SCOREBUG_TEST_BANDWIDTH_PROBE: 'repeated',
    SCOREBUG_TEST_LIVE_PROFILE: '240p30',
    SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
    SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
    SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1500',
  },
  streaming: true,
  requirePublication: true,
  requireProcessing: true,
  holdSeconds: 180,
  liveProfile: '240p30',
});

test('explicit repeated recovery preserves its native mode and all measured option selections', () => {
  const o = options();
  assert.equal(nativeCandidateHeadroom(o.environment), true);
  assert.equal(nativeMeasuredTrial(o), true);
  assert.equal(nativeCandidateProfile(o), '360p30');
  assert.equal(nativeBandwidthProbe(o), 'repeated');
  assert.equal(recovery.nativeMeasuredRecovery({ ...o, measuredTrial: true }), true);
  assert.equal(typeof recovery.nativeRepeatedRecovery, 'function');
  assert.equal(recovery.nativeRepeatedRecovery({ ...o, measuredTrial: true }), true);
});

test('repeated dispatch stays false for absent and legacy recovery', () => {
  assert.equal(typeof recovery.nativeRepeatedRecovery, 'function');
  for (const flag of [undefined, 'decoder-stall']) {
    const o = options();
    o.environment.SCOREBUG_TEST_MEASURED_RECOVERY = flag;
    o.environment.SCOREBUG_TEST_BANDWIDTH_PROBE = 'staged';
    assert.equal(recovery.nativeRepeatedRecovery({ ...o, measuredTrial: true }), false);
  }
});

for (const [key, values] of Object.entries({
  SCOREBUG_TEST_MEASURED_RECOVERY: [undefined, '', 'decoder-stall', 'repeated '],
  SCOREBUG_TEST_MEASURED_TRIAL: [undefined, '', 'true'],
  SCOREBUG_TEST_CANDIDATE_HEADROOM: [undefined, '', '0'],
  SCOREBUG_TEST_CANDIDATE_PROFILE: [undefined, '540p30', '1080p30'],
  SCOREBUG_TEST_BANDWIDTH_PROBE: [undefined, 'staged', 'renew', 'expire'],
  SCOREBUG_TEST_LIVE_PROFILE: [undefined, '360p30'],
  SCOREBUG_TEST_MOTION_FIXTURE: [undefined, 'noise'],
  SCOREBUG_TEST_DIRECT_RTMP_RECORDER: [undefined, '0'],
  SCOREBUG_TEST_DELIVERY_DEADLINE_MS: [undefined, '1000', '1500.0'],
  SCOREBUG_TEST_NATIVE_QUALITY: ['1'],
  SCOREBUG_TEST_NATIVE_CONFIRMATION: ['1'],
  SCOREBUG_TEST_ADAPTIVE_PROFILES: ['1'],
  SCOREBUG_TEST_PROFILE_TRANSITIONS: ['1'],
  SCOREBUG_TEST_SOURCE_CADENCE_PACING: ['1'],
  SCOREBUG_TEST_UPLINK_PROXY_PORT: ['1234'],
  SCOREBUG_TEST_UPLINK_PROFILE: ['passthrough'],
  SCOREBUG_TEST_DECODER_STALL: ['1'],
  SCOREBUG_TEST_CADENCE_REPORTS: ['1'],
  SCOREBUG_TEST_DEADLINE_RESETS: ['1'],
})) {
  test(`repeated options reject missing or contradictory ${key}`, () => {
    for (const value of values) {
      const o = options();
      o.environment[key] = value;
      for (const validate of [nativeMeasuredTrial, nativeCandidateProfile, nativeBandwidthProbe])
        assert.throws(() => validate(o), `${validate.name}: ${key}=${value}`);
    }
  });
}

for (const [key, values] of Object.entries({
  streaming: [false],
  requirePublication: [false],
  requireProcessing: [false],
  holdSeconds: [90, 179, 181, 600, 180.5, '180', undefined, NaN, Infinity],
  liveProfile: ['360p30', '540p30'],
})) {
  test(`repeated route requires validated ${key}`, () => {
    for (const value of values)
      for (const validate of [nativeMeasuredTrial, nativeCandidateProfile, nativeBandwidthProbe])
        assert.throws(() => validate({ ...options(), [key]: value }), validate.name);
  });
}

test('repeated recovery selector requires measured validation, exact hold, and paired flags', () => {
  assert.equal(typeof recovery.nativeRepeatedRecovery, 'function');
  for (const validate of [recovery.nativeRepeatedRecovery, recovery.nativeMeasuredRecovery]) {
    for (const measuredTrial of [undefined, false, 1, 'true'])
      assert.throws(() => validate({ ...options(), measuredTrial }));
    for (const holdSeconds of [90, 179, 181, 600, '180', NaN])
      assert.throws(() => validate({ ...options(), measuredTrial: true, holdSeconds }));
    for (const key of ['SCOREBUG_TEST_MEASURED_TRIAL', 'SCOREBUG_TEST_BANDWIDTH_PROBE']) {
      const o = options();
      delete o.environment[key];
      assert.throws(() => validate({ ...o, measuredTrial: true }));
    }
  }
});
