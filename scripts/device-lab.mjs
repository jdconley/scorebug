import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { createSocket } from 'node:dgram';
import { createWriteStream } from 'node:fs';
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { createServer, isIPv4 } from 'node:net';
import { networkInterfaces } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { mediaTools } from './media-tools.mjs';
import { startScoringTestServer } from './scoring-test-server.mjs';
import { startReconnectingRTMPRecorder } from './reconnecting-rtmp-recorder.mjs';
import { createUDPImpairmentProxy } from './udp-impairment.mjs';
import { createUplinkEvidenceStopper } from './uplink-proxy-evidence.mjs';
import { startOrdinaryRecoveryControl } from './ordinary-recovery-control.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const execute = promisify(execFile);
export function deviceLabOptions(args, interfaces = networkInterfaces()) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index],
      value = args[index + 1];
    assert(
      ['--host', '--duration', '--encoder', '--publish-peer-latency-ms'].includes(key) &&
        value &&
        !values.has(key),
      'Invalid or duplicate lab option',
    );
    values.set(key, value);
  }
  const host = values.get('--host');
  assert(host && isIPv4(host), 'Supply --host with this Mac’s private LAN IPv4 address');
  const octets = host.split('.').map(Number);
  assert(
    octets[0] === 10 ||
      (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] === 192 && octets[1] === 168),
    'Lab host must be a private LAN address',
  );
  assert(
    Object.values(interfaces)
      .flat()
      .some((entry) => entry && !entry.internal && entry.address === host),
    'Lab host must be assigned to this machine',
  );
  const durationText = values.get('--duration') ?? '1800';
  const duration = Number(durationText);
  assert(/^[1-9][0-9]*$/.test(durationText) && duration <= 7200, 'Duration must be 1–7200 seconds');
  const encoder = values.get('--encoder') ?? 'software';
  assert(['software', 'videotoolbox'].includes(encoder), 'Unsupported lab encoder');
  const latencyText = values.get('--publish-peer-latency-ms');
  if (latencyText !== undefined)
    assert(/^[1-9][0-9]*$/.test(latencyText), 'Invalid publishing recovery budget');
  const publishPeerLatencyMs = latencyText === undefined ? undefined : Number(latencyText);
  deviceLabPublishEnvironment(publishPeerLatencyMs);
  return {
    host,
    duration,
    encoder,
    ...(publishPeerLatencyMs === undefined ? {} : { publishPeerLatencyMs }),
  };
}

/** Explicit server-side upload setting; never inherited from the calling shell. */
export function deviceLabPublishEnvironment(publishPeerLatencyMs) {
  assert(
    publishPeerLatencyMs === undefined ||
      (Number.isInteger(publishPeerLatencyMs) &&
        publishPeerLatencyMs >= 120 &&
        publishPeerLatencyMs <= 2000),
    'Invalid publishing recovery budget',
  );
  return {
    SRT_PUBLISH_PEER_LATENCY_MS:
      publishPeerLatencyMs === undefined ? undefined : String(publishPeerLatencyMs),
  };
}

/** Docker arguments for the ordinary local relay, with a loopback-only management API. */
export function deviceLabRelayArgs({ name, host, ingestPort, relayPort, configPath }) {
  return [
    'run',
    '-d',
    '--name',
    name,
    '-p',
    `${host}:${ingestPort}:8890/udp`,
    '-p',
    `127.0.0.1:${relayPort}:9997`,
    '-v',
    `${configPath}:/mediamtx.yml:ro`,
    'scorebug/ingest:campaign-probe-v3',
  ];
}

async function port(host, udp = false) {
  const socket = udp ? createSocket('udp4') : createServer();
  await new Promise((resolve, reject) => {
    socket.once('error', reject);
    if (udp) socket.bind(0, host, resolve);
    else socket.listen(0, host, resolve);
  });
  const assigned = socket.address().port;
  await new Promise((resolve, reject) =>
    socket.close((error) => (error ? reject(error) : resolve())),
  );
  return assigned;
}
function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
async function bounded(promise, ms) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Lab readiness timed out')), ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
/** Outer grace exceeds the production worker's one-second encoder grace. */
export async function stopLabWorker(child, closed, graceMs = 10000) {
  let forced = false;
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  try {
    await bounded(closed, graceMs);
  } catch {
    forced = true;
    child.kill('SIGKILL');
  }
  return { ...(await closed), forced };
}

