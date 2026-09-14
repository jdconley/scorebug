import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startScoringTestServer, scoringTestToken } from './scoring-test-server.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const runtime = process.env.SCOREBUG_WATCH_RUNTIME ?? '10.5';
const deviceType = process.env.SCOREBUG_WATCH_DEVICE_TYPE ?? 'Apple-Watch-Series-7-41mm';
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/native-watch-'));
let simulator,
  api,
  active,
  interrupted = false;
for (const signal of ['SIGINT', 'SIGTERM'])
  process.on(signal, () => {
    interrupted = true;
    if (active?.pid) {
      try {
        process.kill(-active.pid, 'SIGKILL');
      } catch {}
    }
  });
async function run(binary, args, name, { timeout = 120_000, env = {}, cleanup = false } = {}) {
  if (interrupted && !cleanup) throw new Error('Watch test interrupted');
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      cwd: root,
      env: { ...process.env, ...env },
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    active = child;
    let output = '';
    child.stdout.on('data', (data) => {
      output += data;
    });
    child.stderr.on('data', (data) => {
      output += data;
    });
    const timer = setTimeout(() => {
      try {
        process.kill(-child.pid, 'SIGKILL');
      } catch {}
    }, timeout);
    child.once('error', (error) => {
      clearTimeout(timer);
      active = undefined;
      reject(error);
    });
    child.once('close', async (code) => {
      clearTimeout(timer);
      active = undefined;
      try {
        await writeFile(join(artifact, `${name}.log`), output);
        if (code !== 0) throw new Error(`${name} failed (${code}); ${artifact}/${name}.log`);
        resolve(output.trim());
      } catch (error) {
        reject(error);
      }
    });
  });
}
try {
  simulator = await run(
    'xcrun',
    [
      'simctl',
      'create',
      `Scorebug Watch QA ${randomUUID().slice(0, 8)}`,
      `com.apple.CoreSimulator.SimDeviceType.${deviceType}`,
      `com.apple.CoreSimulator.SimRuntime.watchOS-${runtime.replaceAll('.', '-')}`,
    ],
    'create',
  );
  await run('xcrun', ['simctl', 'boot', simulator], 'boot');
  await run('xcrun', ['simctl', 'bootstatus', simulator, '-b'], 'bootstatus');
  api = await startScoringTestServer(join(artifact, 'matches.sqlite'));
  async function request(path, body) {
    const response = await fetch(`${api.baseURL}${path}`, {
      method: body ? 'POST' : 'GET',
      headers: { authorization: `Bearer ${scoringTestToken}`, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(10_000),
    });
    assert.ok(response.ok, `${path}: ${response.status}`);
    return response.json();
  }
  const gameId = randomUUID(),
    deviceId = randomUUID();
  const team = (name) => ({ name, shortName: name.toUpperCase(), color: '#123456' });
  const created = await request('/v1/matches', {
    id: gameId,
    deviceId: 'fixture-phone',
    teams: { home: team('Home'), away: team('Away') },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const offer = await request(`/v1/matches/${gameId}/watch-pairings`, {
    pairingId: randomUUID(),
    watchDeviceId: deviceId,
  });
  const envelope = { version: 1, endpoint: api.baseURL, offer };
  await run('xcodegen', ['generate', '--spec', 'ios/Project.yml'], 'generate');
  await run(
    'xcodebuild',
    [
      '-project',
      'ios/Scorebug.xcodeproj',
      '-scheme',
      'ScorebugWatch',
      '-destination',
      `platform=watchOS Simulator,id=${simulator}`,
      '-derivedDataPath',
      join(artifact, 'DerivedData'),
      '-resultBundlePath',
      join(artifact, 'Watch.xcresult'),
      '-parallel-testing-enabled',
      'NO',
      '-only-testing:ScorebugWatchUITests/NativeWatchScoringTests/testNativePairScoreAndRecoverAfterRelaunch',
      'test',
    ],
    'test',
    { timeout: 360_000, env: { SCOREBUG_TEST_WATCH_SETUP: JSON.stringify(envelope) } },
  );
  const finalResponse = await fetch(`${api.baseURL}/v1/matches/${gameId}`, {
    headers: { authorization: `Bearer ${created.credential.token}` },
    signal: AbortSignal.timeout(10_000),
  });
  assert.ok(finalResponse.ok, `Final snapshot: ${finalResponse.status}`);
  const final = await finalResponse.json();
  assert.equal(final.snapshot.status, 'ended');
  assert.equal(final.snapshot.scorer.deviceId, deviceId);
  assert.equal(final.snapshot.score.home, 0);
  assert.equal(final.snapshot.score.away, 1);
  const database = new DatabaseSync(join(artifact, 'matches.sqlite'), { readOnly: true });
  const outcomes = database
    .prepare('SELECT request, outcome FROM commands WHERE game_id = ? ORDER BY rowid')
    .all(gameId)
    .map((row) => ({ request: JSON.parse(row.request), outcome: JSON.parse(row.outcome) }));
  database.close();
  assert.deepEqual(
    outcomes.map((row) => row.request.operation.type),
    ['take_over', 'award_point', 'undo', 'end_set', 'award_point', 'end_match'],
  );
  assert.deepEqual(
    outcomes.map((row) => row.outcome.accepted),
    [true, true, true, false, true, true],
  );
  assert.ok(outcomes.every((row) => row.request.deviceId === deviceId));
  await writeFile(
    join(artifact, 'result.json'),
    JSON.stringify(
      {
        runtime,
        deviceType,
        snapshot: final.snapshot,
        outcomes,
        qualification:
          'Native Watch UI, simulator-injected setup, real Keychain and URLSession; no WatchConnectivity qualification',
      },
      null,
      2,
    ),
  );
  await run(
    'xcrun',
    [
      'xcresulttool',
      'export',
      'attachments',
      '--path',
      join(artifact, 'Watch.xcresult'),
      '--output-path',
      join(artifact, 'attachments'),
    ],
    'attachments',
  );
  console.log(`PASS: native Watch scoring and relaunch recovery. ${artifact}`);
} finally {
  if (api) await api.stop();
  if (simulator) {
    await run('xcrun', ['simctl', 'shutdown', simulator], 'shutdown', { cleanup: true }).catch(
      () => {},
    );
    await run('xcrun', ['simctl', 'delete', simulator], 'delete', { cleanup: true }).catch(
      () => {},
    );
  }
}
