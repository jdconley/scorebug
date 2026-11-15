// Start a test broadcast against a running Scorebug server, the same way the
// phone app does, and print the SRT publish URL. Used to smoke-test an install
// (docs/self-hosting.md, "Test without a phone"). Needs Node 22.
//
//   node infra/smoke-broadcast.mjs start  -> prints the SRT publish URL
//   node infra/smoke-broadcast.mjs stop   -> ends the test broadcast
//
// Reads CADDY_DOMAIN, HTTPS_PORT, PHONE_TOKEN, WORKER_ID and OUTPUT_ID from
// infra/vps/.env. Set SCOREBUG_INSECURE_TLS=1 for Caddy's private test CA.
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, rmSync } from 'node:fs';

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

async function request(path, token, body) {
  const response = await fetch(api + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status} ${await response.text()}`);
  return response.json();
}

const command = process.argv[2];
if (command === 'start') {
  const matchId = randomUUID();
  const token = env.PHONE_TOKEN;
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
        workerId: env.WORKER_ID,
        outputId: env.OUTPUT_ID,
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
  writeFileSync(statePath, JSON.stringify({ matchId }) + '\n', { mode: 0o600 });
  console.log(access.publishUrl);
} else if (command === 'stop') {
  const { matchId } = JSON.parse(readFileSync(statePath, 'utf8'));
  const result = await request(`/v1/matches/${matchId}/media/commands`, env.PHONE_TOKEN, {
    commandId: randomUUID(),
    gameId: matchId,
    expectedGeneration: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'stop' },
  });
  rmSync(statePath, { force: true });
  console.log(result.accepted ? 'stopped' : 'stop not accepted');
} else {
  console.error('usage: node infra/smoke-broadcast.mjs start|stop');
  process.exit(2);
}
