import test from 'node:test';
import assert from 'node:assert/strict';
import { deviceLabOptions, deviceLabRelayArgs } from '../device-lab.mjs';

const interfaces = { en0: [{ address: '192.168.1.130', family: 'IPv4', internal: false }] };
test('device lab requires an explicit assigned private LAN address', () => {
  for (const host of ['0.0.0.0', '127.0.0.1', '8.8.8.8', '192.168.1.131', 'localhost', '::1']) {
    assert.throws(() => deviceLabOptions(['--host', host], interfaces));
  }
  assert.throws(() => deviceLabOptions([], interfaces));
  assert.deepEqual(deviceLabOptions(['--host', '192.168.1.130'], interfaces), {
    host: '192.168.1.130',
    duration: 1800,
    encoder: 'software',
  });
});
test('device lab bounds duration and rejects ambiguous or unsupported options', () => {
  const base = ['--host', '192.168.1.130'];
  for (const args of [
    ['--duration', '0'],
    ['--duration', '7201'],
    ['--duration', '1.5'],
    ['--duration', 'NaN'],
    ['--encoder', 'other'],
    ['--unknown', 'value'],
    ['--host', '192.168.1.130'],
    ['--duration'],
  ]) {
    assert.throws(() => deviceLabOptions([...base, ...args], interfaces));
  }
  assert.deepEqual(
    deviceLabOptions([...base, '--duration', '10', '--encoder', 'videotoolbox'], interfaces),
    {
      host: '192.168.1.130',
      duration: 10,
      encoder: 'videotoolbox',
    },
  );
});

test('worker shutdown joins delayed graceful exit and distinguishes forced termination', async () => {
  const { spawn } = await import('node:child_process');
  const { once } = await import('node:events');
  const { stopLabWorker } = await import('../device-lab.mjs');
  for (const [body, grace, forced] of [
    ["process.on('SIGTERM',()=>setTimeout(()=>process.exit(0),100));", 1000, false],
    ["process.on('SIGTERM',()=>{});", 100, true],
  ]) {
    const child = spawn(
      process.execPath,
      ['-e', body + "setInterval(()=>{},1000);process.stdout.write('ready');"],
      { stdio: ['ignore', 'pipe', 'ignore'] },
    );
    const closed = once(child, 'close').then(([code, signal]) => ({ code, signal }));
    try {
      await once(child.stdout, 'data');
      const result = await stopLabWorker(child, closed, grace);
      assert.equal(result.forced, forced);
      assert.equal(result.signal, forced ? 'SIGKILL' : null);
      assert.equal(result.code, forced ? null : 0);
    } finally {
      child.kill('SIGKILL');
      await closed;
    }
  }
});

test('ordinary relay uses the maintained image with LAN media and private management', () => {
  const args = deviceLabRelayArgs({
    name: 'owned-lab-relay',
    host: '192.168.1.130',
    ingestPort: 18890,
    relayPort: 19997,
    configPath: '/private/lab/ingest.yml',
  });
  assert.deepEqual(args, [
    'run',
    '-d',
    '--name',
    'owned-lab-relay',
    '-p',
    '192.168.1.130:18890:8890/udp',
    '-p',
    '127.0.0.1:19997:9997',
    '-v',
    '/private/lab/ingest.yml:/mediamtx.yml:ro',
    'scorebug/ingest:campaign-probe-v3',
  ]);
});

test('API-only geometry diagnostics validate before allocation and clear inherited flags', async () => {
  const module = await import('../device-lab.mjs');
  assert.equal(typeof module.deviceLabDiagnosticEnvironment, 'function');
  for (const value of [undefined, false])
    assert.deepEqual(module.deviceLabDiagnosticEnvironment(value), {
      SCOREBUG_TEST_WORKER_TERMINAL: '',
      SCOREBUG_TEST_WORKER_PACKET_TIMING: '',
      SCOREBUG_TEST_WORKER_DECODED_GEOMETRY: '',
    });
  assert.deepEqual(module.deviceLabDiagnosticEnvironment(true), {
    SCOREBUG_TEST_WORKER_TERMINAL: '1',
    SCOREBUG_TEST_WORKER_PACKET_TIMING: '',
    SCOREBUG_TEST_WORKER_DECODED_GEOMETRY: '1',
  });
  for (const value of [null, '1', 1, {}, []]) {
    assert.throws(() => module.deviceLabDiagnosticEnvironment(value));
    await assert.rejects(module.startDeviceLab({ decodedGeometry: value }), /geometry/);
  }
  assert.throws(() =>
    deviceLabOptions(['--host', '192.168.1.130', '--decoded-geometry', 'true'], interfaces),
  );
});
