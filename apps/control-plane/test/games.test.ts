import { describe, expect, it } from 'vitest';
import { buildTestApp, FakeHomeSocket, phoneAuth } from './helpers.js';

const teams = {
  homeTeam: { name: 'Spikers', shortName: 'SPK', color: '#1e3a8a' },
  awayTeam: { name: 'Diggers', shortName: 'DIG', color: '#b91c1c' },
  youtubeStreamKey: 'yt-stream-key-abcdefgh',
};

async function postStart(app: ReturnType<typeof buildTestApp>['app'], token: string) {
  return app.request('/games/start', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...phoneAuth(token) },
    body: JSON.stringify(teams),
  });
}

describe('games routes', () => {
  it('requires the phone bearer token', async () => {
    const { app } = buildTestApp();
    const res = await app.request('/games/start', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(teams),
    });
    expect(res.status).toBe(401);
  });

  it('starts a game and returns publish credentials', async () => {
    const { app, config } = buildTestApp();
    const res = await postStart(app, config.PHONE_TOKEN);
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      id: string;
      status: string;
      publish: { host: string; port: number; streamId: string; passphrase: string };
    };
    expect(body.status).toBe('starting');
    expect(body.publish.host).toBe('ingest.test');
    expect(body.publish.streamId).toMatch(/^publish:game_[0-9a-f-]+:/);
    expect(body.publish.passphrase).toHaveLength(43); // 32 bytes base64url
  });

  it('rejects a second concurrent start with 409', async () => {
    const { app, config } = buildTestApp();
    const r1 = await postStart(app, config.PHONE_TOKEN);
    expect(r1.status).toBe(201);
    const r2 = await postStart(app, config.PHONE_TOKEN);
    expect(r2.status).toBe(409);
    const body = (await r2.json()) as { error: string; existing: { id: string } };
    expect(body.error).toBe('game_in_flight');
    expect(body.existing.id).toBeDefined();
  });

  it('allows a new game after ending the previous one', async () => {
    const { app, config } = buildTestApp();
    const r1 = await postStart(app, config.PHONE_TOKEN);
    const { id } = (await r1.json()) as { id: string };
    await app.request(`/games/${id}/end`, {
      method: 'POST',
      headers: phoneAuth(config.PHONE_TOKEN),
    });
    const r2 = await postStart(app, config.PHONE_TOKEN);
    expect(r2.status).toBe(201);
  });

  it('forwards score updates to the home socket when connected', async () => {
    const { app, config, bus } = buildTestApp();
    const socket = new FakeHomeSocket();
    bus.attach(socket);

    const r1 = await postStart(app, config.PHONE_TOKEN);
    const { id } = (await r1.json()) as { id: string };

    const score = { home: 12, away: 9, set: 1, homeSets: 0, awaySets: 0 };
    const r2 = await app.request(`/games/${id}/score`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...phoneAuth(config.PHONE_TOKEN) },
      body: JSON.stringify(score),
    });
    expect(r2.status).toBe(200);

    expect(socket.sent.length).toBe(2); // start_game + score_update
    const parsed = socket.sent.map((s) => JSON.parse(s) as { type: string });
    expect(parsed.map((p) => p.type)).toEqual(['start_game', 'score_update']);
  });

  it('rejects scoring an ended game with 409', async () => {
    const { app, config } = buildTestApp();
    const r1 = await postStart(app, config.PHONE_TOKEN);
    const { id } = (await r1.json()) as { id: string };
    await app.request(`/games/${id}/end`, {
      method: 'POST',
      headers: phoneAuth(config.PHONE_TOKEN),
    });
    const r2 = await app.request(`/games/${id}/score`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...phoneAuth(config.PHONE_TOKEN) },
      body: JSON.stringify({ home: 1, away: 0, set: 1, homeSets: 0, awaySets: 0 }),
    });
    expect(r2.status).toBe(409);
  });

  it('rejects invalid score payloads with 400', async () => {
    const { app, config } = buildTestApp();
    const r1 = await postStart(app, config.PHONE_TOKEN);
    const { id } = (await r1.json()) as { id: string };
    const r2 = await app.request(`/games/${id}/score`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...phoneAuth(config.PHONE_TOKEN) },
      body: JSON.stringify({ home: -1, away: 0, set: 1, homeSets: 0, awaySets: 0 }),
    });
    expect(r2.status).toBe(400);
  });

  it('accepts callout events with valid kinds', async () => {
    const { app, config, bus } = buildTestApp();
    const socket = new FakeHomeSocket();
    bus.attach(socket);

    const r1 = await postStart(app, config.PHONE_TOKEN);
    const { id } = (await r1.json()) as { id: string };

    const r2 = await app.request(`/games/${id}/callout`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...phoneAuth(config.PHONE_TOKEN) },
      body: JSON.stringify({ kind: 'kill', player: { number: 7, name: 'Alex' } }),
    });
    expect(r2.status).toBe(200);
    const parsed = socket.sent.map((s) => JSON.parse(s) as { type: string });
    expect(parsed.at(-1)?.type).toBe('callout');
  });
});

describe('internal routes', () => {
  it('marks a game live when MediaMTX webhook fires', async () => {
    const { app, config } = buildTestApp();
    const r1 = await postStart(app, config.PHONE_TOKEN);
    const { id } = (await r1.json()) as { id: string };

    const r2 = await app.request('/internal/stream-ready', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${config.INTERNAL_TOKEN}`,
      },
      body: JSON.stringify({ path: `game_${id}` }),
    });
    expect(r2.status).toBe(200);

    const r3 = await app.request(`/games/${id}`, {
      headers: phoneAuth(config.PHONE_TOKEN),
    });
    const body = (await r3.json()) as { status: string };
    expect(body.status).toBe('live');
  });

  it('rejects the internal webhook without the internal bearer', async () => {
    const { app, config } = buildTestApp();
    const r1 = await postStart(app, config.PHONE_TOKEN);
    const { id } = (await r1.json()) as { id: string };

    const r2 = await app.request('/internal/stream-ready', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${config.PHONE_TOKEN}`,
      },
      body: JSON.stringify({ path: `game_${id}` }),
    });
    expect(r2.status).toBe(401);
  });
});
