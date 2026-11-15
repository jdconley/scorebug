import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import { cancellation } from './cancellation.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const args = process.argv.slice(2);
assert(args.length === 0 || (args.length === 2 && args[0] === '--image' && args[1]));
const suppliedImage = args[1];
const project = `scorebug-vps-qa-${randomUUID()}`;
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/vps-stack-'));
await chmod(artifact, 0o700);
const environment = {
  ...process.env,
  CADDY_DOMAIN: 'qa.invalid',
  INGEST_HOST: 'ingest.invalid',
  INGEST_PORT: '8890',
  CADDY_IMAGE: 'caddy:2-alpine',
  SCOREBUG_RELEASE: project,
  CORS_ORIGINS: 'https://localhost.invalid',
  ...Object.fromEntries(
    ['PHONE_TOKEN', 'HOME_TOKEN', 'INTERNAL_TOKEN', 'RELAY_API_PASSWORD'].map((key) => [
      key,
      randomBytes(32).toString('hex'),
    ]),
  ),
};
const checkCancellation = cancellation();
const exec = promisify(execFile);
const docker = (...argv) =>
  exec('docker', argv, {
    cwd: root,
    env: environment,
    timeout: 600000,
    maxBuffer: 8 * 1024 * 1024,
  });
const base = [
  'compose',
  '--project-name',
  project,
  '--env-file',
  '/dev/null',
  '-f',
  join(root, 'infra/vps/docker-compose.yml'),
];
const override = join(artifact, 'override.yml');
await writeFile(
  override,
  `services:\n  control-plane:\n${suppliedImage ? `    image: ${JSON.stringify(suppliedImage)}\n` : ''}    ports:\n      - '127.0.0.1::8787'\n  mediamtx:\n    ports: !override\n      - '127.0.0.1::8890/udp'\n      - '127.0.0.1::9997'\n`,
  { mode: 0o600 },
);
const compose = (...argv) => docker(...base, '-f', override, ...argv);
const evidence = {
  project,
  scope:
    'Local container deployment wiring and durable native API; no TLS, GPU, external host or media qualification',
  checks: {},
  passed: false,
};
async function until(fn) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    checkCancellation();
    try {
      if (await fn()) return;
    } catch {
      /* services may still be starting */
    }
    await delay(200);
  }
  throw new Error('Deployment service readiness timed out');
}
async function endpoint(service, port) {
  const { stdout } = await compose('port', service, String(port));
  assert.match(stdout.trim(), /^127\.0\.0\.1:\d+$/);
  return `http://${stdout.trim()}`;
}
let started = false;
try {
  const config = JSON.parse((await docker(...base, 'config', '--format', 'json')).stdout);
  assert(!config.services['control-plane'].ports?.length);
  assert(config.services.mediamtx.ports.every((p) => p.protocol === 'udp' && p.target === 8890));
  assert.equal(config.services.mediamtx.network_mode, undefined);
  evidence.checks.privateManagementPorts = true;
  if (!suppliedImage) {
    console.log('Building API image; reusing the maintained relay image.');
    const built = await compose('build', 'control-plane');
    await writeFile(join(artifact, 'build.log'), built.stdout + built.stderr, { mode: 0o600 });
  }
  checkCancellation();
  started = true;
  await compose('up', '-d', '--no-build', '--pull', 'never', 'control-plane');
  let api = await endpoint('control-plane', 8787);
  const relay = await endpoint('mediamtx', 9997);
  await until(
    async () => (await fetch(api + '/healthz', { signal: AbortSignal.timeout(2000) })).ok,
  );
  const relayAuth =
    'Basic ' + Buffer.from('scorebug-admin:' + environment.RELAY_API_PASSWORD).toString('base64');
  async function paths(auth = relayAuth) {
    const r = await fetch(relay + '/v3/config/paths/list', {
      headers: auth ? { authorization: auth } : {},
      signal: AbortSignal.timeout(3000),
    });
    if (!auth) {
      await r.arrayBuffer();
      return r.status;
    }
    assert.equal(r.status, 200);
    return (await r.json()).items.map((p) => p.name);
  }
  await until(async () => Array.isArray(await paths()));
  assert.equal(await paths(null), 401);
  assert.deepEqual(await paths(), []);
  evidence.checks.authenticatedRelayManagement = true;
  async function request(path, token, body) {
    checkCancellation();
    const r = await fetch(api + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(5000),
    });
    assert(r.ok, `Native request ${path}: HTTP ${r.status}`);
    return r.json();
  }
  const matchId = randomUUID(),
    token = environment.PHONE_TOKEN;
  const team = { name: 'QA', shortName: 'QA', color: '#123456' };
  await request('/v1/matches', token, {
    id: matchId,
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const joined = await request(`/v1/matches/${matchId}/join`, token, {
    deviceId: 'phone',
    role: 'capture',
  });
  await request(`/v1/matches/${matchId}/media/recordings`, joined.credential.token, {
    recordingId: 'archive',
    sequence: 0,
    status: 'recording',
    startedAt: new Date().toISOString(),
  });
  const startedBroadcast = await request(`/v1/matches/${matchId}/media/commands`, token, {
    commandId: 'start',
    gameId: matchId,
    expectedGeneration: 0,
    issuedAt: new Date().toISOString(),
    operation: {
      type: 'start',
      selection: {
        workerId: 'qa-worker',
        outputId: 'qa-output',
        captureDeviceId: 'phone',
        recordingId: 'archive',
      },
    },
  });
  assert.equal(startedBroadcast.accepted, true);
  const publish = () =>
    request(`/v1/matches/${matchId}/media/publish`, joined.credential.token, {
      recordingId: 'archive',
      generation: 1,
    });
  const access = await publish();
  await until(async () => (await paths()).length === 1);
  const beforePaths = await paths();
  assert.match(beforePaths[0], /^scorebug-[a-f0-9]{16}-[a-f0-9]{32}$/);
  evidence.checks.nativeRelayProvisioning = true;
  await compose(
    'up',
    '-d',
    '--no-deps',
    '--no-build',
    '--pull',
    'never',
    '--force-recreate',
    'control-plane',
  );
  api = await endpoint('control-plane', 8787);
  await until(
    async () => (await fetch(api + '/healthz', { signal: AbortSignal.timeout(2000) })).ok,
  );
  const restored = await publish();
  for (const key of ['gameId', 'generation', 'recordingId'])
    assert.equal(restored[key], access[key]);
  assert(
    restored.publishUrl === access.publishUrl,
    'Publishing grant changed after API recreation',
  );
  assert.deepEqual(await paths(), beforePaths);
  evidence.checks.containerRecreationPreservesMatchCredentialAndGrant = true;
  const stopped = await request(`/v1/matches/${matchId}/media/commands`, token, {
    commandId: 'stop',
    gameId: matchId,
    expectedGeneration: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'stop' },
  });
  assert.equal(stopped.accepted, true);
  await until(async () => (await paths()).length === 0);
  evidence.checks.stoppedBroadcastRemovesRelayPath = true;
  evidence.passed = true;
} catch (error) {
  evidence.error = String(error.message).replace(/passphrase=[^&\s'"]+/g, 'passphrase=REDACTED');
  process.exitCode = 1;
} finally {
  if (started) {
    try {
      await compose('down', '--volumes', '--remove-orphans');
      evidence.cleanedUp = true;
    } catch {
      evidence.cleanedUp = false;
      evidence.passed = false;
      process.exitCode = 1;
    }
  }
  if (!suppliedImage)
    await docker('image', 'rm', `scorebug/control-plane:${project}`).catch(() => {});
  await writeFile(join(artifact, 'result.json'), JSON.stringify(evidence, null, 2) + '\n', {
    mode: 0o600,
  });
}
console.log(JSON.stringify({ artifact, ...evidence }));
