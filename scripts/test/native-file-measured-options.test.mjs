import test from 'node:test';
import { nativeUplinkOptions } from '../native-streaming-options.mjs';
import assert from 'node:assert/strict';
import { nativeFileFixtureOptions, nativeProbePolicy } from '../native-file-fixture.mjs';
import { nativeLiveProfile } from '../native-live-profile.mjs';
import { nativeCandidateHeadroom } from '../native-candidate-headroom.mjs';
import { nativeCandidateProfile } from '../native-candidate-measurement.mjs';
import { nativeBandwidthProbe } from '../native-bandwidth-probe.mjs';
import { nativeMeasuredTrial } from '../native-measured-trial.mjs';
import { nativeMeasuredRecovery, nativeRepeatedRecovery } from '../native-measured-recovery.mjs';
const valid = () => ({
  SCOREBUG_TEST_FILE_INPUT: '/local/input.mov',
  SCOREBUG_TEST_STREAM_HOLD_SECONDS: '90',
  SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
  SCOREBUG_TEST_RELAY_PUBLICATION: '1',
  SCOREBUG_TEST_WORKER_PROCESSING: '1',
  SCOREBUG_TEST_LIVE_PROFILE: '240p30',
  SCOREBUG_TEST_CANDIDATE_PROFILE: '360p30',
  SCOREBUG_TEST_CANDIDATE_HEADROOM: '1',
  SCOREBUG_TEST_MEASURED_TRIAL: '1',
  SCOREBUG_TEST_BANDWIDTH_PROBE: 'staged',
  SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1500',
});
function options(environment) {
  return {
    environment,
    streaming: true,
    requirePublication: true,
    requireProcessing: true,
    holdSeconds: Number(environment.SCOREBUG_TEST_STREAM_HOLD_SECONDS),
    liveProfile: '240p30',
  };
}
function qualify(environment) {
  const args = options(environment);
  assert.equal(nativeFileFixtureOptions(args).minimumDurationSeconds, args.holdSeconds + 90);
  assert.equal(nativeLiveProfile(args), '240p30');
  assert.equal(nativeCandidateHeadroom(environment), true);
  assert.equal(nativeCandidateProfile(args), '360p30');
  assert.equal(nativeBandwidthProbe(args), environment.SCOREBUG_TEST_BANDWIDTH_PROBE);
  assert.equal(nativeMeasuredTrial(args), true);
  const recovery = { ...args, measuredTrial: true };
  assert.equal(
    nativeMeasuredRecovery(recovery),
    environment.SCOREBUG_TEST_MEASURED_RECOVERY !== undefined,
  );
  assert.equal(
    nativeRepeatedRecovery(recovery),
    environment.SCOREBUG_TEST_MEASURED_RECOVERY === 'repeated',
  );
}
for (const recovery of [undefined, 'decoder-stall', 'repeated'])
  test(`complete file measured route accepts ${recovery ?? 'trial'} only with its original gates`, () => {
    const env = valid();
    if (recovery !== undefined) env.SCOREBUG_TEST_MEASURED_RECOVERY = recovery;
    if (recovery === 'repeated') {
      env.SCOREBUG_TEST_BANDWIDTH_PROBE = 'repeated';
      env.SCOREBUG_TEST_STREAM_HOLD_SECONDS = '180';
    }
    qualify(env);
  });
for (const key of Object.keys(valid()))
  test(`file measured route rejects absent or malformed ${key}`, () => {
    for (const value of [undefined, '', 'true', '0']) {
      const env = { ...valid(), [key]: value };
      if (key === 'SCOREBUG_TEST_FILE_INPUT' && value === undefined) continue; // This is the separate synthetic route.
      assert.throws(() => nativeFileFixtureOptions(options(env)));
    }
  });
for (const key of [
  'SCOREBUG_TEST_MOTION_FIXTURE',
  'SCOREBUG_TEST_NATIVE_QUALITY',
  'SCOREBUG_TEST_NATIVE_CONFIRMATION',
  'SCOREBUG_TEST_PROFILE_TRANSITIONS',
  'SCOREBUG_TEST_ADAPTIVE_PROFILES',
  'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
  'SCOREBUG_TEST_UPLINK_PROFILE',
  'SCOREBUG_TEST_UPLINK_PROXY_PORT',
  'SCOREBUG_TEST_DECODER_STALL',
  'SCOREBUG_TEST_CADENCE_REPORTS',
  'SCOREBUG_TEST_DEADLINE_RESETS',
  'SCOREBUG_TEST_DECODER_THREADING',
  'SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS',
  'SCOREBUG_TEST_PUBLISH_PACING',
])
  test(`file measured route rejects conflicting ${key} through every source selector`, () => {
    for (const value of ['', '1', 'blocks16']) {
      const env = { ...valid(), [key]: value };
      const args = options(env);
      for (const select of [
        () => nativeFileFixtureOptions(args),
        () => nativeLiveProfile(args),
        () => nativeCandidateHeadroom(env),
        () => nativeCandidateProfile(args),
        () => nativeBandwidthProbe(args),
        () => nativeMeasuredTrial(args),
      ])
        assert.throws(select);
    }
  });
