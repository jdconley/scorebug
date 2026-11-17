import { afterEach, describe, expect, it } from 'vitest';
import { createTestApp, MEMBER_TOKEN, phoneAuth } from './helpers.js';
import type { MatchStore } from '../src/matches-store.js';
import type { RouteConfig } from '../src/config.js';
const stores: MatchStore[] = [];
afterEach(() => stores.splice(0).forEach((store) => store.close()));
async function fixture(overrides: Partial<RouteConfig> = {}) {
  const { app, matches, config } = createTestApp({ config: overrides });
  stores.push(matches);
  const owner = MEMBER_TOKEN;
  const team = { name: 'Team', shortName: 'T', color: '#123456' };
  const request = async (path: string, token: string, body?: unknown) =>
    app.request(path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { ...phoneAuth(token), 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  const created = await request('/v1/matches', owner, {
    id: 'match',
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const scorer = (await created.json()).credential;
  const joined = await request('/v1/matches/match/join', owner, {
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
      selection: { captureDeviceId: 'phone', recordingId: 'archive' },
    },
  };
  return { app, config, matches, owner, request, scorer, capture, report, command };
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
it('reserves broadcast mutation and receipts for team members', async () => {
  const f = await fixture();
  await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  expect(
    (await f.request('/v1/matches/match/media/commands', f.scorer.token, f.command)).status,
  ).toBe(401);
  expect(
    (await f.request('/v1/matches/match/media/commands', f.capture.token, f.command)).status,
  ).toBe(401);
  const response = await f.request('/v1/matches/match/media/commands', f.owner, f.command);
  expect(response.status).toBe(200);
  const outcome = await response.json();
  expect(outcome.snapshot.broadcast).toMatchObject({ desired: 'running', generation: 1 });
  expect(
    await (await f.request('/v1/matches/match/media/commands', f.owner, f.command)).json(),
  ).toEqual(outcome);
  expect(await (await f.request('/v1/matches/match/media/commands/start', f.owner)).json()).toEqual(
    outcome,
  );
  expect((await f.request('/v1/matches/match/media/commands/start', f.scorer.token)).status).toBe(
    401,
  );
  expect((await f.request('/v1/matches/match/media/commands/missing', f.owner)).status).toBe(404);
});
it('checks route identity, generation, and expired broadcast commands', async () => {
  const f = await fixture();
  await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  expect(
    (
      await f.request('/v1/matches/match/media/commands', f.owner, {
        ...f.command,
        gameId: 'other',
      })
    ).status,
  ).toBe(403);
  const stale = await f.request('/v1/matches/match/media/commands', f.owner, {
    ...f.command,
    expectedGeneration: 1,
  });
  expect(stale.status).toBe(409);
  expect((await stale.json()).error).toBe('generation_conflict');
  const expired = await f.request('/v1/matches/match/media/commands', f.owner, {
    ...f.command,
    commandId: 'old',
    issuedAt: new Date(Date.now() - 30_000).toISOString(),
  });
  expect((await expired.json()).error).toBe('command_expired');
});
it('gives the selected worker current match state on late attachment and stops assignment on end', async () => {
  const f = await fixture();
  await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  await f.request('/v1/matches/match/media/commands', f.owner, f.command);
  expect((await f.request('/v1/worker/snapshot?workerId=match', f.scorer.token)).status).toBe(401);
  expect((await f.request('/v1/worker/snapshot', f.config.workerToken)).status).toBe(400);
  const selected = await (
    await f.request('/v1/worker/snapshot?workerId=match', f.config.workerToken)
  ).json();
  expect(selected.assignment.match.id).toBe('match');
  expect(selected.assignment.media.broadcast.selection.outputId).toBe('youtube');
  expect(selected.assignment.output).toEqual({ publishUrl: expect.stringMatching(/^rtmps:/) });
  expect(
    (await (await f.request('/v1/worker/snapshot?workerId=other', f.config.workerToken)).json())
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
    await f.request('/v1/worker/snapshot?workerId=match', f.config.workerToken)
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
    (await (await f.request('/v1/worker/snapshot?workerId=match', f.config.workerToken)).json())
      .assignment,
  ).toBeNull();
  expect(f.matches.media.get('match').recordings[0]?.status).toBe('recording');
});

it('fills in the configured worker and output and refuses a selection that names them', async () => {
  const f = await fixture({ workerId: 'garage', outputId: 'youtube-2' });
  await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  const named = {
    ...f.command,
    operation: {
      type: 'start',
      selection: { ...f.command.operation.selection, workerId: 'other' },
    },
  };
  expect((await f.request('/v1/matches/match/media/commands', f.owner, named)).status).toBe(400);
  const outcome = await (
    await f.request('/v1/matches/match/media/commands', f.owner, f.command)
  ).json();
  expect(outcome.snapshot.broadcast.selection).toEqual({
    workerId: 'garage',
    outputId: 'youtube-2',
    captureDeviceId: 'phone',
    recordingId: 'archive',
  });
});
it('requires the publishing attempt and echoes it with the publish URL', async () => {
  const f = await fixture();
  await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
  await f.request('/v1/matches/match/media/commands', f.owner, f.command);
  const attempt = '0a1b2c3d-0000-4000-8000-000000000001';
  const publish = (body: unknown) =>
    f.request('/v1/matches/match/media/publish', f.capture.token, body);
  const request = { recordingId: 'archive', generation: 1 };
  expect((await publish(request)).status).toBe(400);
  expect((await publish({ ...request, publishingAttemptId: attempt.toUpperCase() })).status).toBe(
    400,
  );
  const granted = await publish({ ...request, publishingAttemptId: attempt });
  expect(granted.status).toBe(200);
  expect(await granted.json()).toMatchObject({
    gameId: 'match',
    generation: 1,
    recordingId: 'archive',
    publishingAttemptId: attempt,
  });
});
