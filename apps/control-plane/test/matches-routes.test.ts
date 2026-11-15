import { afterEach, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { testConfig, phoneAuth } from './helpers.js';
const apps: ReturnType<typeof createApp>[] = [];
afterEach(() => {
  for (const item of apps.splice(0)) item.matches?.close();
});
const input = {
  id: 'native-game',
  deviceId: 'phone-a',
  teams: {
    home: { name: 'Home', shortName: 'H', color: '#112233' },
    away: { name: 'Away', shortName: 'A', color: '#445566' },
  },
  rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
};
function setup() {
  const config = testConfig();
  const value = createApp(config);
  apps.push(value);
  return { ...value, token: config.PHONE_TOKEN };
}
async function post(
  app: ReturnType<typeof createApp>['app'],
  path: string,
  body: unknown,
  token: string,
) {
  return app.request(path, {
    method: 'POST',
    headers: { ...phoneAuth(token), 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}
it('creates a camera-free match and discovers it without returning stream secrets', async () => {
  const { app, token } = setup();
  const response = await post(app, '/v1/matches', input, token);
  expect(response.status).toBe(201);
  const body = await response.json();
  expect(body.snapshot.score.home).toBe(0);
  expect(body.credential.role).toBe('score');
  expect(body.credential.token).toHaveLength(43);
  const active = await app.request('/v1/matches/active', { headers: phoneAuth(token) });
  expect(active.status).toBe(200);
  const text = await active.text();
  expect(text).toContain('native-game');
  expect(text).not.toMatch(/passphrase|youtubeStreamKey|token/);
});
it('binds commands to scoped device credentials and rejects capture-only scoring', async () => {
  const { app, token } = setup();
  const result = await (await post(app, '/v1/matches', input, token)).json();
  const cmd = {
    commandId: 'point-1',
    gameId: input.id,
    deviceId: input.deviceId,
    expectedRevision: 0,
    scorerEpoch: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'award_point', side: 'home' },
  };
  const forged = await post(
    app,
    '/v1/matches/native-game/commands',
    { ...cmd, deviceId: 'other' },
    result.credential.token,
  );
  expect(forged.status).toBe(403);
  const applied = await post(app, '/v1/matches/native-game/commands', cmd, result.credential.token);
  expect(applied.status).toBe(200);
  expect((await applied.json()).snapshot.score.home).toBe(1);
  const duplicate = await post(
    app,
    '/v1/matches/native-game/commands',
    cmd,
    result.credential.token,
  );
  expect((await duplicate.json()).snapshot.score.home).toBe(1);
  const capture = await (
    await post(app, '/v1/matches/native-game/join', { deviceId: 'camera', role: 'capture' }, token)
  ).json();
  expect(
    (
      await post(
        app,
        '/v1/matches/native-game/commands',
        { ...cmd, deviceId: 'camera' },
        capture.credential.token,
      )
    ).status,
  ).toBe(403);
  expect(
    (await app.request('/games/native-game', { headers: phoneAuth(result.credential.token) }))
      .status,
  ).toBe(401);
});
it('supports a second native scorer joining, taking over and querying its uncertain command', async () => {
  const { app, token } = setup();
  await post(app, '/v1/matches', input, token);
  const joined = await (
    await post(app, '/v1/matches/native-game/join', { deviceId: 'watch-b', role: 'score' }, token)
  ).json();
  const cmd = {
    commandId: 'takeover-1',
    gameId: input.id,
    deviceId: 'watch-b',
    expectedRevision: 0,
    scorerEpoch: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'take_over' },
  };
  const result = await post(app, '/v1/matches/native-game/commands', cmd, joined.credential.token);
  expect(result.status).toBe(200);
  const queried = await app.request('/v1/matches/native-game/commands/takeover-1', {
    headers: phoneAuth(joined.credential.token),
  });
  expect(queried.status).toBe(200);
  expect((await queried.json()).snapshot.scorer.deviceId).toBe('watch-b');
});
it('rejects invalid rules and missing bootstrap authorization', async () => {
  const { app, token } = setup();
  expect((await post(app, '/v1/matches', input, 'invalid')).status).toBe(401);
  expect(
    (await post(app, '/v1/matches', { ...input, rules: { ...input.rules, pointCap: 5 } }, token))
      .status,
  ).toBe(400);
});
it('keeps creation and join credentials stable when a response is lost and retried', async () => {
  const { app, token } = setup();
  const first = await (await post(app, '/v1/matches', input, token)).json();
  const retry = await (await post(app, '/v1/matches', input, token)).json();
  expect(retry.credential).toEqual(first.credential);
  expect(
    (await app.request('/v1/matches/native-game', { headers: phoneAuth(first.credential.token) }))
      .status,
  ).toBe(200);
  const joined = await (
    await post(app, '/v1/matches/native-game/join', { deviceId: 'watch-b', role: 'score' }, token)
  ).json();
  const joinRetry = await (
    await post(app, '/v1/matches/native-game/join', { deviceId: 'watch-b', role: 'score' }, token)
  ).json();
  expect(joinRetry.credential).toEqual(joined.credential);
});
it('rejects a match ID reserved for active-match discovery', async () => {
  const { app, token } = setup();
  expect((await post(app, '/v1/matches', { ...input, id: 'active' }, token)).status).toBe(400);
});