function startWorker(environment, artifact) {
  const output = createWriteStream(join(artifact, 'worker.log'), { flags: 'wx', mode: 0o600 });
  const child = spawn(
    process.execPath,
    [
      '--import',
      './apps/home-daemon/node_modules/tsx/dist/loader.mjs',
      'apps/home-daemon/src/index.ts',
    ],
    {
      cwd: root,
      env: { ...process.env, ...environment },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  const closed = new Promise((resolve) =>
    child.once('close', (code, signal) => resolve({ code, signal })),
  );
  const ready = new Promise((resolve, reject) => {
    let partial = '';
    child.once('error', reject);
    child.once('close', () => reject(new Error('Lab worker exited before readiness')));
    output.once('error', reject);
    child.stdout.on('data', (chunk) => {
      partial += chunk.toString();
      const lines = partial.split('\n');
      partial = lines.pop() ?? '';
      for (const line of lines) {
        try {
          if (JSON.parse(line).msg === 'worker_processing_capability') resolve();
        } catch {}
      }
    });
  });
  ready.catch(() => {});
  child.stdout.pipe(output, { end: false });
  child.stderr.pipe(output, { end: false });
  let stopping;
  return {
    ready,
    closed,
    stop() {
      return (stopping ??= (async () => {
        const result = await stopLabWorker(child, closed);
        await new Promise((resolve) => output.end(resolve));
        return result;
      })());
    },
  };
}

/** API-only observer selection; no app or worker profile/timing controls. */
export function deviceLabDiagnosticEnvironment(decodedGeometry) {
  assert(
    decodedGeometry === undefined || typeof decodedGeometry === 'boolean',
    'Invalid decoded geometry selection',
  );
  return {
    SCOREBUG_TEST_WORKER_TERMINAL: decodedGeometry ? '1' : '',
    SCOREBUG_TEST_WORKER_PACKET_TIMING: '',
    SCOREBUG_TEST_WORKER_DECODED_GEOMETRY: decodedGeometry ? '1' : '',
  };
}

/** Owned development stack; media and credentials remain under one private artifact directory. */
export async function startDeviceLab(options, { signal } = {}) {
  signal?.throwIfAborted();
  const diagnosticEnvironment = deviceLabDiagnosticEnvironment(options.decodedGeometry);
  const publishEnvironment = deviceLabPublishEnvironment(options.publishPeerLatencyMs);
  assert(
    options.publisherRecovery === undefined || typeof options.publisherRecovery === 'boolean',
    'Invalid publisher recovery selection',
  );
  // Validate exported API callers too, before creating any processes or files.
  deviceLabOptions([
    '--host',
    options.host,
    '--duration',
    String(options.duration),
    '--encoder',
    options.encoder,
  ]);
  const parent = join(root, 'artifacts/qa');
  await mkdir(parent, { recursive: true });
  const artifact = await mkdtemp(join(parent, 'device-lab-'));
  await chmod(artifact, 0o700);
  const relayName = `scorebug-device-${randomUUID()}`;
  const secret = () => randomBytes(24).toString('hex');
  const phoneToken = secret(),
    homeToken = secret(),
    internalToken = secret(),
    relayPassword = secret();
  const { ffmpeg, ffprobe, font } = mediaTools();
  let api,
    recorder,
    worker,
    recoveryControl,
    stopUplink,
    relayStarted = false,
    stopping;
  async function stop() {
    return (stopping ??= (async () => {
      const failures = [];
      let workerExit = null,
        receiver = null;
      for (const [name, action] of [
        [
          'recovery-control',
          async () => {
            await recoveryControl?.stop();
          },
        ],
        [
          'worker',
          async () => {
            workerExit = (await worker?.stop()) ?? null;
            if (
              workerExit &&
              (workerExit.forced || workerExit.code !== 0 || workerExit.signal !== null)
            )
              throw new Error('Worker shutdown was not clean; descendant cleanup is unconfirmed');
          },
        ],
        [
          'receiver',
          async () => {
            receiver = await recorder?.finish();
          },
        ],
        [
          'api',
          async () => {
            await api?.stop();
          },
        ],
        [
          'publisher-uplink',
          async () => {
            await stopUplink?.();
          },
        ],
        [
          'relay',
          async () => {
            if (relayStarted) await execute('docker', ['rm', '-f', relayName], { timeout: 20000 });
          },
        ],
      ]) {
        try {
          await action();
        } catch {
          failures.push(name);
        }
      }
      await writeFile(
        join(artifact, 'shutdown.json'),
        JSON.stringify({ workerExit, receiver, failures, mediaQualified: false }, null, 2) + '\n',
        { flag: 'wx', mode: 0o600 },
      );
      if (failures.length) throw new Error(`Lab cleanup failed: ${failures.join(', ')}`);
    })());
  }
  try {
    const ingestPort = await port(options.host, true),
      relayPort = await port('127.0.0.1');
    const relayConfig = join(artifact, 'ingest.yml');
    await writeFile(
      relayConfig,
      `logLevel: warn\napi: true\napiAddress: :9997\nrtsp: false\nrtmp: false\nhls: false\nwebrtc: false\nmoq: false\nsrt: true\nsrtAddress: :8890\nauthInternalUsers:\n  - user: any\n    permissions:\n      - action: publish\n        path: '~^scorebug-[a-f0-9]{16}-[a-f0-9]{32}$'\n      - action: read\n        path: '~^scorebug-[a-f0-9]{16}-[a-f0-9]{32}$'\n  - user: lab-admin\n    pass: ${relayPassword}\n    permissions:\n      - action: api\npaths: {}\n`,
      { flag: 'wx', mode: 0o600 },
    );
    // Set before Docker returns: a timed-out start still needs owned-name cleanup.
    relayStarted = true;
    await execute(
      'docker',
      deviceLabRelayArgs({
        name: relayName,
        host: options.host,
        ingestPort,
        relayPort,
        configPath: relayConfig,
      }),
      { timeout: 30000 },
    );
    let relayReady = false;
    for (let attempt = 0; attempt < 40 && !relayReady; attempt++) {
      try {
        relayReady = (
          await fetch(`http://127.0.0.1:${relayPort}/v3/config/paths/list`, {
            headers: {
              authorization: `Basic ${Buffer.from(`lab-admin:${relayPassword}`).toString('base64')}`,
            },
            signal: AbortSignal.timeout(1000),
          })
        ).ok;
      } catch {}
      if (!relayReady) await wait(250);
    }
    assert(relayReady, 'Lab relay did not become ready');
    signal?.throwIfAborted();
    let publisherEnvironment = {};
    if (options.publisherRecovery) {
      const uplink = await createUDPImpairmentProxy({
        receiverHost: options.host,
        receiverPort: ingestPort,
        forward: { recordTimeline: true, recordRateLedger: true },
        reverse: { recordTimeline: true },
        forwardRateControl: { rateBitsPerSecond: 750000 },
      });
      stopUplink = createUplinkEvidenceStopper({
        uplink,
        artifact,
        capacityEvidencePolicy: 'rate-ledger-v1',
      });
      recoveryControl = await startOrdinaryRecoveryControl({ uplink, artifact });
      publisherEnvironment = {
        INGEST_PUBLISH_HOST: '127.0.0.1',
        INGEST_PUBLISH_PORT: String(uplink.port),
      };
    }
    recorder = await startReconnectingRTMPRecorder({ artifact, ffmpeg, port: 0 });
    api = await startScoringTestServer(join(artifact, 'scorebug.sqlite'), {
      HOST: options.host,
      PHONE_TOKEN: phoneToken,
      HOME_TOKEN: homeToken,
      INTERNAL_TOKEN: internalToken,
      INGEST_HOST: options.host,
      INGEST_PORT: String(ingestPort),
      ...publisherEnvironment,
      ...publishEnvironment,
      RELAY_API_URL: `http://127.0.0.1:${relayPort}`,
      RELAY_API_USERNAME: 'lab-admin',
      RELAY_API_PASSWORD: relayPassword,
    });
    signal?.throwIfAborted();
    const endpoint = new URL(api.baseURL);
    endpoint.hostname = options.host;
    const baseURL = endpoint.origin;
    const matchId = randomUUID(),
      team = (name) => ({ name, shortName: name, color: '#123456' });
    const response = await fetch(`${baseURL}/v1/matches`, {
      method: 'POST',
      headers: { authorization: `Bearer ${phoneToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        id: matchId,
        deviceId: 'device-lab-bootstrap',
        teams: { home: team('HOME'), away: team('AWAY') },
        rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
      }),
      signal: AbortSignal.timeout(5000),
    });
    assert.equal(response.status, 201, 'Lab match creation failed');
    await response.arrayBuffer();
    worker = startWorker(
      {
        CONTROL_PLANE_URL: baseURL,
        HOME_TOKEN: homeToken,
        WORKER_ID: 'mac',
        OUTPUT_ID: 'local-sink',
        OUTPUT_MODE: 'rtmp+record',
        OUTPUT_URL: recorder.url,
        OUTPUT_RECORDING_DIR: join(artifact, 'proxy-recordings'),
        ENCODER: options.encoder,
        DECODER_THREADING: 'automatic',
        VIDEO_PROFILE: '1080p30',
        SCORE_DIR: join(artifact, 'worker'),
        FFMPEG_PATH: ffmpeg,
        FFPROBE_PATH: ffprobe,
        FONT_PATH: font,
        LOG_LEVEL: 'info',
        WORKER_PROCESSING: 'auto',
        WORKER_REPORT_INTERVAL_MS: '100',
        ...diagnosticEnvironment,
      },
      artifact,
    );
    await bounded(worker.ready, 20000);
    signal?.throwIfAborted();
    const setup = {
      endpoint: baseURL,
      installationToken: phoneToken,
      workerId: 'mac',
      outputId: 'local-sink',
      matchId,
      artifact,
      encoder: options.encoder,
      durationSeconds: options.duration,
      ...(options.publishPeerLatencyMs === undefined
        ? {}
        : { requestedPublishPeerLatencyMs: options.publishPeerLatencyMs }),
      mediaQualified: false,
    };
    await writeFile(join(artifact, 'setup.json'), JSON.stringify(setup, null, 2) + '\n', {
      flag: 'wx',
      mode: 0o600,
    });
    return {
      artifact,
      setup,
      stop,
      workerClosed: worker.closed,
      ...(recoveryControl
        ? {
            recoveryControl: {
              endpoint: recoveryControl.endpoint,
              token: recoveryControl.token,
              runID: recoveryControl.runID,
            },
          }
        : {}),
    };
  } catch (error) {
    try {
      await stop();
    } catch (cleanup) {
      throw new AggregateError([error, cleanup], 'Lab startup and cleanup failed');
    }
    throw error;
  }
}

async function main() {
  const options = deviceLabOptions(process.argv.slice(2));
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', interrupt);
  let lab, timer;
  try {
    lab = await startDeviceLab(options, { signal: controller.signal });
    console.log(
      JSON.stringify({
        ready: true,
        endpoint: lab.setup.endpoint,
        artifact: lab.artifact,
        setupFile: join(lab.artifact, 'setup.json'),
        durationSeconds: options.duration,
      }),
    );
    const ended = new Promise((resolve) => {
      if (controller.signal.aborted) resolve('signal');
      else controller.signal.addEventListener('abort', () => resolve('signal'), { once: true });
      timer = setTimeout(() => resolve('duration'), options.duration * 1000);
    });
    const reason = await Promise.race([ended, lab.workerClosed.then(() => 'worker-exited')]);
    if (reason === 'worker-exited') throw new Error('Lab worker exited unexpectedly');
  } finally {
    clearTimeout(timer);
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
    await lab?.stop();
  }
  console.log(JSON.stringify({ stopped: true, artifact: lab.artifact }));
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
