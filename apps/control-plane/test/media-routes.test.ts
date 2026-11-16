import { afterEach, describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { ownerToken, testConfig, phoneAuth } from './helpers.js';
import type { MatchStore } from '../src/matches-store.js';
import type { Config } from '../src/config.js';
const stores: MatchStore[] = [];
afterEach(() => stores.splice(0).forEach((store) => store.close()));
async function fixture(overrides: Partial<Config> = {}) {
  const config = testConfig(overrides);
  const { app, matches } = createApp(config);
  stores.push(matches);
  const owner = ownerToken(matches);
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
      selection: {
        workerId: 'mac',
        outputId: 'local-sink',
        captureDeviceId: 'phone',
        recordingId: 'archive',
      },
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
it('reserves broadcast mutation and receipts for installation access', async () => {
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

describe('a start command without workerId/outputId', () => {
  type Fixture = Awaited<ReturnType<typeof fixture>>;
  const autoStart = (f: Fixture, commandId = 'auto') => ({
    ...f.command,
    commandId,
    issuedAt: new Date().toISOString(),
    operation: { type: 'start', selection: { captureDeviceId: 'phone', recordingId: 'archive' } },
  });
  const send = async (f: Fixture, body: unknown) =>
    (await f.request('/v1/matches/match/media/commands', f.owner, body)).json();
  const start = async (f: Fixture) => {
    await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
    return send(f, autoStart(f));
  };
  const register = (f: Fixture, workerId: string, outputId?: string) =>
    f.request('/v1/worker/sessions', f.config.HOME_TOKEN, {
      workerId,
      runId: `${workerId}-run`,
      ...(outputId ? { outputId } : {}),
    });

  it('goes to the one connected worker and the output it registered', async () => {
    const f = await fixture();
    expect((await register(f, 'home-1', 'youtube')).status).toBe(200);
    const outcome = await start(f);
    expect(outcome.accepted).toBe(true);
    expect(outcome.snapshot.broadcast.selection).toMatchObject({
      workerId: 'home-1',
      outputId: 'youtube',
    });
    const worker = await f.request('/v1/worker/snapshot?workerId=home-1', f.config.HOME_TOKEN);
    expect((await worker.json()).assignment.media.broadcast.generation).toBe(1);
  });

  it('prefers the configured WORKER_ID/OUTPUT_ID, even before that worker connects', async () => {
    const f = await fixture({ WORKER_ID: 'garage', OUTPUT_ID: 'youtube' });
    await register(f, 'other', 'elsewhere');
    const outcome = await start(f);
    expect(outcome.snapshot.broadcast.selection).toMatchObject({
      workerId: 'garage',
      outputId: 'youtube',
    });
  });

  it('refuses when no worker, several workers or no known output', async () => {
    const none = await fixture();
    expect(await start(none)).toMatchObject({ accepted: false, error: 'no_worker' });

    const many = await fixture();
    await register(many, 'a', 'out');
    await register(many, 'b', 'out');
    expect(await start(many)).toMatchObject({ accepted: false, error: 'worker_ambiguous' });

    // A worker from before outputId registration: polling alone names no output.
    const unknown = await fixture();
    await unknown.request('/v1/worker/snapshot?workerId=old', unknown.config.HOME_TOKEN);
    expect(await start(unknown)).toMatchObject({ accepted: false, error: 'output_unknown' });
  });

  it('replays the first outcome on retry even if the workers changed', async () => {
    const f = await fixture();
    await register(f, 'home-1', 'youtube');
    await f.request('/v1/matches/match/media/recordings', f.capture.token, f.report);
    const body = autoStart(f, 'retry');
    const first = await send(f, body);
    expect(first.accepted).toBe(true);
    await register(f, 'home-2', 'youtube');
    expect(await send(f, body)).toEqual(first);
  });
});
