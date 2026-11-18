import { env, runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { beforeEach, expect, it, vi } from 'vitest';
import fixture from '../../../packages/protocol/fixtures/match-v1.json';
import type { TeamObject } from '../src/worker/team-object.js';
import { sweep } from '../src/worker/sweep.js';
import { mediaAdapters } from '../src/worker/media-adapters.js';
import { inputName } from '../src/worker/stream.js';
import { resetFakes, type Fakes } from './fake-media.js';
import { harness, invite, ownerWithTeam, type Harness } from './helpers.js';

type Json = Record<string, any>;
type Credential = { gameId: string; deviceId: string; role: string; token: string };
let h: Harness;
let fakes: Fakes;
beforeEach(() => {
  h = harness();
  fakes = resetFakes();
});

const team = (teamId: string) => env.TEAM.getByName(teamId);
const body = async (response: Response) => (await response.json()) as Json;

/** Connect flow: /connect → Google → callback → claim the ticket. */
async function connect(token: string, opts: { refreshToken?: string } = {}) {
  const started = await h.json('/v1/youtube/connect', {}, { headers: h.auth(token) });
  expect(started.status).toBe(200);
  const { url } = await body(started);
  const state = new URL(url).searchParams.get('state')!;
  const code = h.google.youtubeGrant(
    opts.refreshToken === undefined ? {} : { refreshToken: opts.refreshToken },
  );
  const callback = await h.call(`/v1/auth/google/callback?${new URLSearchParams({ code, state })}`);
  const redirect = new URL(callback.headers.get('location')!);
  const ticket = redirect.searchParams.get('ticket');
  const claimed = await h.json('/v1/youtube/connections', { ticket }, { headers: h.auth(token) });
  return { url: new URL(url), redirect, claimed };
}

/** An owner whose team streams to a connected channel. */
async function liveReadyTeam() {
  const owner = await ownerWithTeam(h);
  const { claimed } = await connect(owner.token, { refreshToken: 'refresh-owner' });
  const { connection } = await body(claimed);
  const set = await h.call(`/v1/teams/${owner.teamId}/youtube`, {
    method: 'PUT',
    headers: { ...h.auth(owner.token), 'content-type': 'application/json' },
    body: JSON.stringify({ connectionId: connection.id }),
  });
  expect(set.status).toBe(200);
  return { ...owner, connectionId: connection.id as string };
}

/** Creates the match, joins a capture phone and reports its recording. */
async function filming(owner: { token: string; teamId: string }, id = 'game-1') {
  const created = await h.json(
    `/v1/teams/${owner.teamId}/matches`,
    { ...fixture.creation, id, deviceId: 'score-phone' },
    { headers: h.auth(owner.token) },
  );
  expect(created.status).toBe(201);
  const scorer = (await body(created)).credential as Credential;
  const joined = await h.json(
    `/v1/teams/${owner.teamId}/matches/${id}/join`,
    { deviceId: 'camera-phone', role: 'capture' },
    { headers: h.auth(owner.token) },
  );
  const capture = (await body(joined)).credential as Credential;
  const report = await h.json(
    `/v1/matches/${id}/media/recordings`,
    { recordingId: 'rec-1', sequence: 0, status: 'recording', startedAt: new Date().toISOString() },
    { headers: h.auth(capture.token) },
  );
  expect(report.status).toBe(200);
  return { scorer, capture };
}

let commands = 0;
function media(
  owner: { token: string; teamId: string },
  operation: Json,
  expectedGeneration: number,
  id = 'game-1',
) {
  return h.json(
    `/v1/teams/${owner.teamId}/matches/${id}/media/commands`,
    {
      commandId: `media-${++commands}`,
      gameId: id,
      expectedGeneration,
      issuedAt: new Date().toISOString(),
      operation,
    },
    { headers: h.auth(owner.token) },
  );
}
const start = (owner: { token: string; teamId: string }, generation = 0, id = 'game-1') =>
  media(
    owner,
    { type: 'start', selection: { captureDeviceId: 'camera-phone', recordingId: 'rec-1' } },
    generation,
    id,
  );

const workerApi = (teamId: string, path: string, method = 'GET', payload = '') =>
  team(teamId).workerApi(method, path, 'Bearer outbound-intercept-only-not-a-secret', payload);

// ------------------------------------------------------------------- connections

it('connects a channel with incremental, offline consent on the existing redirect URI', async () => {
  const owner = await ownerWithTeam(h);
  const { url, redirect, claimed } = await connect(owner.token, { refreshToken: 'refresh-abc' });
  expect(url.searchParams.get('scope')).toBe('https://www.googleapis.com/auth/youtube');
  expect(url.searchParams.get('access_type')).toBe('offline');
  expect(url.searchParams.get('prompt')).toBe('select_account consent');
  expect(url.searchParams.get('redirect_uri')).toBe(
    'https://scorebug.live/v1/auth/google/callback',
  );
  expect(redirect.protocol).toBe('scorebug:');
  expect(redirect.searchParams.get('purpose')).toBe('youtube');
  expect(redirect.searchParams.get('status')).toBe('ok');
  expect(claimed.status).toBe(201);
  expect((await body(claimed)).connection).toMatchObject({
    channelId: 'UC-wildcats',
    channelTitle: 'Wildcats Volleyball',
    channelThumbnail: 'https://yt3.example/wildcats.jpg',
    status: 'ready',
  });
  expect(fakes.youtube.calls).toContain('createStream');
  const row = await env.DB.prepare('SELECT * FROM youtube_connections').first<Json>();
  expect(JSON.stringify(row)).not.toContain('refresh-abc');
  expect(JSON.stringify(row)).not.toContain('key-stream');
  const list = await h.call('/v1/youtube/connections', { headers: h.auth(owner.token) });
  expect((await body(list)).connections).toHaveLength(1);
});

it('only the person who started a connection can claim it, once', async () => {
  const owner = await ownerWithTeam(h);
  const other = await h.signIn('other@example.com');
  const started = await body(
    await h.json('/v1/youtube/connect', {}, { headers: h.auth(owner.token) }),
  );
  const state = new URL(started.url).searchParams.get('state')!;
  const code = h.google.youtubeGrant();
  const callback = await h.call(`/v1/auth/google/callback?${new URLSearchParams({ code, state })}`);
  const ticket = new URL(callback.headers.get('location')!).searchParams.get('ticket');
  const stolen = await h.json(
    '/v1/youtube/connections',
    { ticket },
    { headers: h.auth(other.token) },
  );
  expect(stolen.status).toBe(404);
  const mine = await h.json(
    '/v1/youtube/connections',
    { ticket },
    { headers: h.auth(owner.token) },
  );
  expect(mine.status).toBe(201);
  const again = await h.json(
    '/v1/youtube/connections',
    { ticket },
    { headers: h.auth(owner.token) },
  );
  expect(again.status).toBe(404);
});

it('reports a declined YouTube box and a cancelled consent to the app', async () => {
  const owner = await ownerWithTeam(h);
  const started = await body(
    await h.json('/v1/youtube/connect', {}, { headers: h.auth(owner.token) }),
  );
  const state = new URL(started.url).searchParams.get('state')!;
  const code = h.google.youtubeGrant({ youtube: false });
  const denied = await h.call(`/v1/auth/google/callback?${new URLSearchParams({ code, state })}`);
  expect(denied.headers.get('location')).toBe(
    'scorebug://auth?purpose=youtube&status=scope_denied',
  );
  const cancelled = await h.call(
    `/v1/auth/google/callback?${new URLSearchParams({ error: 'access_denied', state })}`,
  );
  expect(cancelled.headers.get('location')).toBe(
    'scorebug://auth?purpose=youtube&status=cancelled',
  );
});

it('flags a channel without live streaming at setup, and a re-check fixes it', async () => {
  const owner = await ownerWithTeam(h);
  fakes.youtube.liveEnabledNow = false;
  const { claimed } = await connect(owner.token);
  const { connection } = await body(claimed);
  expect(connection.status).toBe('live_disabled');
  expect(fakes.youtube.calls).not.toContain('createStream');
  fakes.youtube.liveEnabledNow = true;
  const checked = await h.json(
    `/v1/youtube/connections/${connection.id}/check`,
    {},
    { headers: h.auth(owner.token) },
  );
  expect((await body(checked)).connection.status).toBe('ready');
  expect(fakes.youtube.calls).toContain('createStream');
});

it('owners pick one of their own connections as the team channel; members see it', async () => {
  const owner = await liveReadyTeam();
  const { code } = await invite(h, owner.token, owner.teamId);
  const member = await h.signIn('parent@example.com', { invite: code });
  const view = await body(
    await h.call(`/v1/teams/${owner.teamId}`, { headers: h.auth(member.token) }),
  );
  expect(view.youtube).toEqual({
    connectionId: owner.connectionId,
    channelTitle: 'Wildcats Volleyball',
    channelThumbnail: 'https://yt3.example/wildcats.jpg',
    status: 'ready',
    connectedBy: owner.personId,
  });
  const put = (token: string, connectionId: string | null) =>
    h.call(`/v1/teams/${owner.teamId}/youtube`, {
      method: 'PUT',
      headers: { ...h.auth(token), 'content-type': 'application/json' },
      body: JSON.stringify({ connectionId }),
    });
  expect((await put(member.token, null)).status).toBe(403);
  const theirs = await body((await connect(member.token)).claimed);
  expect((await put(owner.token, theirs.connection.id)).status).toBe(404);
  const cleared = await put(owner.token, null);
  expect((await body(cleared)).youtube).toBeNull();
});

// ------------------------------------------------------------------------ Go Live

it('goes live: Stream input, one unlisted broadcast, the container, and the watch link', async () => {
  const owner = await liveReadyTeam();
  const { capture } = await filming(owner);
  // Opening the film screen (capture join) already made the match's Stream input.
  expect([...fakes.stream.inputs.values()].map((i) => i.name)).toEqual([
    inputName(owner.teamId, 'game-1'),
  ]);
  const live = await start(owner);
  expect(live.status).toBe(200);
  const outcome = await body(live);
  expect(outcome).toMatchObject({ accepted: true, error: null });
  const [broadcast] = [...fakes.youtube.broadcasts.values()];
  expect(broadcast!.title).toMatch(/^Spikers vs Diggers · [A-Z][a-z]{2} \d{1,2}$/);
  expect(broadcast!.boundTo).toMatch(/^stream-/);
  expect(outcome.youtube).toEqual({
    broadcastId: broadcast!.id,
    watchUrl: `https://www.youtube.com/watch?v=${broadcast!.id}`,
    channelTitle: 'Wildcats Volleyball',
    channelThumbnail: 'https://yt3.example/wildcats.jpg',
    privacy: 'unlisted',
  });
  expect(fakes.container.running).toBe(true);
  expect(fakes.container.starts[0]).toMatchObject({
    CONTROL_PLANE_URL: 'http://api.internal/',
    WORKER_ID: 'match',
    OUTPUT_ID: 'youtube',
    VIDEO_PROFILE: '1080p30',
    SCORE_DELAY_MS: '1100',
    INPUT_PROBE: 'fast',
  });
  // No credential reaches the container's environment.
  expect(JSON.stringify(fakes.container.starts[0])).not.toMatch(/refresh|key-stream|passphrase/);

  const read = await body(await h.call('/v1/matches/game-1', { headers: h.auth(capture.token) }));
  expect(read.youtube.watchUrl).toBe(outcome.youtube.watchUrl);

  // The phone's publish credential: Stream's SRT publish URL.
  const publish = await h.json(
    '/v1/matches/game-1/media/publish',
    {
      recordingId: 'rec-1',
      generation: 1,
      publishingAttemptId: '0a1b2c3d-0000-4000-8000-000000000001',
    },
    { headers: h.auth(capture.token) },
  );
  expect(publish.status).toBe(200);
  const access = await body(publish);
  expect(access).toMatchObject({
    gameId: 'game-1',
    generation: 1,
    recordingId: 'rec-1',
    publishingAttemptId: '0a1b2c3d-0000-4000-8000-000000000001',
  });
  expect(access.publishUrl).toMatch(/^srt:\/\/live\.cloudflare\.example:778\?passphrase=pub-/);

  // The container's worker, through the team object's worker API (the intercept's target).
  const session = await workerApi(
    owner.teamId,
    '/v1/worker/sessions',
    'POST',
    JSON.stringify({ workerId: 'match', runId: 'run-1' }),
  );
  expect(session.status).toBe(200);
  const snapshot = JSON.parse(
    (await workerApi(owner.teamId, '/v1/worker/snapshot?workerId=match')).body,
  );
  expect(snapshot.assignment.output).toEqual({
    publishUrl: expect.stringMatching(/^rtmps:\/\/a\.rtmps\.youtube\.example\/live2\/key-stream-/),
  });
  const connection = JSON.parse(
    (await workerApi(owner.teamId, '/v1/worker/connection?workerId=match')).body,
  );
  expect(connection.connection).toEqual({
    gameId: 'game-1',
    generation: 1,
    readUrl: expect.stringMatching(/^rtmps:\/\/live\.cloudflare\.example:443\/live\/play-/),
  });
  const refused = await team(owner.teamId).workerApi(
    'GET',
    '/v1/worker/snapshot?workerId=match',
    'Bearer nope',
    '',
  );
  expect(refused.status).toBe(401);
});

it('publishes only to the selected capture and generation, and connects only the match worker', async () => {
  const owner = await liveReadyTeam();
  const { scorer, capture } = await filming(owner);
  const joined = await h.json(
    `/v1/teams/${owner.teamId}/matches/game-1/join`,
    { deviceId: 'other-camera', role: 'capture' },
    { headers: h.auth(owner.token) },
  );
  const other = (await body(joined)).credential as Credential;
  const publish = (token: string, payload: Json) =>
    h.json('/v1/matches/game-1/media/publish', payload, { headers: h.auth(token) });
  const request = {
    recordingId: 'rec-1',
    generation: 1,
    publishingAttemptId: '0a1b2c3d-0000-4000-8000-000000000002',
  };
  // Before Go Live there is no running generation.
  const early = await publish(capture.token, request);
  expect(early.status).toBe(409);
  expect(await body(early)).toEqual({ error: 'broadcast_changed' });
  expect((await body(await start(owner))).accepted).toBe(true);
  expect((await publish(scorer.token, request)).status).toBe(403);
  const unselected = await publish(other.token, request);
  expect(unselected.status).toBe(403);
  expect(await body(unselected)).toEqual({ error: 'capture_not_selected' });
  const stale = await publish(capture.token, { ...request, generation: 2 });
  expect(stale.status).toBe(409);
  expect(await body(stale)).toEqual({ error: 'broadcast_changed' });
  expect((await publish(capture.token, { ...request, publishingAttemptId: 'nope' })).status).toBe(
    400,
  );
  const { publishingAttemptId: _, ...withoutAttempt } = request;
  expect((await publish(capture.token, withoutAttempt)).status).toBe(400);
  expect((await publish(capture.token, request)).status).toBe(200);
  const elsewhere = JSON.parse(
    (await workerApi(owner.teamId, '/v1/worker/connection?workerId=other')).body,
  );
  expect(elsewhere.connection).toBeNull();
});

it('stop keeps the input and broadcast; going live again reuses the same link', async () => {
  const owner = await liveReadyTeam();
  await filming(owner);
  const first = await body(await start(owner, 0));
  const stopped = await media(owner, { type: 'stop' }, 1);
  expect((await body(stopped)).accepted).toBe(true);
  expect(fakes.container.running).toBe(false);
  expect(fakes.stream.deleted).toEqual([]);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM live_slots').first('n')).toBe(0);
  const again = await body(await start(owner, 2));
  expect(again.accepted).toBe(true);
  expect(again.youtube.watchUrl).toBe(first.youtube.watchUrl);
  expect(fakes.youtube.broadcasts.size).toBe(1);
  expect(fakes.stream.inputs.size).toBe(1);
  expect(fakes.container.starts).toHaveLength(2);
});

it('ending the match tears everything down and ends the broadcast', async () => {
  const owner = await liveReadyTeam();
  const { scorer } = await filming(owner);
  await start(owner);
  const ended = await h.json(
    '/v1/matches/game-1/commands',
    {
      commandId: 'end-1',
      gameId: 'game-1',
      deviceId: scorer.deviceId,
      expectedRevision: 1,
      scorerEpoch: 1,
      issuedAt: new Date().toISOString(),
      operation: { type: 'end_match', reason: 'Gym closing' },
    },
    { headers: h.auth(scorer.token) },
  );
  expect((await body(ended)).accepted).toBe(true);
  // The end schedules an immediate alarm, which tears down on its own.
  await vi.waitFor(() => expect(fakes.youtube.calls).toContain('endBroadcast'));
  expect(fakes.container.running).toBe(false);
  expect(fakes.stream.inputs.size).toBe(0);
  expect([...fakes.youtube.broadcasts.values()][0]!.state).not.toBe('ready');
  expect(fakes.youtube.calls).toContain('endBroadcast');
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM live_slots').first('n')).toBe(0);
});

it('refuses Go Live without a team channel, and the refusal is retryable', async () => {
  const owner = await ownerWithTeam(h);
  await filming(owner);
  const refused = await start(owner, 0);
  expect(refused.status).toBe(409);
  expect(await body(refused)).toMatchObject({ accepted: false, error: 'youtube_not_set' });
  expect(fakes.container.running).toBe(false);
  // Nothing was recorded: once the owner connects, the same generation goes live.
  const { claimed } = await connect(owner.token);
  const { connection } = await body(claimed);
  await h.call(`/v1/teams/${owner.teamId}/youtube`, {
    method: 'PUT',
    headers: { ...h.auth(owner.token), 'content-type': 'application/json' },
    body: JSON.stringify({ connectionId: connection.id }),
  });
  expect((await body(await start(owner, 0))).accepted).toBe(true);
});

it('a revoked grant puts the team in needs-reconnecting', async () => {
  const owner = await liveReadyTeam();
  await filming(owner);
  fakes.youtube.revoked.add('refresh-owner');
  const refused = await body(await start(owner, 0));
  expect(refused.error).toBe('youtube_needs_reconnect');
  const view = await body(
    await h.call(`/v1/teams/${owner.teamId}`, { headers: h.auth(owner.token) }),
  );
  expect(view.youtube.status).toBe('needs_reconnect');
});

it('caps concurrent live matches service-wide with a busy refusal', async () => {
  const owner = await liveReadyTeam();
  await filming(owner);
  const now = Date.now();
  for (let i = 0; i < 5; i++)
    await env.DB.prepare('INSERT INTO live_slots VALUES(?,?,?,?)')
      .bind(`other-${i}`, 't', now, now)
      .run();
  const refused = await start(owner, 0);
  expect(refused.status).toBe(409);
  expect((await body(refused)).error).toBe('busy');
  await env.DB.prepare('DELETE FROM live_slots WHERE game_id=?').bind('other-0').run();
  expect((await body(await start(owner, 0))).accepted).toBe(true);
});

it('record-only matches never touch YouTube', async () => {
  const owner = await liveReadyTeam();
  await h.json(
    `/v1/teams/${owner.teamId}/matches`,
    { ...fixture.creation, id: 'quiet', deviceId: 'score-phone', recordOnly: true },
    { headers: h.auth(owner.token) },
  );
  const refused = await start(owner, 0, 'quiet');
  expect((await body(refused)).error).toBe('record_only_match');
  expect(fakes.youtube.broadcasts.size).toBe(0);
});

// ------------------------------------------------------------------------- guards

async function editRow(teamId: string, change: (row: Json) => void) {
  await runInDurableObject(team(teamId), async (_instance: TeamObject, state) => {
    const row = state.storage.sql
      .exec<{ data: string }>("SELECT data FROM hosted_media WHERE game_id='game-1'")
      .one();
    const data = JSON.parse(row.data) as Json;
    change(data);
    state.storage.sql.exec(
      "UPDATE hosted_media SET data=? WHERE game_id='game-1'",
      JSON.stringify(data),
    );
  });
}

it('parks an idle container after 10 minutes and restarts it when video returns', async () => {
  const owner = await liveReadyTeam();
  await filming(owner);
  await start(owner);
  await editRow(owner.teamId, (row) => {
    row.containerStartedAt = Date.now() - 11 * 60 * 1000;
  });
  await runDurableObjectAlarm(team(owner.teamId));
  expect(fakes.container.running).toBe(false);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM live_slots').first('n')).toBe(0);
  await runDurableObjectAlarm(team(owner.teamId));
  expect(fakes.container.running).toBe(false);
  for (const input of fakes.stream.inputs.values()) input.connected = true;
  await runDurableObjectAlarm(team(owner.teamId));
  expect(fakes.container.running).toBe(true);
  expect(fakes.container.starts).toHaveLength(2);
  expect(fakes.youtube.broadcasts.size).toBe(1);
});

it('restarts a crashed container on the next alarm', async () => {
  const owner = await liveReadyTeam();
  await filming(owner);
  await start(owner);
  fakes.container.running = false;
  await runDurableObjectAlarm(team(owner.teamId));
  expect(fakes.container.running).toBe(true);
});

it('ends everything at the 4-hour cap and refuses another Go Live', async () => {
  const owner = await liveReadyTeam();
  await filming(owner);
  await start(owner);
  await editRow(owner.teamId, (row) => {
    row.firstLiveAt = Date.now() - 4 * 60 * 60 * 1000 - 1;
  });
  await runDurableObjectAlarm(team(owner.teamId));
  expect(fakes.container.running).toBe(false);
  expect(fakes.stream.inputs.size).toBe(0);
  expect(fakes.youtube.calls).toContain('endBroadcast');
  const refused = await body(await start(owner, 2));
  expect(refused.error).toBe('time_limit');
});

it('the daily sweep deletes Stream inputs no open match uses', async () => {
  const owner = await liveReadyTeam();
  await filming(owner);
  await start(owner);
  const old = Date.now() - 2 * 60 * 60 * 1000;
  const orphan = fakes.stream.add(inputName(owner.teamId, 'old-game'), old);
  const stranger = fakes.stream.add('not-scorebug', old);
  const result = await sweep(env, mediaAdapters(env));
  expect(result.deletedInputs).toBe(1);
  expect(fakes.stream.deleted).toEqual([orphan]);
  expect(fakes.stream.inputs.has(stranger)).toBe(true);
  expect(fakes.container.running).toBe(true);
});

// ------------------------------------------------------------------- account deletion

const deleteAccount = (token: string) =>
  h.call('/v1/me', { method: 'DELETE', headers: h.auth(token) });

it('deleting the account ends its live match, deletes its only team and revokes Google', async () => {
  const owner = await liveReadyTeam();
  await filming(owner);
  expect((await body(await start(owner))).accepted).toBe(true);
  expect(fakes.container.running).toBe(true);

  expect((await deleteAccount(owner.token)).status).toBe(204);
  expect(fakes.container.running).toBe(false);
  expect(fakes.stream.inputs.size).toBe(0);
  expect([...fakes.youtube.broadcasts.values()][0]!.state).not.toBe('ready');
  expect(h.google.revoked).toEqual(['refresh-owner']);
  for (const table of ['youtube_connections', 'youtube_grants', 'live_slots', 'teams', 'people'])
    expect(await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first('n')).toBe(0);
});

it("a team that stays stops streaming to the deleted owner's channel and needs a new one", async () => {
  const owner = await liveReadyTeam();
  const { code } = await invite(h, owner.token, owner.teamId);
  const member = await h.signIn('parent@example.com', { invite: code });
  const { capture } = await filming(owner);
  expect((await body(await start(owner))).accepted).toBe(true);

  expect((await deleteAccount(owner.token)).status).toBe(204);
  expect(fakes.container.running).toBe(false);
  expect(fakes.youtube.calls).toContain('endBroadcast');
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM live_slots').first('n')).toBe(0);
  // The match carries on, stopped and without the old broadcast.
  const read = await body(await h.call('/v1/matches/game-1', { headers: h.auth(capture.token) }));
  expect(read.youtube).toBeNull();
  expect(read.snapshot.status).toBe('active');
  const detail = await body(
    await h.call(`/v1/teams/${owner.teamId}`, { headers: h.auth(member.token) }),
  );
  expect(detail).toMatchObject({ role: 'owner', youtube: null });
  // The new owner's Go Live asks for a channel; once there is one, it goes live there.
  const refused = await start({ token: member.token, teamId: owner.teamId }, 2);
  expect(await body(refused)).toMatchObject({ accepted: false, error: 'youtube_not_set' });
  const { claimed } = await connect(member.token, { refreshToken: 'refresh-parent' });
  const { connection } = await body(claimed);
  await h.call(`/v1/teams/${owner.teamId}/youtube`, {
    method: 'PUT',
    headers: { ...h.auth(member.token), 'content-type': 'application/json' },
    body: JSON.stringify({ connectionId: connection.id }),
  });
  const again = await body(await start({ token: member.token, teamId: owner.teamId }, 2));
  expect(again.accepted).toBe(true);
  expect(fakes.youtube.broadcasts.size).toBe(2);
});

it('a failed Google revoke does not stop the deletion', async () => {
  const owner = await liveReadyTeam();
  h.google.revokeFails = true;
  expect((await deleteAccount(owner.token)).status).toBe(204);
  expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM youtube_connections').first('n')).toBe(0);
});
