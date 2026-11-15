import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import {
  separateScorerOptions,
  separateScorerEnvironment,
  separateScorerTests,
  recordScorerCaptureInventory,
} from '../test-separate-native-scorer.mjs';
const args = ['--device', '00008140-001474110C13001C', '--host', '192.168.1.130'];
const interfaces = { en0: [{ address: '192.168.1.130', family: 'IPv4', internal: false }] };
test('separate scorer requires physical camera and assigned LAN host with bounded defaults', () => {
  const options = separateScorerOptions(args, interfaces);
  assert.equal(options.duration, 900);
  assert.equal(options.team, 'B222J9J7B8');
  for (const bad of [
    [],
    [...args, '--lane', 'network-probe'],
    [...args, '--source', 'input.mov'],
    ['--device', 'simulator', '--host', '192.168.1.130'],
  ])
    assert.throws(() => separateScorerOptions(bad, interfaces));
});
test('role environments cannot enable fixture capture or recovery control and select exact native tests', () => {
  const lab = {
    setup: { endpoint: 'http://192.168.1.130:7777', installationToken: 'private-test-token' },
  };
  const camera = separateScorerEnvironment(lab, 'camera'),
    scorer = separateScorerEnvironment(lab, 'scorer');
  assert.deepEqual(Object.keys(camera).sort(), [
    'SCOREBUG_DEVICE_API_URL',
    'SCOREBUG_DEVICE_TOKEN',
    'SCOREBUG_PHYSICAL_SEPARATE_SCORER',
  ]);
  assert.deepEqual(Object.keys(scorer).sort(), [
    'SCOREBUG_DEVICE_API_URL',
    'SCOREBUG_DEVICE_TOKEN',
    'SCOREBUG_SEPARATE_NATIVE_SCORER',
  ]);
  assert.equal(camera.SCOREBUG_PHYSICAL_SEPARATE_SCORER, '1');
  assert.equal(scorer.SCOREBUG_SEPARATE_NATIVE_SCORER, '1');
  assert.match(separateScorerTests.camera, /testPhysicalIPhoneWhileSeparateNativePhoneScores$/);
  assert.match(separateScorerTests.scorer, /testSeparateNativeScorerWhileOtherPhonePublishes$/);
  assert.throws(() => separateScorerEnvironment(lab, 'watch'));
  for (const endpoint of [
    'http://127.0.0.1:7777',
    'http://3232235906:7777',
    'http://8.8.8.8:7777',
    'http://192.168.1.130:7777?token=x',
  ])
    assert.throws(() => separateScorerEnvironment({ setup: { ...lab.setup, endpoint } }, 'camera'));
});

test('capture violation inventory is retained before caller rejects the run', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'scorebug-scorer-inventory-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const recording = '11111111-2222-4333-8444-555555555555';
  await mkdir(join(root, 'Library/Application Support/Scorebug/Recordings', recording), {
    recursive: true,
  });
  const file = join(root, 'inventory.json');
  const result = await recordScorerCaptureInventory(root, file);
  assert.equal(result.noLocalRecordings, false);
  assert.deepEqual(JSON.parse(await readFile(file)), result);
  assert.deepEqual(result.recordingEntries, [recording]);
});
