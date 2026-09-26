import test from 'node:test';
import {mkdtemp, mkdir, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,dirname} from 'node:path';
import assert from 'node:assert/strict';
import {
  physicalRecoveryOptions,
  physicalRecoveryEnvironment,
  withPhysicalRecoveryLab,
  physicalRecoveryTest,
  readPhysicalRecoveryInputs,
  verifyPhysicalRecoveryInputs,
} from '../test-physical-recovery.mjs';
const device = '00008140-001474110C13001C';
const interfaces = { en0: [{ address: '192.168.1.130', family: 'IPv4', internal: false }] };
const args = ['--device', device, '--host', '192.168.1.130'];
test('physical recovery requires explicit hardware device and assigned private host', () => {
  const o = physicalRecoveryOptions(args, interfaces);
  assert.equal(o.device, device);
  assert.equal(o.publishPeerLatencyMs, 700);
  assert.equal(o.team, 'B222J9J7B8');
  assert.equal(o.encoder, 'software');
  assert.equal(o.duration, 900);
  for (const bad of [
    [],
    ['--device', device],
    ['--device', '5FD063FB-64F2-45D1-8500-8358C9AF5BA4', '--host', '192.168.1.130'],
    [...args, '--device', device],
    [...args, '--file', 'input.mov'],
    ['--device', device, '--host', '8.8.8.8'],
    ['--device', device, '--host', '192.168.1.131'],
    [...args, '--publish-peer-latency-ms', '0'],
    [...args, '--team', 'invalid'],
  ])
    assert.throws(() => physicalRecoveryOptions(bad, interfaces));
});
function lab() {
  return {
    setup: {
      endpoint: 'http://192.168.1.130:9999',
      installationToken: 'private-installation-token',
    },
    recoveryControl: {
      endpoint: 'http://192.168.1.130:7777',
      token: 'a'.repeat(64),
      runID: '11111111-2222-4333-8444-555555555555',
    },
  };
}
test('private physical environment contains only explicit camera recovery configuration', () => {
  const e = physicalRecoveryEnvironment(lab());
  assert.deepEqual(Object.keys(e).sort(), [
    'SCOREBUG_DEVICE_API_URL',
    'SCOREBUG_DEVICE_TOKEN',
    'SCOREBUG_PHYSICAL_RECOVERY_720',
    'SCOREBUG_RECOVERY_CONTROL_TOKEN',
    'SCOREBUG_RECOVERY_CONTROL_URL',
    'SCOREBUG_RECOVERY_RUN_ID',
  ]);
  assert.equal(e.SCOREBUG_PHYSICAL_RECOVERY_720, '1');
  assert.equal(e.SCOREBUG_RECOVERY_CONTROL_URL, 'http://192.168.1.130:7777');
  assert.match(
    physicalRecoveryTest,
    /PhysicalStreamingTests\/testPhysicalIPhoneRecover720ScoreStopAndExport$/,
  );
});
test('physical environment rejects loopback, foreign host and malformed controller', () => {
  for (const bad of [
    'http://127.0.0.1:7777',
    'http://192.168.1.131:7777',
    'http://192.168.1.130:7777?x=1',
    'http://192.168.1.130:7777/foreign',
    'http://user@192.168.1.130:7777',
  ]) {
    const l = lab();
    l.recoveryControl.endpoint = bad;
    assert.throws(() => physicalRecoveryEnvironment(l));
  }
  const l = lab();
  l.recoveryControl.token = 'bad';
  assert.throws(() => physicalRecoveryEnvironment(l));
});
test('lab remains live until the owned failing workflow joins, then stops exactly once', async () => {
  const events = [];
  let release;
  const gate = new Promise((r) => {
    release = r;
  });
  const work = withPhysicalRecoveryLab(
    async () => ({
      stop: async () => {
        events.push('stop');
      },
    }),
    async () => {
      events.push('running');
      await gate;
      events.push('joined');
      throw new Error('workflow failure');
    },
  );
  const rejected = assert.rejects(work, /workflow failure/);
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(events, ['running']);
  release();
  await rejected;
  assert.deepEqual(events, ['running', 'joined', 'stop']);
});
test('cleanup failure prevents success, and start failure does not invent a lab', async () => {
  await assert.rejects(
    withPhysicalRecoveryLab(
      async () => ({
        stop: async () => {
          throw new Error('cleanup failed');
        },
      }),
      async () => 42,
    ),
    /cleanup failed/,
  );
  let ran = false;
  await assert.rejects(
    withPhysicalRecoveryLab(
      async () => {
        throw new Error('start failed');
      },
      async () => {
        ran = true;
      },
    ),
    /start failed/,
  );
  assert.equal(ran, false);
});

test('rejects normalized or encoded host spellings in physical environment', () => {
  for (const url of [
    'http://3232235906:7777',
    'http://0xc0a80182:7777',
    'http://%31%39%32.168.1.130:7777',
  ]) {
    const value = lab();
    value.recoveryControl.endpoint = url;
    assert.throws(() => physicalRecoveryEnvironment(value));
  }
});

test('binds the actual Debug implementation image and rejects changes after execution', async t => {
  const products = await mkdtemp(join(tmpdir(), 'scorebug-physical-products-'));
  t.after(() => rm(products,{recursive:true,force:true}));
  const names = ['Debug-iphoneos/Scorebug.app/Scorebug', 'Debug-iphoneos/Scorebug.app/Scorebug.debug.dylib',
    'Debug-iphoneos/ScorebugAppUITests-Runner.app/ScorebugAppUITests-Runner',
    'Debug-iphoneos/ScorebugAppUITests-Runner.app/PlugIns/ScorebugAppUITests.xctest/ScorebugAppUITests',
    'Scorebug_iphoneos26.2-arm64.xctestrun'];
  for (const name of names) { const path=join(products,name); await mkdir(dirname(path),{recursive:true});await writeFile(path,name); }
  const extra=join(products,'private.xctestrun');await writeFile(extra,'configured private run');
  const inputs=await readPhysicalRecoveryInputs(products,[extra]);
  assert(inputs.some(i=>i.path.endsWith('/Scorebug.debug.dylib')));
  assert(inputs.some(i=>i.path===extra));
  await verifyPhysicalRecoveryInputs(inputs);
  await writeFile(join(products,names[1]),'changed implementation');
  await assert.rejects(verifyPhysicalRecoveryInputs(inputs),/changed/);
});
