import { afterEach, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { testConfig, phoneAuth } from './helpers.js';
import type { MatchStore } from '../src/matches-store.js';
const stores: MatchStore[] = [];
afterEach(() => stores.splice(0).forEach((store) => store.close()));
async function fixture() {
  const config = testConfig();
  const { app, matches } = createApp(config);
  stores.push(matches);
  const team = { name: 'Team', shortName: 'T', color: '#123456' };
  const request = async (path: string, token: string, body?: unknown) =>
    app.request(path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { ...phoneAuth(token), 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  const created = await request('/v1/matches', config.PHONE_TOKEN, {
    id: 'match',
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const scorer = (await created.json()).credential;
  const joined = await request('/v1/matches/match/join', config.PHONE_TOKEN, {
    deviceId: 'phone',
    role: 'capture',
  });
  const capture = (await joined.json()).credential;
  const issuedAt = new Date().toISOString();
  const report = { recordingId: 'archive', sequence: 0, status: 'recording', startedAt: issuedAt };
  const command = {
    commandId: 'start',
    gameId: 'match',
    expectedGeneration: 0,
    issuedAt,
    operation: {
      type: 'start',
      selection: {
        workerId: 'mac',
        outputId: 'local-sink',
        captureDeviceId: 'phone',
        recordingId: 'archive',
      },
    },
  };
  return { app, config, matches, request, scorer, capture, report, command };
}
it('requires scoped credentials for media reads and capture role for recording reports', async () => {
  const f = await fixture();
  expect((await f.request('/v1/matches/match/media', 'bad')).status).toBe(401);
  expect((await f.request('/v1/matches/match/media', f.scorer.token)).status).toBe(200);
  expect(
    (await f.request('/v1/matches/match/media/recordings', f.scorer.token, f.report)).status,
  ).toBe(403);
  const accepted = await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  expect(accepted.status).toBe(200);
  expect((await accepted.json()).recording.deviceId).toBe('phone');
  expect(
    (
      await f.request('/v1/matches/match/media/recordings', f.capture.token, {
        ...f.report,
        deviceId: 'spoof',
      })
    ).status,
  ).toBe(400);
  const publicState = await (await f.request('/v1/matches/match/media', f.scorer.token)).json();
  expect(publicState.snapshot.recordings).toHaveLength(1);
  expect(JSON.stringify(publicState)).not.toContain(f.capture.token);
});
it('reserves broadcast mutation and receipts for installation access', async () => {
  const f = await fixture();
  await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  expect(
    (await f.request('/v1/matches/match/media/commands', f.scorer.token, f.command)).status,
  ).toBe(401);
  expect(
    (await f.request('/v1/matches/match/media/commands', f.capture.token, f.command)).status,
  ).toBe(401);
  const response = await f.request(
    '/v1/matches/match/media/commands',
    f.config.PHONE_TOKEN,
    f.command,
  );
  expect(response.status).toBe(200);
  const outcome = await response.json();
  expect(outcome.snapshot.broadcast).toMatchObject({ desired: 'running', generation: 1 });
  expect(
    await (
      await f.request('/v1/matches/match/media/commands', f.config.PHONE_TOKEN, f.command)
    ).json(),
  ).toEqual(outcome);
  expect(
    await (await f.request('/v1/matches/match/media/commands/start', f.config.PHONE_TOKEN)).json(),
  ).toEqual(outcome);
  expect((await f.request('/v1/matches/match/media/commands/start', f.scorer.token)).status).toBe(
    401,
  );
  expect(
    (await f.request('/v1/matches/match/media/commands/missing', f.config.PHONE_TOKEN)).status,
  ).toBe(404);
});
it('checks route identity, generation, and expired broadcast commands', async () => {
  const f = await fixture();
  await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  expect(
    (
      await f.request('/v1/matches/match/media/commands', f.config.PHONE_TOKEN, {
        ...f.command,
        gameId: 'other',
      })
    ).status,
  ).toBe(403);
  const stale = await f.request('/v1/matches/match/media/commands', f.config.PHONE_TOKEN, {
    ...f.command,
    expectedGeneration: 1,
  });
  expect(stale.status).toBe(409);
  expect((await stale.json()).error).toBe('generation_conflict');
  const expired = await f.request('/v1/matches/match/media/commands', f.config.PHONE_TOKEN, {
    ...f.command,
    commandId: 'old',
    issuedAt: new Date(Date.now() - 30_000).toISOString(),
  });
  expect((await expired.json()).error).toBe('command_expired');
});
it('gives the selected worker current match state on late attachment and stops assignment on end', async () => {
  const f = await fixture();
  await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  await f.request('/v1/matches/match/media/commands', f.config.PHONE_TOKEN, f.command);
  expect((await f.request('/v1/worker/snapshot?workerId=mac', f.scorer.token)).status).toBe(401);
  expect((await f.request('/v1/worker/snapshot', f.config.HOME_TOKEN)).status).toBe(400);
  const selected = await (
    await f.request('/v1/worker/snapshot?workerId=mac', f.config.HOME_TOKEN)
  ).json();
  expect(selected.assignment.match.id).toBe('match');
  expect(selected.assignment.media.broadcast.selection.outputId).toBe('local-sink');
  expect(
    (await (await f.request('/v1/worker/snapshot?workerId=other', f.config.HOME_TOKEN)).json())
      .assignment,
  ).toBeNull();
  const issuedAt = new Date().toISOString();
  await f.request('/v1/matches/match/commands', f.scorer.token, {
    commandId: 'point',
    gameId: 'match',
    deviceId: 'scorer',
    expectedRevision: 1,
    scorerEpoch: 1,
    issuedAt,
    operation: { type: 'award_point', side: 'home' },
  });
  const refreshed = await (
    await f.request('/v1/worker/snapshot?workerId=mac', f.config.HOME_TOKEN)
  ).json();
  expect(refreshed.assignment.match.score.home).toBe(1);
  await f.request('/v1/matches/match/commands', f.scorer.token, {
    commandId: 'end',
    gameId: 'match',
    deviceId: 'scorer',
    expectedRevision: 2,
    scorerEpoch: 1,
    issuedAt,
    operation: { type: 'end_match', reason: 'Finished' },
  });
  expect(
    (await (await f.request('/v1/worker/snapshot?workerId=mac', f.config.HOME_TOKEN)).json())
      .assignment,
  ).toBeNull();
  expect(f.matches.media.get('match').recordings[0]?.status).toBe('recording');
});
