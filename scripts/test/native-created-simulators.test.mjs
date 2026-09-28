import test from 'node:test';
import assert from 'node:assert/strict';
import { deviceLabSeedsMatch } from '../device-lab.mjs';
import {
  nativeCreatedOptions,
  nativeCreatedEnvironment,
  nativeCreatedTests,
  validateNativeCreation,
} from '../test-native-created-simulators.mjs';

const interfaces = { en0: [{ address: '192.168.1.130', family: 'IPv4', internal: false }] };
const args = ['--host', '192.168.1.130', '--source', '/private/input.mov'];
test('empty lab is explicit and simulator options exclude physical and recovery selectors', () => {
  assert.equal(deviceLabSeedsMatch(undefined), true);
  assert.equal(deviceLabSeedsMatch(true), true);
  assert.equal(deviceLabSeedsMatch(false), false);
  for (const value of [null, 0, '', 'false']) assert.throws(() => deviceLabSeedsMatch(value));
  assert.equal(nativeCreatedOptions(args, interfaces).source, '/private/input.mov');
  for (const extra of [
    ['--device', 'phone'],
    ['--lane', 'paired'],
    ['--publish-pacing', 'relative'],
    ['--source', '/other.mov'],
  ])
    assert.throws(() => nativeCreatedOptions([...args, ...extra], interfaces));
});
test('role environments only select simulator creation and camera fixture entry', () => {
  const lab = {
    setup: { endpoint: 'http://192.168.1.130:8080', installationToken: 'private-test-token' },
  };
  assert.deepEqual(nativeCreatedEnvironment(lab, 'camera'), {
    SCOREBUG_DEVICE_API_URL: lab.setup.endpoint,
    SCOREBUG_DEVICE_TOKEN: lab.setup.installationToken,
    SCOREBUG_ORDINARY_SIMULATOR: '1',
    SCOREBUG_NATIVE_CREATED_SIMULATOR: '1',
  });
  assert.deepEqual(nativeCreatedEnvironment(lab, 'scorer'), {
    SCOREBUG_DEVICE_API_URL: lab.setup.endpoint,
    SCOREBUG_DEVICE_TOKEN: lab.setup.installationToken,
    SCOREBUG_SEPARATE_NATIVE_SCORER: '1',
    SCOREBUG_NATIVE_CREATED_SIMULATOR: '1',
  });
  assert.match(nativeCreatedTests.camera, /testNativeCreatedSimulatorCameraWhileOtherPhoneScores$/);
  assert.match(nativeCreatedTests.scorer, /testSeparateNativeScorerWhileOtherPhonePublishes$/);
  assert.throws(() => nativeCreatedEnvironment(lab, 'watch'));
});
test('creation readback rejects seeds, extra matches, prior mutations and wrong initial owner', () => {
  const id = '10000000-0000-4000-8000-000000000001';
  const deviceId = '20000000-0000-4000-8000-000000000001';
  const creation = { id, deviceId, teams: { home: { name: 'HOME' }, away: { name: 'AWAY' } } };
  const match = {
    id,
    revision: 0,
    creationRequest: JSON.stringify(creation),
    scoring: { status: 'active', score: { home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0 } },
    scorer: { deviceId, epoch: 1 },
    broadcast: { desired: 'stopped', generation: 0 },
  };
  assert.deepEqual(validateNativeCreation([match]), {
    matchId: id,
    creatorDeviceId: deviceId,
    creationRequest: creation,
  });
  for (const rows of [
    [],
    [match, match],
    [{ ...match, revision: 1 }],
    [
      {
        ...match,
        creationRequest: JSON.stringify({ ...creation, deviceId: 'device-lab-bootstrap' }),
      },
    ],
    [{ ...match, creationRequest: JSON.stringify({ ...creation, id: deviceId }) }],
    [{ ...match, scorer: { deviceId: id, epoch: 1 } }],
    [{ ...match, broadcast: { desired: 'running', generation: 1 } }],
  ])
    assert.throws(() => validateNativeCreation(rows));
});

test('separate Watch lane is explicit, local-only, and preserves scorer/camera role separation', () => {
  assert.equal(
    nativeCreatedOptions([...args, '--watch', 'separate'], interfaces).separateWatch,
    true,
  );
  assert.throws(() => nativeCreatedOptions([...args, '--watch', 'paired'], interfaces));
  assert.throws(() =>
    nativeCreatedOptions([...args, '--watch', 'separate', '--watch', 'separate'], interfaces),
  );
  const lab = {
    setup: { endpoint: 'http://127.0.0.1:1234', installationToken: 'private-test-token' },
  };
  const camera = nativeCreatedEnvironment(lab, 'camera', true);
  const scorer = nativeCreatedEnvironment(lab, 'scorer', true);
  assert.equal(camera.SCOREBUG_SEPARATE_WATCH_SCORER, '1');
  assert.equal(camera.SCOREBUG_ORDINARY_SIMULATOR, '1');
  assert.equal(scorer.SCOREBUG_SEPARATE_NATIVE_SCORER, '1');
  assert.equal(scorer.SCOREBUG_ORDINARY_SIMULATOR, undefined);
  assert.throws(() => nativeCreatedEnvironment(lab, 'camera', false));
  assert.throws(() =>
    nativeCreatedEnvironment(
      { setup: { ...lab.setup, endpoint: 'https://example.com' } },
      'camera',
      true,
    ),
  );
});