test('repeated file mode cannot be selected partially or with a different hold', () => {
  for (const patch of [
    { SCOREBUG_TEST_MEASURED_RECOVERY: 'repeated' },
    { SCOREBUG_TEST_BANDWIDTH_PROBE: 'repeated' },
    { SCOREBUG_TEST_MEASURED_RECOVERY: 'repeated', SCOREBUG_TEST_BANDWIDTH_PROBE: 'repeated' },
    {
      SCOREBUG_TEST_MEASURED_RECOVERY: 'decoder-stall',
      SCOREBUG_TEST_BANDWIDTH_PROBE: 'repeated',
      SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180',
    },
    { SCOREBUG_TEST_MEASURED_RECOVERY: 'other' },
    { SCOREBUG_TEST_CANDIDATE_PROFILE: '540p30' },
    { SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1000' },
    { SCOREBUG_TEST_STREAM_HOLD_SECONDS: '090' },
  ])
    assert.throws(() => nativeFileFixtureOptions(options({ ...valid(), ...patch })));
});

for (const profile of ['passthrough', 'loss0p2-delay30'])
  test(`complete staged file route composes with ${profile} link`, () => {
    const env = {
      ...valid(),
      SCOREBUG_TEST_UPLINK_PROFILE: profile,
      ...(profile === 'loss0p2-delay30' ? { SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: '400' } : {}),
    };
    qualify(env);
    const args = {
      ...options(env),
      fixtureWorkload: 'real-file',
      requireQuality: false,
      requireConfirmation: false,
    };
    assert.equal(nativeUplinkOptions(args), profile);
    for (const latency of ['', '120', '399', '401', '0400'])
      assert.throws(() => qualify({ ...env, SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: latency }));
    if (profile === 'loss0p2-delay30')
      assert.throws(() => qualify({ ...env, SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: undefined }));
    for (const patch of [
      { requireQuality: true },
      { requireConfirmation: true },
      { fixtureWorkload: 'motion-blocks16' },
      { liveProfile: '360p30' },
      { holdSeconds: 89 },
      { streaming: false },
      { requireProcessing: false },
      { requirePublication: false },
    ])
      assert.throws(() => nativeUplinkOptions({ ...args, ...patch }));
    for (const patch of [
      { SCOREBUG_TEST_MEASURED_RECOVERY: 'decoder-stall' },
      {
        SCOREBUG_TEST_BANDWIDTH_PROBE: 'repeated',
        SCOREBUG_TEST_MEASURED_RECOVERY: 'repeated',
        SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180',
      },
      { SCOREBUG_TEST_MEASURED_TRIAL: undefined },
      { SCOREBUG_TEST_FILE_INPUT: undefined },
      { SCOREBUG_TEST_UPLINK_PROXY_PORT: '1234' },
    ]) {
      const environment = { ...env, ...patch };
      assert.throws(() => qualify(environment));
      assert.throws(() => nativeUplinkOptions({ ...args, environment }));
    }
  });

test('only the complete impaired file route accepts explicit slice decoding', () => {
  const env = {
    ...valid(),
    SCOREBUG_TEST_UPLINK_PROFILE: 'loss0p2-delay30',
    SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: '400',
    SCOREBUG_TEST_DECODER_THREADING: 'slice',
  };
  qualify(env);
  assert.equal(
    nativeUplinkOptions({
      ...options(env),
      fixtureWorkload: 'real-file',
      requireQuality: false,
      requireConfirmation: false,
    }),
    'loss0p2-delay30',
  );
  for (const mode of ['', 'automatic', 'frame', 'Slice', '1'])
    assert.throws(() => qualify({ ...env, SCOREBUG_TEST_DECODER_THREADING: mode }));
  for (const profile of [undefined, 'passthrough'])
    assert.throws(() =>
      qualify({
        ...env,
        SCOREBUG_TEST_UPLINK_PROFILE: profile,
        SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: undefined,
      }),
    );
  for (const patch of [
    { SCOREBUG_TEST_BANDWIDTH_PROBE: undefined },
    { SCOREBUG_TEST_MEASURED_TRIAL: undefined },
    { SCOREBUG_TEST_MEASURED_RECOVERY: 'decoder-stall' },
    { SCOREBUG_TEST_DIRECT_RTMP_RECORDER: undefined },
  ])
    assert.throws(() => qualify({ ...env, ...patch }));
});

for (const profile of ['passthrough', 'loss0p2-delay30'])
  test(`recovery policy requires the complete staged file ${profile} route`, () => {
    const env = {
      ...valid(),
      SCOREBUG_TEST_PROBE_POLICY: 'recovery-budget-v1',
      SCOREBUG_TEST_UPLINK_PROFILE: profile,
      ...(profile === 'loss0p2-delay30' ? { SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: '400' } : {}),
    };
    qualify(env);
    assert.equal(nativeProbePolicy(env), 'recovery-budget-v1');
    for (const key of Object.keys(env).filter((key) => key !== 'SCOREBUG_TEST_PROBE_POLICY')) {
      const bad = { ...env, [key]: undefined };
      assert.throws(() => nativeProbePolicy(bad), key);
      assert.throws(() => nativeFileFixtureOptions(options(bad)), key);
    }
    for (const value of [
      '',
      '1',
      'local-zero-loss-v1',
      'recovery-budget-v2',
      ' recovery-budget-v1',
    ]) {
      const bad = { ...env, SCOREBUG_TEST_PROBE_POLICY: value };
      assert.throws(() => nativeProbePolicy(bad));
      assert.throws(() => qualify(bad));
    }
    for (const patch of [
      {
        SCOREBUG_TEST_BANDWIDTH_PROBE: 'repeated',
        SCOREBUG_TEST_MEASURED_RECOVERY: 'repeated',
        SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180',
      },
      { SCOREBUG_TEST_MEASURED_RECOVERY: 'decoder-stall' },
      { SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16' },
      { SCOREBUG_TEST_ADAPTIVE_PROFILES: '1' },
      { SCOREBUG_TEST_UPLINK_PROXY_PORT: '12345' },
    ])
      assert.throws(() => nativeProbePolicy({ ...env, ...patch }));
  });
test('historical routes keep the original probe policy and partial opt-ins cannot disappear', () => {
  assert.equal(nativeProbePolicy({}), 'local-zero-loss-v1');
  assert.equal(nativeProbePolicy(valid()), 'local-zero-loss-v1');
  assert.throws(() => nativeProbePolicy({ SCOREBUG_TEST_PROBE_POLICY: 'recovery-budget-v1' }));
  assert.throws(() =>
    nativeFileFixtureOptions(options({ SCOREBUG_TEST_PROBE_POLICY: 'recovery-budget-v1' })),
  );
});

test('delivery floor has an explicit host selection and preserves the strict default', async () => {
  const { nativeDeliveryProfile } = await import('../native-file-fixture.mjs');
  assert.equal(typeof nativeDeliveryProfile, 'function');
  assert.equal(nativeDeliveryProfile({}), 'strict30-v1');
  assert.equal(nativeDeliveryProfile(valid()), 'strict30-v1');
  const env = { ...valid(), SCOREBUG_TEST_DELIVERY_PROFILE: 'floor24-v1' };
  qualify(env);
  assert.equal(nativeDeliveryProfile(env), 'floor24-v1');
  for (const key of Object.keys(valid())) {
    const bad = { ...env, [key]: undefined };
    assert.throws(() => nativeDeliveryProfile(bad), key);
    assert.throws(() => nativeFileFixtureOptions(options(bad)), key);
  }
  for (const value of ['', '24', 'strict30-v1', ' floor24-v1', 'floor24-v2'])
    assert.throws(() => nativeDeliveryProfile({ ...env, SCOREBUG_TEST_DELIVERY_PROFILE: value }));
  for (const patch of [
    { SCOREBUG_TEST_MEASURED_RECOVERY: 'decoder-stall' },
    {
      SCOREBUG_TEST_MEASURED_RECOVERY: 'repeated',
      SCOREBUG_TEST_BANDWIDTH_PROBE: 'repeated',
      SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180',
    },
    { SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16' },
    { SCOREBUG_TEST_ADAPTIVE_PROFILES: '1' },
    { SCOREBUG_TEST_DECODER_STALL: '1' },
    { SCOREBUG_TEST_STREAM_HOLD_SECONDS: '89' },
  ])
    assert.throws(() => nativeDeliveryProfile({ ...env, ...patch }));
});
