// Start a test broadcast against a running Scorebug server, the same way the
// phone app does, and print the SRT publish URL. Used to smoke-test an install
// (docs/self-hosting.md, "Test without a phone"). Needs Node 22.
//
//   node infra/smoke-broadcast.mjs start [setup-link]  -> prints the SRT publish URL
//   node infra/smoke-broadcast.mjs stop                -> ends the test broadcast
//
// Like a phone, it enrolls with a setup link: the one given, else one it mints
// with `docker compose exec` (as `infra/install.sh phone` does). `stop` revokes
// that test phone. The server picks the worker, as it does for the app. Reads
// CADDY_DOMAIN and HTTPS_PORT from infra/vps/.env. Set SCOREBUG_INSECURE_TLS=1
// for Caddy's private test CA.
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const envPath = new URL('./vps/.env', import.meta.url);
const statePath = new URL('./vps/.smoke-broadcast.json', import.meta.url);
const env = Object.fromEntries(
  readFileSync(envPath, 'utf8')
    .split('\n')
    .filter((line) => /^[A-Z_]+=/.test(line))
    .map((line) => {
      const at = line.indexOf('=');
      return [line.slice(0, at), line.slice(at + 1).replace(/^'(.*)'$/, '$1')];
    }),
);
if (process.env.SCOREBUG_INSECURE_TLS === '1') process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
const port = env.HTTPS_PORT && env.HTTPS_PORT !== '443' ? `:${env.HTTPS_PORT}` : '';
const api = process.env.SCOREBUG_API_URL ?? `https://${env.CADDY_DOMAIN}${port}`;

// body: undefined = GET, null = DELETE, else POST.
async function request(path, token, body) {
  const response = await fetch(api + path, {
    method: body === undefined ? 'GET' : body === null ? 'DELETE' : 'POST',
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      'content-type': 'application/json',
    },
    ...(body == null ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status} ${await response.text()}`);
  return response.json();
}

function mintSetupLink() {
  const dir = fileURLToPath(new URL('./vps', import.meta.url));
  const out = execFileSync(
    'docker',
    [
      'compose',
      '--project-directory',
      dir,
      '-f',
      `${dir}/docker-compose.yml`,
      '--env-file',
      `${dir}/.env`,
      'exec',
      '-T',
      'control-plane',
      'node',
      'apps/control-plane/dist/cli.js',
      'setup-link',
      '--server',
      api,
      '--hours',
      '1',
      '--qr',
      'none',
    ],
    { encoding: 'utf8' },
  );
  const link = out.split('\n').find((line) => line.startsWith('scorebug://connect?'));
  if (!link) throw new Error('could not mint a setup link; is the server running?');
  return link;
}

const command = process.argv[2];
if (command === 'start') {
  const code = new URL(process.argv[3] ?? mintSetupLink()).searchParams.get('code');
  const deviceId = randomUUID();
  const { token } = await request('/v1/setup/redeem', '', {
    code,
    deviceId,
    deviceName: 'Smoke test',
  });
  const matchId = randomUUID();
  const team = (name) => ({ name, shortName: name.slice(0, 4).toUpperCase(), color: '#1f6feb' });
  await request('/v1/matches', token, {
    id: matchId,
    deviceId: 'smoke-scorer',
    teams: { home: team('Home'), away: team('Away') },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const joined = await request(`/v1/matches/${matchId}/join`, token, {
    deviceId: 'smoke-phone',
    role: 'capture',
  });
  await request(`/v1/matches/${matchId}/media/recordings`, joined.credential.token, {
    recordingId: 'smoke',
    sequence: 0,
    status: 'recording',
    startedAt: new Date().toISOString(),
  });
  const started = await request(`/v1/matches/${matchId}/media/commands`, token, {
    commandId: randomUUID(),
    gameId: matchId,
    expectedGeneration: 0,
    issuedAt: new Date().toISOString(),
    operation: {
      type: 'start',
      selection: {
        captureDeviceId: 'smoke-phone',
        recordingId: 'smoke',
      },
    },
  });
  if (!started.accepted) throw new Error('broadcast start was not accepted');
  const access = await request(`/v1/matches/${matchId}/media/publish`, joined.credential.token, {
    recordingId: 'smoke',
    generation: 1,
  });
  writeFileSync(statePath, JSON.stringify({ matchId, deviceId, token }) + '\n', { mode: 0o600 });
  console.log(access.publishUrl);
} else if (command === 'stop') {
  const { matchId, deviceId, token } = JSON.parse(readFileSync(statePath, 'utf8'));
  const result = await request(`/v1/matches/${matchId}/media/commands`, token, {
    commandId: randomUUID(),
    gameId: matchId,
    expectedGeneration: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'stop' },
  });
  await request(`/v1/devices/${deviceId}`, token, null);
  rmSync(statePath, { force: true });
  console.log(result.accepted ? 'stopped' : 'stop not accepted');
} else {
  console.error('usage: node infra/smoke-broadcast.mjs start [setup-link] | stop');
  process.exit(2);
}
