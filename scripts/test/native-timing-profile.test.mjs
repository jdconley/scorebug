import assert from 'node:assert/strict';
import test from 'node:test';
import { nativeCapacityRecovery } from '../native-capacity-recovery.mjs';
import { nativeFileFixtureOptions } from '../native-file-fixture.mjs';
import { nativeMeasuredTrial } from '../native-measured-trial.mjs';
import { fixtureDeliveryDeadline } from '../native-streaming-options.mjs';
const environment = () => ({
  SCOREBUG_TEST_CAPACITY_RECOVERY: '1',
  SCOREBUG_TEST_UPLINK_PROFILE: 'capacity750k-retry',
  SCOREBUG_TEST_OWNED_MEASUREMENT: '1',
  SCOREBUG_TEST_CAPACITY_EVIDENCE: 'token-budget-v1',
  SCOREBUG_TEST_PROBE_POLICY: 'recovery-budget-v1',
  SCOREBUG_TEST_STREAM_HOLD_SECONDS: '270',
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
const args = (env) => ({
  environment: env,
  streaming: true,
  holdSeconds: 270,
  requirePublication: true,
  requireProcessing: true,
  liveProfile: '240p30',
});
for (const [profile, milliseconds] of [
  ['strict1500-v1', 1500],
  ['broadcast-reliability2000-v1', 2000],
  ['broadcast-reliability3000-v1', 3000],
  ['broadcast-reliability6000-v1', 6000],
]) {
  test(`${profile} composes complete owned route with exact independent peer latency`, () => {
    for (const peer of ['400', '700', '1000']) {
      const env = {
        ...environment(),
        SCOREBUG_TEST_TIMING_PROFILE: profile,
        SCOREBUG_TEST_DELIVERY_DEADLINE_MS: String(milliseconds),
        SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: peer,
      };
      assert.equal(nativeCapacityRecovery(args(env)), true);
      assert.equal(nativeFileFixtureOptions(args(env)).minimumDurationSeconds, 360);
      assert.equal(nativeMeasuredTrial(args(env)), true);
      assert.equal(
        fixtureDeliveryDeadline({ environment: env, decoderStall: false, measuredTrial: true }),
        milliseconds / 1000,
      );
    }
  });
  test(`${profile} rejects missing prerequisites and seconds or malformed milliseconds`, () => {
    const env = {
      ...environment(),
      SCOREBUG_TEST_TIMING_PROFILE: profile,
      SCOREBUG_TEST_DELIVERY_DEADLINE_MS: String(milliseconds),
    };
    for (const key of Object.keys(environment()))
      assert.throws(() => nativeCapacityRecovery(args({ ...env, [key]: undefined })), key);
    for (const raw of [
      String(milliseconds / 1000),
      `${milliseconds}.0`,
      `0${milliseconds}`,
      ` ${milliseconds}`,
      milliseconds,
      '1000',
    ])
      assert.throws(() =>
        nativeCapacityRecovery(args({ ...env, SCOREBUG_TEST_DELIVERY_DEADLINE_MS: raw })),
      );
  });
}
test('unknown and partial timing selections never silently fall through legacy routes', () => {
  for (const value of ['unknown', '', null, 2000, ' broadcast-reliability2000-v1'])
    assert.throws(() =>
      nativeCapacityRecovery(args({ ...environment(), SCOREBUG_TEST_TIMING_PROFILE: value })),
    );
  for (const profile of [
    'strict1500-v1',
    'broadcast-reliability2000-v1',
    'broadcast-reliability3000-v1',
  ])
    assert.throws(() => nativeCapacityRecovery(args({ SCOREBUG_TEST_TIMING_PROFILE: profile })));
  assert.equal(nativeCapacityRecovery(args(environment())), true);
});

test('host and native contracts share one exact versioned table and remain immutable', async () => {
  const { readFile } = await import('node:fs/promises');
  const { timingContracts } = await import('../native-timing-contract.mjs');
  const table = JSON.parse(
    await readFile(
      new URL(
        '../../ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/streaming-timing-contracts.json',
        import.meta.url,
      ),
    ),
  );
  assert.deepEqual(Object.values(timingContracts), table);
  for (const contract of Object.values(timingContracts)) {
    assert.throws(() => {
      contract.decoderBudgetMs = 10000;
    });
  }
});
test('timing metadata requires trusted selection and rejects missing, mixed, altered and relabelled legacy evidence', async () => {
  const { qualifyTimingContract, timingContracts } = await import('../native-timing-contract.mjs');
  const strict = 'strict1500-v1';
  assert.equal(qualifyTimingContract({}), timingContracts[strict]);
  for (const profile of Object.keys(timingContracts).filter((p) => p !== strict)) {
    const contract = timingContracts[profile];
    assert.equal(
      qualifyTimingContract({ timingContract: structuredClone(contract) }, profile),
      contract,
    );
    assert.throws(() => qualifyTimingContract({}, profile));
    assert.throws(() => qualifyTimingContract({ timingContract: contract }));
    for (const key of Object.keys(contract)) {
      const changed = structuredClone(contract);
      delete changed[key];
      assert.throws(() => qualifyTimingContract({ timingContract: changed }, profile));
      changed[key] = typeof contract[key] === 'number' ? contract[key] / 1000 : 'invalid';
      assert.throws(() => qualifyTimingContract({ timingContract: changed }, profile));
    }
    for (const other of Object.keys(timingContracts).filter((p) => p !== profile))
      assert.throws(() =>
        qualifyTimingContract({ timingContract: timingContracts[other] }, profile),
      );
    assert.throws(() =>
      qualifyTimingContract({ timingContract: { ...contract, unknown: 1 } }, profile),
    );
  }
});
