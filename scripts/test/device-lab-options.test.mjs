import test from 'node:test';
import assert from 'node:assert/strict';
import { deviceLabOptions, deviceLabRelayArgs } from '../device-lab.mjs';

const interfaces = { en0: [{ address: '192.168.1.130', family: 'IPv4', internal: false }] };
test('explicit publishing recovery budget is bounded and default remains unset', async () => {
  const module = await import('../device-lab.mjs');
  const base = ['--host', '192.168.1.130'];
  for (const milliseconds of [120, 700, 2000]) {
    assert.equal(
      deviceLabOptions([...base, '--publish-peer-latency-ms', String(milliseconds)], interfaces)
        .publishPeerLatencyMs,
      milliseconds,
    );
  }
  assert.equal(deviceLabOptions(base, interfaces).publishPeerLatencyMs, undefined);
  for (const value of ['119', '2001', '700.1', '0700', '7e2', 'NaN', '']) {
    assert.throws(() =>
      deviceLabOptions([...base, '--publish-peer-latency-ms', value], interfaces),
    );
  }
  assert.equal(typeof module.deviceLabPublishEnvironment, 'function');
  assert.deepEqual(module.deviceLabPublishEnvironment(undefined), {
    SRT_PUBLISH_PEER_LATENCY_MS: undefined,
    SRT_PUBLISH_PACING: undefined,
  });
  assert.deepEqual(module.deviceLabPublishEnvironment(700), {
    SRT_PUBLISH_PEER_LATENCY_MS: '700',
    SRT_PUBLISH_PACING: undefined,
  });
  for (const value of [null, '700', 119, 2001, NaN, {}, []]) {
    assert.throws(() => module.deviceLabPublishEnvironment(value));
    await assert.rejects(module.startDeviceLab({ publishPeerLatencyMs: value }), /recovery budget/);
  }
});
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
  for (const [body, grace, forced, initialSignal] of [
    ["process.on('SIGTERM',()=>setTimeout(()=>process.exit(0),100));", 1000, false],
    ["process.on('SIGTERM',()=>{});", 100, true],
    ["process.on('SIGTERM',()=>process.exit(0));", 1000, true, 'SIGKILL'],
  ]) {
    const child = spawn(
      process.execPath,
      ['-e', body + "setInterval(()=>{},1000);process.stdout.write('ready');"],
      { stdio: ['ignore', 'pipe', 'ignore'] },
    );
    const closed = once(child, 'close').then(([code, signal]) => ({ code, signal }));
    try {
      await once(child.stdout, 'data');
      const result = await stopLabWorker(child, closed, grace, initialSignal);
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
    'scorebug/ingest:drain-v1',
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

test('physical recovery is API-only and derives all public endpoints from one validated host', async () => {
  const module = await import('../device-lab.mjs');
  assert.equal(typeof module.deviceLabRecoveryBind, 'function');
  for (const publisherRecovery of [undefined, false, true]) {
    for (const physicalRecovery of [undefined, false])
      assert.equal(
        module.deviceLabRecoveryBind({ publisherRecovery, physicalRecovery }, interfaces),
        '127.0.0.1',
      );
  }
  assert.equal(
    module.deviceLabRecoveryBind(
      { publisherRecovery: true, physicalRecovery: true, host: '192.168.1.130' },
      interfaces,
    ),
    '192.168.1.130',
  );
  for (const physicalRecovery of [null, 'true', 1, {}, []]) {
    assert.throws(
      () => module.deviceLabRecoveryBind({ publisherRecovery: true, physicalRecovery }, interfaces),
      /physical recovery/i,
    );
    await assert.rejects(
      module.startDeviceLab({ publisherRecovery: true, physicalRecovery }),
      /physical recovery/i,
    );
  }
  for (const publisherRecovery of [undefined, false]) {
    assert.throws(
      () => module.deviceLabRecoveryBind({ publisherRecovery, physicalRecovery: true }, interfaces),
      /requires publisher/i,
    );
    await assert.rejects(
      module.startDeviceLab({ publisherRecovery, physicalRecovery: true }),
      /requires publisher/i,
    );
  }
  for (const host of ['127.0.0.1', '0.0.0.0', '192.168.1.131', '8.8.8.8', 'localhost'])
    assert.throws(() =>
      module.deviceLabRecoveryBind(
        { publisherRecovery: true, physicalRecovery: true, host },
        interfaces,
      ),
    );
  assert.throws(() =>
    deviceLabOptions(['--host', '192.168.1.130', '--physical-recovery', 'true'], interfaces),
  );
});

test('publishing pacing accepts only explicit relative and clears inherited pacing at the child boundary', async () => {
  const { deviceLabPublishEnvironment } = await import('../device-lab.mjs');
  const { execFileSync } = await import('node:child_process');
  const base = ['--host', '192.168.1.130'];
  assert.equal(Object.hasOwn(deviceLabOptions(base, interfaces), 'publishPacing'), false);
  assert.equal(
    deviceLabOptions([...base, '--publish-pacing', 'relative'], interfaces).publishPacing,
    'relative',
  );
  for (const latency of [undefined, 700]) {
    for (const pacing of [undefined, 'relative']) {
      const environment = deviceLabPublishEnvironment(latency, pacing);
      assert.deepEqual(environment, {
        SRT_PUBLISH_PEER_LATENCY_MS: latency === undefined ? undefined : '700',
        SRT_PUBLISH_PACING: pacing,
      });
      const inherited = {
        ...process.env,
        SRT_PUBLISH_PEER_LATENCY_MS: '2000',
        SRT_PUBLISH_PACING: 'relative',
      };
      const observed = JSON.parse(
        execFileSync(
          process.execPath,
          [
            '-e',
            'console.log(JSON.stringify({latency: process.env.SRT_PUBLISH_PEER_LATENCY_MS, pacing: process.env.SRT_PUBLISH_PACING}))',
          ],
          { env: { ...inherited, ...environment }, encoding: 'utf8' },
        ),
      );
      assert.deepEqual(observed, {
        ...(latency === undefined ? {} : { latency: '700' }),
        ...(pacing === undefined ? {} : { pacing: 'relative' }),
      });
    }
  }
});

test('publishing pacing rejects malformed CLI options and API values before allocation', async () => {
  const { deviceLabPublishEnvironment, startDeviceLab } = await import('../device-lab.mjs');
  const base = ['--host', '192.168.1.130'];
  for (const value of [
    '',
    'RELATIVE',
    'Relative',
    ' relative',
    'relative ',
    'relative\n',
    'absolute',
    '0',
  ]) {
    assert.throws(() => deviceLabOptions([...base, '--publish-pacing', value], interfaces));
  }
  assert.throws(() => deviceLabOptions([...base, '--publish-pacing'], interfaces));
  assert.throws(() =>
    deviceLabOptions(
      [...base, '--publish-pacing', 'relative', '--publish-pacing', 'relative'],
      interfaces,
    ),
  );
  for (const value of [
    null,
    false,
    true,
    0,
    1,
    NaN,
    {},
    [],
    ['relative'],
    new String('relative'),
    '',
    'RELATIVE',
    ' relative',
    'relative ',
    'relative\n',
    'absolute',
  ]) {
    assert.throws(() => deviceLabPublishEnvironment(undefined, value), /pacing/i);
    await assert.rejects(startDeviceLab({ publishPacing: value }), /pacing/i);
  }
  assert.throws(() => deviceLabPublishEnvironment('700', 'relative'), /recovery budget/);
  await assert.rejects(
    startDeviceLab({ publishPeerLatencyMs: '700', publishPacing: 'relative' }),
    /recovery budget/,
  );
});

test('container lane preserves credentials/routes while mapping host loopback and mounted paths', async () => {
  const { containerLabEnvironment, validateWorkerImage } =
    await import('../container-lab-worker.mjs');
  const input = {
    ENCODER: 'software',
    CONTROL_PLANE_URL: 'http://127.0.0.1:9876',
    OUTPUT_URL: 'rtmp://localhost:5432/live/fixture?scope=local',
    HOME_TOKEN: 'fixture-secret',
    SCORE_DIR: '/private/lab/worker',
    OUTPUT_RECORDING_DIR: '/private/lab/outputs',
  };
  const result = containerLabEnvironment(input);
  assert.equal(result.CONTROL_PLANE_URL, 'http://host.docker.internal:9876/');
  assert.equal(result.OUTPUT_URL, 'rtmp://host.docker.internal:5432/live/fixture?scope=local');
  assert.equal(result.HOME_TOKEN, input.HOME_TOKEN);
  assert.equal(result.SCORE_DIR, '/scorebug/state');
  assert.equal(result.OUTPUT_RECORDING_DIR, '/scorebug/recordings');
  assert.equal(input.SCORE_DIR, '/private/lab/worker');
  assert.equal(
    containerLabEnvironment({ ...input, CONTROL_PLANE_URL: 'http://192.168.1.130:9876' })
      .CONTROL_PLANE_URL,
    'http://192.168.1.130:9876/',
  );
  assert.throws(() => containerLabEnvironment({ ...input, ENCODER: 'videotoolbox' }));
  for (const image of ['--privileged', '', 'bad\nimage', 'image with spaces'])
    assert.throws(() => validateWorkerImage(image));
  const opts = deviceLabOptions(
    ['--host', '192.168.1.130', '--worker-image', 'scorebug/home-daemon:local'],
    interfaces,
  );
  assert.equal(opts.workerImage, 'scorebug/home-daemon:local');
});
