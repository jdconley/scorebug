import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import { cancellation } from './cancellation.mjs';

import { startScoringTestServer, scoringTestToken } from './scoring-test-server.mjs';
const dir = await mkdtemp(join(tmpdir(), 'scorebug-recovery-'));
const checkCancellation = cancellation();
const token = scoringTestToken;
let processHandle;
async function stop() {
  if (!processHandle) return;
  const owned = processHandle;
  processHandle = undefined;
  await owned.stop();
}
async function start() {
  checkCancellation();
  processHandle = await startScoringTestServer(join(dir, 'match.sqlite'));
  checkCancellation();
  return processHandle.baseURL;
}
async function request(base, path, credential, body) {
  checkCancellation();
  const response = await fetch(`${base}${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(5000),
  });
  const result = await response.json();
  assert.equal(response.status, body && path === '/v1/matches' ? 201 : 200, JSON.stringify(result));
  return result;
}
try {
  let base = await start();
  const match = await request(base, '/v1/matches', token, {
    id: 'recovery-game',
    deviceId: 'phone-a',
    teams: {
      home: { name: 'Home', shortName: 'H', color: '#112233' },
      away: { name: 'Away', shortName: 'A', color: '#445566' },
    },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const command = {
    commandId: 'uncertain-point',
    gameId: match.snapshot.id,
    deviceId: 'phone-a',
    expectedRevision: 0,
    scorerEpoch: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'award_point', side: 'home' },
  };
  const applied = await request(
    base,
    '/v1/matches/recovery-game/commands',
    match.credential.token,
    command,
  );
  assert.equal(applied.snapshot.score.home, 1);
  await stop();
  base = await start();
  const recovered = await request(base, '/v1/matches/active', token);
  assert.equal(recovered.snapshot.id, 'recovery-game');
  assert.equal(recovered.snapshot.score.home, 1);
  const receipt = await request(
    base,
    '/v1/matches/recovery-game/commands/uncertain-point',
    match.credential.token,
  );
  assert.deepEqual(receipt, applied);
  const retried = await request(
    base,
    '/v1/matches/recovery-game/commands',
    match.credential.token,
    command,
  );
  assert.deepEqual(retried, applied);
  const joined = await request(base, '/v1/matches/recovery-game/join', token, {
    deviceId: 'watch-b',
    role: 'score',
  });
  const takeover = await request(
    base,
    '/v1/matches/recovery-game/commands',
    joined.credential.token,
    {
      ...command,
      commandId: 'takeover',
      deviceId: 'watch-b',
      expectedRevision: 1,
      issuedAt: new Date().toISOString(),
      operation: { type: 'take_over' },
    },
  );
  assert.equal(takeover.snapshot.scorer.deviceId, 'watch-b');
  await stop();
  base = await start();
  const final = await request(base, '/v1/matches/recovery-game', joined.credential.token);
  assert.equal(final.snapshot.scorer.deviceId, 'watch-b');
  assert.equal(final.snapshot.scorer.epoch, 2);
  assert.equal(final.snapshot.score.home, 1);
  checkCancellation();
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  await stop();
  await rm(dir, { recursive: true, force: true });
}
if (!process.exitCode)
  console.log(
    'PASS: real HTTP scoring survives two forced API process exits; credentials, score, takeover and exact command receipts recover.',
  );
