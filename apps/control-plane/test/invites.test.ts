import { Hono } from 'hono';
import { afterEach, expect, it } from 'vitest';
import { MatchStore } from '../src/matches-store.js';
import { RedeemGuard } from '../src/rate-limit.js';
import { inviteRoutes } from '../src/routes/invites.js';
import type { MatchAccess } from '../src/routes/matches.js';
import { createTestApp, MEMBER_TOKEN, SERVER_SECRET } from './helpers.js';
import { openNodeSqlite } from './sqlite.js';

const apps: ReturnType<typeof createTestApp>[] = [];
afterEach(() => {
  for (const item of apps.splice(0)) item.matches.close();
});
const rules = { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null };
const team = (name: string, shortName?: string) => ({
  name,
  ...(shortName === undefined ? {} : { shortName }),
  color: '#112233',
});

function setup(options: { inviteGuard?: RedeemGuard } = {}) {
  const clock = { now: Date.parse('2026-11-15T12:00:00.000Z') };
  const matches = new MatchStore(openNodeSqlite(':memory:'), SERVER_SECRET, () => clock.now);
  const value = createTestApp({
    matches,
    ...(options.inviteGuard ? { inviteGuard: options.inviteGuard } : {}),
  });
  apps.push(value);
  const call = async (
    method: string,
    path: string,
    token?: string,
    body?: unknown,
    headers: Record<string, string> = {},
  ) => {
    const response = await value.app.request(path, {
      method,
      headers: {
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        'content-type': 'application/json',
        ...headers,
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const text = await response.text();
    return { status: response.status, text, json: text ? JSON.parse(text) : null, response };
  };
  return { ...value, clock, owner: () => MEMBER_TOKEN, call };
}
type Fixture = ReturnType<typeof setup>;

async function createMatch(f: Fixture, token: string, extra: Record<string, unknown> = {}) {
  return f.call('POST', '/v1/matches', token, {
    id: 'game-1',
    deviceId: 'owner-phone',
    teams: { home: team('Spikers', 'SPK'), away: team('Diggers', 'DIG') },
    rules,
    ...extra,
  });
}

// ---------------------------------------------------------------- invites

async function inviteFixture() {
  const f = setup();
  const created = await createMatch(f, f.owner());
  const capture = (
    await f.call('POST', '/v1/matches/game-1/join', f.owner(), {
      deviceId: 'owner-phone-camera',
      role: 'capture',
    })
  ).json.credential;
  return { f, ownerScore: created.json.credential, capture };
}

it('mints short typeable multi-use invites that redeem for scorer credentials', async () => {
  const { f, capture } = await inviteFixture();
  const minted = await f.call('POST', '/v1/matches/game-1/invites', capture.token);
  expect(minted.status).toBe(201);
  expect(minted.json.code).toMatch(/^[2-9A-HJKMNP-TV-Z]{3}-[2-9A-HJKMNP-TV-Z]{3}$/);
  expect(minted.json.link).toBe(`https://scorebug.test/join/${minted.json.code.replace('-', '')}`);
  // Default expiry: six hours (or match end, whichever is first).
  expect(Date.parse(minted.json.expiresAt) - f.clock.now).toBe(6 * 3600 * 1000);

  const typed = minted.json.code.toLowerCase().replace('-', ' ');
  const a = await f.call('POST', '/v1/invites/redeem', undefined, { code: typed, deviceId: 'mom' });
  expect(a.status).toBe(200);
  expect(a.json.credential).toMatchObject({ gameId: 'game-1', deviceId: 'mom', role: 'score' });
  expect(a.json.snapshot.id).toBe('game-1');
  const b = await f.call('POST', '/v1/invites/redeem', undefined, {
    code: minted.json.code,
    deviceId: 'dad',
  });
  expect(b.status).toBe(200);
  // Redeeming again on the same phone is idempotent.
  const again = await f.call('POST', '/v1/invites/redeem', undefined, {
    code: minted.json.code,
    deviceId: 'mom',
  });
  expect(again.json.credential.token).toBe(a.json.credential.token);
  const list = await f.call('GET', '/v1/matches/game-1/invites', capture.token);
  expect(list.json.invites).toHaveLength(1);
  expect(list.json.invites[0].redemptions).toBe(2);
  expect(list.text).not.toContain(minted.json.code.replace('-', ''));
});

it('gives invite scorers scoring and takeover only', async () => {
  const { f } = await inviteFixture();
  const { code } = (await f.call('POST', '/v1/matches/game-1/invites', f.owner())).json;
  const scorer = (await f.call('POST', '/v1/invites/redeem', undefined, { code, deviceId: 'mom' }))
    .json.credential;
  const command = (operation: unknown, revision: number, epoch: number, commandId: string) =>
    f.call('POST', '/v1/matches/game-1/commands', scorer.token, {
      commandId,
      gameId: 'game-1',
      deviceId: 'mom',
      expectedRevision: revision,
      scorerEpoch: epoch,
      issuedAt: new Date(f.clock.now).toISOString(),
      operation,
    });
  // Not the current scorer yet; take over, then score.
  expect((await command({ type: 'award_point', side: 'home' }, 0, 1, 'p0')).json.error).toBe(
    'scorer_changed',
  );
  expect((await command({ type: 'take_over' }, 0, 1, 'take')).status).toBe(200);
  expect((await command({ type: 'award_point', side: 'home' }, 1, 2, 'p1')).status).toBe(200);
  // Everything member-only is refused.
  expect((await createMatch(f, scorer.token, { id: 'game-2' })).status).toBe(401);
  expect((await f.call('POST', '/v1/matches/game-1/invites', scorer.token)).status).toBe(403);
  expect(
    (
      await f.call('POST', '/v1/matches/game-1/media/commands', scorer.token, {
        commandId: 'stop',
        gameId: 'game-1',
        expectedGeneration: 0,
        issuedAt: new Date(f.clock.now).toISOString(),
        operation: { type: 'stop' },
      })
    ).status,
  ).toBe(401);
  expect(
    (
      await f.call('POST', '/v1/matches/game-1/join', scorer.token, {
        deviceId: 'mom',
        role: 'capture',
      })
    ).status,
  ).toBe(401);
});

it('expires, revokes and ends invites, and revocation removes their scorers', async () => {
  const { f, ownerScore } = await inviteFixture();
  const short = (
    await f.call('POST', '/v1/matches/game-1/invites', f.owner(), { expiresInMinutes: 5 })
  ).json;
  const long = (await f.call('POST', '/v1/matches/game-1/invites', f.owner())).json;
  const scorer = (
    await f.call('POST', '/v1/invites/redeem', undefined, { code: long.code, deviceId: 'mom' })
  ).json.credential;
  f.clock.now += 5 * 60 * 1000;
  const expired = await f.call('POST', '/v1/invites/redeem', undefined, {
    code: short.code,
    deviceId: 'aunt',
  });
  expect(expired.status).toBe(410);
  expect(expired.json.error).toBe('invite_expired');
  expect(expired.text).not.toContain('snapshot');

  expect((await f.call('GET', '/v1/matches/game-1', scorer.token)).status).toBe(200);
  const revoked = await f.call('DELETE', `/v1/matches/game-1/invites/${long.invite.id}`, f.owner());
  expect(revoked.json.invite.revokedAt).not.toBeNull();
  expect((await f.call('GET', '/v1/matches/game-1', scorer.token)).status).toBe(401);
  const afterRevoke = await f.call('POST', '/v1/invites/redeem', undefined, {
    code: long.code,
    deviceId: 'uncle',
  });
  expect(afterRevoke.json.error).toBe('invite_revoked');

  const third = (await f.call('POST', '/v1/matches/game-1/invites', f.owner())).json;
  const end = await f.call('POST', '/v1/matches/game-1/commands', ownerScore.token, {
    commandId: 'end',
    gameId: 'game-1',
    deviceId: 'owner-phone',
    expectedRevision: 0,
    scorerEpoch: 1,
    issuedAt: new Date(f.clock.now).toISOString(),
    operation: { type: 'end_match', reason: 'done' },
  });
  expect(end.status).toBe(200);
  const ended = await f.call('POST', '/v1/invites/redeem', undefined, {
    code: third.code,
    deviceId: 'cousin',
  });
  expect(ended.status).toBe(410);
  expect(ended.json.error).toBe('match_ended');
  expect((await f.call('POST', '/v1/matches/game-1/invites', f.owner())).json.error).toBe(
    'match_ended',
  );
});

it('refuses invite device IDs that alias existing match credentials', async () => {
  const { f } = await inviteFixture();
  const { code } = (await f.call('POST', '/v1/matches/game-1/invites', f.owner())).json;
  const alias = await f.call('POST', '/v1/invites/redeem', undefined, {
    code,
    deviceId: 'owner-phone',
  });
  expect(alias.status).toBe(409);
  expect(alias.json.error).toBe('device_id_taken');
});

it('requires a member or the match capture device to manage invites', async () => {
  const { f, ownerScore } = await inviteFixture();
  expect((await f.call('POST', '/v1/matches/game-1/invites', undefined)).status).toBe(401);
  expect((await f.call('POST', '/v1/matches/game-1/invites', 'nope')).status).toBe(401);
  expect((await f.call('POST', '/v1/matches/game-1/invites', ownerScore.token)).status).toBe(403);
  expect((await f.call('GET', '/v1/matches/game-1/invites', ownerScore.token)).status).toBe(403);
});

it('rate limits invite redemption', async () => {
  const f = setup({ inviteGuard: new RedeemGuard({ perClient: 2 }) });
  const attempt = () =>
    f.call(
      'POST',
      '/v1/invites/redeem',
      undefined,
      { code: 'AAA-AAA', deviceId: 'x' },
      {
        'x-forwarded-for': '198.51.100.7',
      },
    );
  expect((await attempt()).status).toBe(401);
  expect((await attempt()).status).toBe(401);
  expect((await attempt()).status).toBe(429);
});

it('revokes a join code whose routing hook fails, so no unroutable code lingers', async () => {
  const store = new MatchStore(openNodeSqlite(':memory:'), 'qa-credential-key-not-production');
  store.create({
    id: 'game-1',
    deviceId: 'phone-a',
    teams: {
      home: { name: 'One', shortName: 'ONE', color: '#112233' },
      away: { name: 'Two', shortName: 'TWO', color: '#445566' },
    },
    rules: { ...rules, bestOf: 3 as const },
  });
  const access: MatchAccess = {
    bootstrap: async (_c, next) => next(),
    issuer: () => 'member:someone',
    joinLink: (code) => `https://scorebug.test/join/${code}`,
    onInvite: {
      issued: async () => {
        throw new Error('code taken elsewhere');
      },
      revoked: async () => {},
    },
  };
  const app = new Hono();
  app.route('/v1/matches/:id/invites', inviteRoutes(store, access));
  app.onError((_error, c) => c.json({ error: 'internal' }, 500));
  const response = await app.request('/v1/matches/game-1/invites', { method: 'POST' });
  expect(response.status).toBe(500);
  const invites = store.listInvites('game-1');
  expect(invites).toHaveLength(1);
  expect(invites[0]?.revokedAt).not.toBeNull();
  store.close();
});

// ---------------------------------------------------------------- scoring

it('defaults team short names from the name and limits them to 8 characters', async () => {
  const f = setup();
  const make = (home: unknown, id = 'game-1') =>
    f.call('POST', '/v1/matches', f.owner(), {
      id,
      deviceId: 'p',
      teams: { home, away: team('Diggers') },
      rules,
    });
  expect((await make(team('Spikers', 'SPIKERS99'))).status).toBe(400);
  expect((await make(team('Spikers', '   '))).status).toBe(400);
  const created = await make(team('  Bay   Area Juniors ', '🏐 BAJ 🏐'));
  expect(created.status).toBe(201);
  expect(created.json.snapshot.teams.home.shortName).toBe('🏐 BAJ 🏐');
  expect(created.json.snapshot.teams.away.shortName).toBe('Diggers');
  const g = setup();
  const defaulted = await g.call('POST', '/v1/matches', g.owner(), {
    id: 'g',
    deviceId: 'p',
    teams: { home: team('  Bay   Area Juniors '), away: team('A') },
    rules,
  });
  expect(defaulted.json.snapshot.teams.home.shortName).toBe('Bay Area');
});

it('reports pendingSetEnd at set point and keeps points after it allowed', async () => {
  const f = setup();
  const created = (await createMatch(f, f.owner())).json;
  let revision = 0;
  const run = async (operation: unknown) => {
    const result = await f.call('POST', '/v1/matches/game-1/commands', created.credential.token, {
      commandId: `c${revision}`,
      gameId: 'game-1',
      deviceId: 'owner-phone',
      expectedRevision: revision,
      scorerEpoch: 1,
      issuedAt: new Date(f.clock.now).toISOString(),
      operation,
    });
    expect(result.status).toBe(200);
    revision++;
    return result.json.snapshot;
  };
  let snapshot = created.snapshot;
  expect(snapshot.pendingSetEnd).toBeNull();
  for (let i = 0; i < 24; i++) snapshot = await run({ type: 'award_point', side: 'home' });
  for (let i = 0; i < 23; i++) snapshot = await run({ type: 'award_point', side: 'away' });
  expect(snapshot.pendingSetEnd).toBeNull();
  snapshot = await run({ type: 'award_point', side: 'home' });
  expect(snapshot.pendingSetEnd).toEqual({ winner: 'home' });
  snapshot = await run({ type: 'award_point', side: 'away' });
  expect(snapshot.pendingSetEnd).toBeNull();
  snapshot = await run({ type: 'award_point', side: 'home' });
  snapshot = await run({ type: 'award_point', side: 'home' });
  expect(snapshot.score).toMatchObject({ home: 27, away: 24 });
  expect(snapshot.pendingSetEnd).toEqual({ winner: 'home' });
  snapshot = await run({ type: 'end_set' });
  expect(snapshot.score).toMatchObject({ set: 2, homeSets: 1, home: 0, away: 0 });
  expect(snapshot.pendingSetEnd).toBeNull();
});
