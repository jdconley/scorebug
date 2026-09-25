import assert from 'node:assert/strict';
import test from 'node:test';
const implementation = await import('../native-capacity-recovery.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
export const capacityEnvironment = () => ({
  SCOREBUG_TEST_CAPACITY_RECOVERY: '1',
  SCOREBUG_TEST_UPLINK_PROFILE: 'capacity550k',
  SCOREBUG_TEST_PROBE_POLICY: 'recovery-budget-v1',
  SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180',
  SCOREBUG_TEST_FILE_INPUT: '/local/input.mov',
  SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
  SCOREBUG_TEST_RELAY_PUBLICATION: '1',
  SCOREBUG_TEST_WORKER_PROCESSING: '1',
  SCOREBUG_TEST_MEASURED_TRIAL: '1',
  SCOREBUG_TEST_CANDIDATE_HEADROOM: '1',
  SCOREBUG_TEST_CANDIDATE_PROFILE: '360p30',
  SCOREBUG_TEST_LIVE_PROFILE: '240p30',
  SCOREBUG_TEST_BANDWIDTH_PROBE: 'staged',
  SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1500',
  SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: '400',
});
const select = (environment = capacityEnvironment(), rest = {}) => {
  assert.equal(typeof implementation.nativeCapacityRecovery, 'function');
  return implementation.nativeCapacityRecovery({
    environment,
    streaming: true,
    holdSeconds: 180,
    ...rest,
  });
};
test('rate-ledger evidence needs explicit complete capacity selection and defaults to legacy', () => {
  assert.equal(typeof implementation.nativeCapacityEvidencePolicy, 'function');
  const evidence = (environment, capacityRecovery = true) =>
    implementation.nativeCapacityEvidencePolicy({ environment, capacityRecovery });
  assert.equal(evidence({}), 'congestion-v1');
  assert.equal(evidence({}, false), 'congestion-v1');
  assert.equal(evidence({ SCOREBUG_TEST_CAPACITY_EVIDENCE: 'rate-ledger-v1' }), 'rate-ledger-v1');
  assert.equal(evidence({ SCOREBUG_TEST_CAPACITY_EVIDENCE: 'token-budget-v1' }), 'token-budget-v1');
  assert.throws(() => evidence({ SCOREBUG_TEST_CAPACITY_EVIDENCE: 'rate-ledger-v1' }, false));
  assert.throws(() => evidence({ SCOREBUG_TEST_CAPACITY_EVIDENCE: 'token-budget-v1' }, false));
  for (const value of [null, false, '', '1', 'congestion-v1', 'rate-ledger', ' rate-ledger-v1'])
    assert.throws(() => evidence({ SCOREBUG_TEST_CAPACITY_EVIDENCE: value }));
});
test('capacity route requires a separate complete explicit file experiment', () => {
  const environment = capacityEnvironment(),
    before = structuredClone(environment);
  assert.equal(select(environment), true);
  assert.equal(select({ ...environment, SCOREBUG_TEST_DECODER_THREADING: 'slice' }), true);
  assert.deepEqual(environment, before);
  assert.equal(select({}), false);
  assert.equal(select({ SCOREBUG_TEST_UPLINK_PROFILE: 'loss0p2-delay30' }), false);
});
for (const key of Object.keys(capacityEnvironment()))
  test(`capacity selection rejects missing/malformed ${key}`, () => {
    for (const value of [undefined, '', '0', 'true', ' 1', '0180'])
      assert.throws(() => select({ ...capacityEnvironment(), [key]: value }));
  });
for (const key of [
  'SCOREBUG_TEST_FILE_CAPTURE',
  'SCOREBUG_TEST_UPLINK_PROXY_PORT',
  'SCOREBUG_TEST_MEASURED_RECOVERY',
  'SCOREBUG_TEST_MOTION_FIXTURE',
  'SCOREBUG_FIXTURE_FAIL_AFTER',
  'SCOREBUG_TEST_NATIVE_QUALITY',
  'SCOREBUG_TEST_NATIVE_CONFIRMATION',
  'SCOREBUG_TEST_PROFILE_TRANSITIONS',
  'SCOREBUG_TEST_ADAPTIVE_PROFILES',
  'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
  'SCOREBUG_TEST_DECODER_STALL',
  'SCOREBUG_TEST_CADENCE_REPORTS',
  'SCOREBUG_TEST_DEADLINE_RESETS',
  'SCOREBUG_TEST_PUBLISH_PACING',
  'SCOREBUG_TEST_DELIVERY_PROFILE',
])
  test(`capacity selection rejects mixed ${key}`, () => {
    for (const value of ['', '1', 'decoder-stall', 'repeated'])
      assert.throws(() => select({ ...capacityEnvironment(), [key]: value }));
  });
test('capacity selection rejects wrong derived mode or duration', () => {
  for (const holdSeconds of [undefined, null, 179, 181, 600, '180'])
    assert.throws(() => select(capacityEnvironment(), { holdSeconds }));
  for (const streaming of [undefined, false, 'true'])
    assert.throws(() => select(capacityEnvironment(), { streaming }));
  for (const value of ['', 'automatic', 'frame'])
    assert.throws(() =>
      select({ ...capacityEnvironment(), SCOREBUG_TEST_DECODER_THREADING: value }),
    );
});

test('capacity selection composes existing native file and measured source parsers', async () => {
  const { nativeFileFixtureOptions, nativeProbePolicy } =
    await import('../native-file-fixture.mjs');
  const { nativeUplinkOptions } = await import('../native-streaming-options.mjs');
  const { nativeMeasuredTrial } = await import('../native-measured-trial.mjs');
  const { nativeLiveProfile } = await import('../native-live-profile.mjs');
  const { nativeBandwidthProbe } = await import('../native-bandwidth-probe.mjs');
  const { nativeCandidateProfile } = await import('../native-candidate-measurement.mjs');
  const environment = capacityEnvironment();
  const args = {
    environment,
    streaming: true,
    holdSeconds: 180,
    requirePublication: true,
    requireProcessing: true,
    requireQuality: false,
    requireConfirmation: false,
    fixtureWorkload: 'real-file',
    liveProfile: '240p30',
  };
  assert.equal(nativeFileFixtureOptions(args).minimumDurationSeconds, 270);
  assert.equal(nativeProbePolicy(environment), 'recovery-budget-v1');
  assert.equal(nativeUplinkOptions(args), 'capacity550k');
  assert.equal(nativeMeasuredTrial(args), true);
  assert.equal(nativeLiveProfile(args), '240p30');
  assert.equal(nativeBandwidthProbe(args), 'staged');
  assert.equal(nativeCandidateProfile(args), '360p30');
  for (const patch of [
    { SCOREBUG_TEST_CAPACITY_RECOVERY: undefined },
    { SCOREBUG_TEST_MEASURED_RECOVERY: 'decoder-stall' },
    { SCOREBUG_TEST_STREAM_HOLD_SECONDS: '90' },
    { SCOREBUG_TEST_PROBE_POLICY: undefined },
    { SCOREBUG_TEST_DELIVERY_PROFILE: 'floor24-v1' },
  ]) {
    const bad = { ...args, environment: { ...environment, ...patch } };
    for (const fn of [
      nativeFileFixtureOptions,
      nativeUplinkOptions,
      nativeMeasuredTrial,
      nativeLiveProfile,
      nativeBandwidthProbe,
      nativeCandidateProfile,
    ])
      assert.throws(() => fn(bad));
  }
});

test('native harness rejects incomplete capacity qualification before artifacts or resources', async () => {
  const { spawnSync } = await import('node:child_process');
  const { readdirSync } = await import('node:fs');
  const before = readdirSync(new URL('../../artifacts/qa/', import.meta.url)).filter((name) =>
    name.startsWith('native-app-'),
  );
  const result = spawnSync(process.execPath, ['scripts/test-native-app.mjs', '--streaming'], {
    cwd: new URL('../../', import.meta.url),
    env: { ...process.env, ...capacityEnvironment(), SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '0' },
    encoding: 'utf8',
    timeout: 10000,
  });
  assert.equal(result.status, 1);
  assert.match(
    result.stderr,
    /Extended hold requires native streaming and the direct RTMP recorder/,
  );
  assert.deepEqual(
    readdirSync(new URL('../../artifacts/qa/', import.meta.url)).filter((name) =>
      name.startsWith('native-app-'),
    ),
    before,
  );
});

test('native entry point rejects ledger selection outside capacity before creating artifacts', async () => {
  const { spawnSync } = await import('node:child_process');
  const { readdirSync } = await import('node:fs');
  const directory = new URL('../../artifacts/qa/', import.meta.url);
  const names = () => readdirSync(directory).filter((name) => name.startsWith('native-app-'));
  const before = names();
  const environment = Object.fromEntries(
    Object.entries(process.env).filter(([key]) => !key.startsWith('SCOREBUG_TEST_')),
  );
  const result = spawnSync(process.execPath, ['scripts/test-native-app.mjs', '--streaming'], {
    cwd: new URL('../../', import.meta.url),
    env: { ...environment, SCOREBUG_TEST_CAPACITY_EVIDENCE: 'rate-ledger-v1' },
    encoding: 'utf8',
    timeout: 10000,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Rate-ledger evidence requires complete capacity recovery/);
  assert.deepEqual(names(), before);
});

test('750k native host selection requires its exact210s complete route', async () => {
  const environment = {
    ...capacityEnvironment(),
    SCOREBUG_TEST_UPLINK_PROFILE: 'capacity750k',
    SCOREBUG_TEST_STREAM_HOLD_SECONDS: '210',
  };
  assert.equal(select(environment, { holdSeconds: 210 }), true);
  for (const holdSeconds of [180, 209, 211])
    assert.throws(() => select(environment, { holdSeconds }));
  assert.throws(() =>
    select({ ...environment, SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180' }, { holdSeconds: 210 }),
  );
  assert.throws(() =>
    select({ ...environment, SCOREBUG_TEST_CAPACITY_RECOVERY: undefined }, { holdSeconds: 210 }),
  );
  const { nativeFileFixtureOptions } = await import('../native-file-fixture.mjs');
  const { nativeUplinkOptions } = await import('../native-streaming-options.mjs');
  const { nativeMeasuredTrial } = await import('../native-measured-trial.mjs');
  const args = {
    environment,
    streaming: true,
    holdSeconds: 210,
    requirePublication: true,
    requireProcessing: true,
    requireQuality: false,
    requireConfirmation: false,
    fixtureWorkload: 'real-file',
    liveProfile: '240p30',
  };
  assert.equal(nativeFileFixtureOptions(args).minimumDurationSeconds, 300);
  assert.equal(nativeUplinkOptions(args), 'capacity750k');
  assert.equal(nativeMeasuredTrial(args), true);
});

const ownedEnvironment = () => ({
  ...capacityEnvironment(),
  SCOREBUG_TEST_UPLINK_PROFILE: 'capacity750k-retry',
  SCOREBUG_TEST_STREAM_HOLD_SECONDS: '270',
  SCOREBUG_TEST_OWNED_MEASUREMENT: '1',
  SCOREBUG_TEST_CAPACITY_EVIDENCE: 'token-budget-v1',
});
test('owned retry is an exact separate capacity selection with a longer source budget', async () => {
  const environment = ownedEnvironment();
  assert.equal(select(environment, { holdSeconds: 270 }), true);
  const { measuredCapacityProfile, measuredCapacityUplinkConfiguration } =
    await import('../measured-capacity-uplink.mjs');
  assert.deepEqual(measuredCapacityProfile('capacity750k-retry'), {
    rateBitsPerSecond: 750000,
    limitedAtMilliseconds: 90000,
    restoredAtMilliseconds: 150000,
    holdSeconds: 270,
  });
  assert.deepEqual(
    measuredCapacityUplinkConfiguration('capacity750k-retry'),
    measuredCapacityUplinkConfiguration('capacity750k'),
  );
  const { nativeFileFixtureOptions } = await import('../native-file-fixture.mjs');
  assert.equal(
    nativeFileFixtureOptions({ environment, streaming: true, holdSeconds: 270 })
      .minimumDurationSeconds,
    360,
  );
});
for (const patch of [
  { SCOREBUG_TEST_OWNED_MEASUREMENT: undefined },
  { SCOREBUG_TEST_OWNED_MEASUREMENT: 'true' },
  { SCOREBUG_TEST_OWNED_MEASUREMENT: '' },
  { SCOREBUG_TEST_CAPACITY_EVIDENCE: undefined },
  { SCOREBUG_TEST_CAPACITY_EVIDENCE: 'rate-ledger-v1' },
  { SCOREBUG_TEST_UPLINK_PROFILE: 'capacity750k', SCOREBUG_TEST_STREAM_HOLD_SECONDS: '210' },
])
  test(`owned retry rejects incomplete or mixed selection ${JSON.stringify(patch)}`, () => {
    const environment = { ...ownedEnvironment(), ...patch };
    assert.throws(() =>
      select(environment, { holdSeconds: Number(environment.SCOREBUG_TEST_STREAM_HOLD_SECONDS) }),
    );
  });
test('an owned flag cannot silently fall through a non-capacity route', () => {
  assert.throws(() => select({ SCOREBUG_TEST_OWNED_MEASUREMENT: '1' }));
});

test('native runner fails before resources until whole-history owned qualification is wired', async () => {
  const { spawnSync } = await import('node:child_process');
  const environment = Object.fromEntries(
    Object.entries(process.env).filter(([key]) => !key.startsWith('SCOREBUG_TEST_')),
  );
  const result = spawnSync(process.execPath, ['scripts/test-native-app.mjs', '--streaming'], {
    cwd: new URL('../..', import.meta.url),
    env: { ...environment, ...ownedEnvironment(), SCOREBUG_IOS_RUNTIME: '00.0' },
    encoding: 'utf8',
    timeout: 10000,
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Owned recovery runner awaits its whole-history qualifier/);
});
