import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { afterEach, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { MatchStore } from '../src/matches-store.js';
import { openNodeSqlite } from '../src/sql-node.js';
import { RedeemGuard } from '../src/rate-limit.js';
import { ownerToken, testConfig } from './helpers.js';

const apps: ReturnType<typeof createApp>[] = [];
const dirs: string[] = [];
afterEach(() => {
  for (const item of apps.splice(0)) item.matches.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  vi.restoreAllMocks();
});
const rules = { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null };
const team = (name: string, shortName?: string) => ({
  name,
  ...(shortName === undefined ? {} : { shortName }),
  color: '#112233',
});
const STREAM_KEY = 'abcd-efgh-ijkl-mnop-qrst';

function setup(
  options: { setupGuard?: RedeemGuard; inviteGuard?: RedeemGuard; file?: boolean } = {},
) {
  const clock = { now: Date.parse('2026-11-15T12:00:00.000Z') };
  let path = ':memory:';
  if (options.file) {
    const dir = mkdtempSync(join(tmpdir(), 'scorebug-account-'));
    dirs.push(dir);
    path = join(dir, 'db.sqlite');
  }
  const config = testConfig({ PUBLIC_URL: 'https://scorebug.example.com', DATABASE_PATH: path });
  const matches = new MatchStore(openNodeSqlite(path), config.SERVER_SECRET, () => clock.now);
  const value = createApp(config, {
    matches,
    ...(options.setupGuard ? { setupGuard: options.setupGuard } : {}),
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
  let owner: string | undefined;
  // Enrolled on first use, so tests that count devices see only their own.
  const ownerOf = () => (owner ??= ownerToken(matches));
  return { ...value, path, clock, config, owner: ownerOf, call };
}
type Fixture = ReturnType<typeof setup>;

async function enroll(f: Fixture, deviceId: string = randomUUID()) {
  const { code } = f.matches.account.mintSetupCode();
  const redeemed = await f.call('POST', '/v1/setup/redeem', undefined, {
    code,
    deviceId,
    deviceName: 'JD iPhone',
  });
  expect(redeemed.status).toBe(200);
  return { code, deviceId, token: redeemed.json.token as string, body: redeemed.json };
}
async function createMatch(f: Fixture, token: string, extra: Record<string, unknown> = {}) {
  return f.call('POST', '/v1/matches', token, {
    id: 'game-1',
    deviceId: 'owner-phone',
    teams: { home: team('Spikers', 'SPK'), away: team('Diggers', 'DIG') },
    rules,
    ...extra,
  });
}

// ------------------------------------------------------------- enrollment

it('redeems a one-time setup code for a revocable owner device credential', async () => {
  const f = setup();
  const { code, deviceId, token, body } = await enroll(f);
  expect(body.device).toMatchObject({ id: deviceId, name: 'JD iPhone', role: 'owner' });
  expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
  // The device credential is an owner: it can create matches and list devices.
  expect((await createMatch(f, token)).status).toBe(201);
  const devices = await f.call('GET', '/v1/devices', token);
  expect(devices.status).toBe(200);
  expect(devices.json.devices).toHaveLength(1);
  expect(devices.text).not.toContain(token);
  expect((await f.call('GET', '/v1/devices/me', token)).json).toMatchObject({
    role: 'owner',
    device: { id: deviceId },
  });
  // Single use: another phone cannot reuse the code.
  const reuse = await f.call('POST', '/v1/setup/redeem', undefined, {
    code,
    deviceId: randomUUID(),
    deviceName: 'Other',
  });
  expect(reuse.status).toBe(409);
  expect(reuse.json.error).toBe('setup_code_used');
  // Revocation takes effect immediately.
  expect(
    (await f.call('DELETE', `/v1/devices/${deviceId}`, f.owner())).json.device.revokedAt,
  ).not.toBeNull();
  expect((await f.call('GET', '/v1/devices', token)).status).toBe(401);
  expect((await createMatch(f, token, { id: 'game-2' })).status).toBe(401);
});

it('lets a phone repeat a lost redeem response briefly, with the same device ID only', async () => {
  const f = setup();
  const { code, deviceId, token } = await enroll(f);
  const retry = await f.call('POST', '/v1/setup/redeem', undefined, {
    code,
    deviceId,
    deviceName: 'JD iPhone',
  });
  expect(retry.status).toBe(200);
  expect(retry.json.token).toBe(token);
  f.clock.now += 11 * 60 * 1000;
  expect(
    (await f.call('POST', '/v1/setup/redeem', undefined, { code, deviceId, deviceName: 'x' }))
      .status,
  ).toBe(409);
});

it('expires setup codes after 24 hours by default and rejects unknown codes', async () => {
  const f = setup();
  const { code, expiresAt } = f.matches.account.mintSetupCode();
  expect(Date.parse(expiresAt) - f.clock.now).toBe(24 * 3600 * 1000);
  f.clock.now = Date.parse(expiresAt);
  const expired = await f.call('POST', '/v1/setup/redeem', undefined, {
    code,
    deviceId: randomUUID(),
  });
  expect(expired.status).toBe(410);
  expect(expired.json.error).toBe('setup_code_expired');
  const unknown = await f.call('POST', '/v1/setup/redeem', undefined, {
    code: 'A'.repeat(24),
    deviceId: randomUUID(),
  });
  expect(unknown.status).toBe(401);
  expect(unknown.json.error).toBe('setup_code_invalid');
});

it('stores only hashes of setup codes and device tokens', async () => {
  const f = setup({ file: true });
  const { code, token } = await enroll(f);
  const pending = f.matches.account.mintSetupCode().code;
  f.matches.close();
  // Closing checkpoints the WAL into the main file.
  const raw = readFileSync(f.path).toString('latin1');
  for (const secret of [code, token, pending]) expect(raw).not.toContain(secret);
});

it('accepts only enrolled device tokens as owner credentials', async () => {
  const f = setup();
  // The server secret keys credentials; it is never a bearer token.
  for (const token of [f.config.SERVER_SECRET, f.config.HOME_TOKEN, 'wrong-token']) {
    expect((await createMatch(f, token)).status).toBe(401);
    expect((await f.call('GET', '/v1/devices', token)).status).toBe(401);
  }
  expect((await createMatch(f, f.owner())).status).toBe(201);
});

it('lets an owner mint a setup link for another phone', async () => {
  const f = setup();
  const { token } = await enroll(f);
  const minted = await f.call('POST', '/v1/setup/links', token);
  expect(minted.status).toBe(201);
  const link = new URL(minted.json.link);
  expect(minted.json.link.startsWith('scorebug://connect?')).toBe(true);
  expect(link.searchParams.get('server')).toBe('https://scorebug.example.com');
  expect(link.searchParams.get('code')).toBe(minted.json.code);
  expect((await f.call('POST', '/v1/setup/links', undefined)).status).toBe(401);
  expect((await f.call('POST', '/v1/setup/links', token, { expiresInHours: 0 })).status).toBe(400);
});

it('rate limits setup redemption per client and globally on failures', async () => {
  const f = setup({
    setupGuard: new RedeemGuard({ perClient: 3, failures: 5, failureWindowMs: 600_000 }),
  });
  const attempt = (ip: string) =>
    f.call(
      'POST',
      '/v1/setup/redeem',
      undefined,
      { code: 'B'.repeat(24), deviceId: randomUUID() },
      { 'x-forwarded-for': ip },
    );
  for (let i = 0; i < 3; i++) expect((await attempt('203.0.113.1')).status).toBe(401);
  const limited = await attempt('203.0.113.1');
  expect(limited.status).toBe(429);
  expect(limited.response.headers.get('retry-after')).toMatch(/^\d+$/);
  // Two more failures from new addresses exhaust the global failure budget.
  expect((await attempt('203.0.113.2')).status).toBe(401);
  expect((await attempt('203.0.113.3')).status).toBe(401);
  expect((await attempt('203.0.113.4')).status).toBe(429);
});

// ---------------------------------------------------------------- invites

async function inviteFixture() {
  const f = setup();
  const owner = await enroll(f);
  const created = await createMatch(f, owner.token);
  const capture = (
    await f.call('POST', '/v1/matches/game-1/join', owner.token, {
      deviceId: 'owner-phone-camera',
      role: 'capture',
    })
  ).json.credential;
  return { f, owner, ownerScore: created.json.credential, capture };
}

it('mints short typeable multi-use invites that redeem for scorer credentials', async () => {
  const { f, capture } = await inviteFixture();
  const minted = await f.call('POST', '/v1/matches/game-1/invites', capture.token);
  expect(minted.status).toBe(201);
  expect(minted.json.code).toMatch(/^[2-9A-HJKMNP-TV-Z]{3}-[2-9A-HJKMNP-TV-Z]{3}$/);
  const link = new URL(minted.json.link);
  expect(minted.json.link.startsWith('scorebug://join?')).toBe(true);
  expect(link.searchParams.get('server')).toBe('https://scorebug.example.com');
  expect(link.searchParams.get('code')).toBe(minted.json.code.replace('-', ''));
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
  // Everything owner-only is refused.
  expect((await createMatch(f, scorer.token, { id: 'game-2' })).status).toBe(401);
  expect((await f.call('GET', '/v1/destinations', scorer.token)).status).toBe(401);
  expect((await f.call('GET', '/v1/devices', scorer.token)).status).toBe(401);
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

it('requires an owner or the match capture device to manage invites', async () => {
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

// ----------------------------------------------------------- destinations

it('never returns or logs a destination stream key', async () => {
  const lines: string[] = [];
  for (const method of ['log', 'info', 'warn', 'error', 'debug'] as const)
    vi.spyOn(console, method).mockImplementation((...args: unknown[]) => {
      lines.push(args.map(String).join(' '));
    });
  const f = setup();
  const { token } = await enroll(f);
  const responses: string[] = [];
  const created = await f.call('POST', '/v1/destinations', token, {
    name: 'YouTube',
    rtmpUrl: 'rtmps://a.rtmp.youtube.com/live2',
    streamKey: STREAM_KEY,
  });
  expect(created.status).toBe(201);
  expect(created.json.destination).toMatchObject({
    name: 'YouTube',
    rtmpUrl: 'rtmps://a.rtmp.youtube.com/live2',
    streamKeyLast4: 'qrst',
    isDefault: true,
  });
  const id = created.json.destination.id;
  responses.push(created.text);
  responses.push((await f.call('GET', '/v1/destinations', token)).text);
  responses.push((await f.call('GET', `/v1/destinations/${id}`, token)).text);
  const rotated = await f.call('PATCH', `/v1/destinations/${id}`, token, {
    streamKey: `${STREAM_KEY}-new9`,
  });
  expect(rotated.json.destination.streamKeyLast4).toBe('new9');
  responses.push(rotated.text);
  // Invalid requests are not echoed back either.
  const invalid = await f.call('POST', '/v1/destinations', token, {
    name: 'Bad',
    rtmpUrl: 'https://not-rtmp.example.com',
    streamKey: STREAM_KEY,
  });
  expect(invalid.status).toBe(400);
  responses.push(invalid.text);
  responses.push((await createMatch(f, token)).text);
  responses.push((await f.call('GET', '/v1/matches/active', token)).text);
  for (const text of [...responses, ...lines]) expect(text).not.toContain(STREAM_KEY);
  expect((await f.call('GET', '/v1/destinations', undefined)).status).toBe(401);
});

it('validates destinations, keeps one default and protects one in use', async () => {
  const f = setup();
  const add = (body: Record<string, unknown>) =>
    f.call('POST', '/v1/destinations', f.owner(), body);
  expect((await add({ name: 'x', rtmpUrl: 'rtmp://h/app', streamKey: 'has space' })).status).toBe(
    400,
  );
  expect((await add({ name: 'x', rtmpUrl: 'rtmp://user:pw@h/app', streamKey: 'k' })).status).toBe(
    400,
  );
  expect((await add({ name: '', rtmpUrl: 'rtmp://h/app', streamKey: 'k' })).status).toBe(400);
  const first = (await add({ name: 'YouTube', rtmpUrl: 'rtmps://h/live2', streamKey: 'key-one-1' }))
    .json.destination;
  const second = (
    await add({ name: 'Facebook', rtmpUrl: 'rtmps://fb:443/rtmp', streamKey: 'FB-1?s_bl=1&a=b' })
  ).json.destination;
  expect(first.isDefault).toBe(true);
  expect(second.isDefault).toBe(false);
  await f.call('PATCH', `/v1/destinations/${second.id}`, f.owner(), { isDefault: true });
  const list = (await f.call('GET', '/v1/destinations', f.owner())).json.destinations;
  expect(list.map((d: { isDefault: boolean }) => d.isDefault)).toEqual([false, true]);
  expect(
    (await createMatch(f, f.owner(), { destinationId: first.id })).json.snapshot.output,
  ).toEqual({
    destinationId: first.id,
    recordOnly: false,
  });
  const inUse = await f.call('DELETE', `/v1/destinations/${first.id}`, f.owner());
  expect(inUse.status).toBe(409);
  expect(inUse.json.error).toBe('destination_in_use');
  expect((await f.call('DELETE', `/v1/destinations/${second.id}`, f.owner())).status).toBe(200);
  expect((await f.call('GET', `/v1/destinations/${second.id}`, f.owner())).status).toBe(404);
  expect((await f.call('PATCH', `/v1/destinations/${first.id}`, f.owner(), {})).status).toBe(400);
});

it('assigns match outputs: named, default, record-only or the worker fallback', async () => {
  const f = setup();
  // No destinations: the worker's own OUTPUT_URL applies.
  const fallback = await createMatch(f, f.owner());
  expect(fallback.json.snapshot.output).toEqual({ destinationId: null, recordOnly: false });
  expect(
    (
      await createMatch(f, f.owner(), {
        id: 'other',
        recordOnly: true,
        destinationId: randomUUID(),
      })
    ).status,
  ).toBe(400);
  const g = setup();
  const missing = await createMatch(g, g.owner(), { destinationId: randomUUID() });
  expect(missing.json.error).toBe('destination_not_found');
});

async function startBroadcast(f: Fixture, token: string) {
  const capture = (
    await f.call('POST', '/v1/matches/game-1/join', token, { deviceId: 'cam', role: 'capture' })
  ).json.credential;
  const issuedAt = new Date(f.clock.now).toISOString();
  await f.call('POST', '/v1/matches/game-1/media/recordings', capture.token, {
    recordingId: 'archive',
    sequence: 0,
    status: 'recording',
    startedAt: issuedAt,
  });
  return f.call('POST', '/v1/matches/game-1/media/commands', token, {
    commandId: 'start',
    gameId: 'game-1',
    expectedGeneration: 0,
    issuedAt,
    operation: {
      type: 'start',
      selection: { workerId: 'w1', outputId: 'o1', captureDeviceId: 'cam', recordingId: 'archive' },
    },
  });
}

it('hands the worker its match destination URL; record-only matches never broadcast', async () => {
  const f = setup();
  const destination = f.matches.account.createDestination({
    name: 'YouTube',
    rtmpUrl: 'rtmps://a.rtmp.youtube.com/live2/',
    streamKey: STREAM_KEY,
  });
  const created = await createMatch(f, f.owner());
  // Omitted destinationId resolves to the default destination at creation.
  expect(created.json.snapshot.output.destinationId).toBe(destination.id);
  expect((await startBroadcast(f, f.owner())).json.accepted).toBe(true);
  const worker = await f.call('GET', '/v1/worker/snapshot?workerId=w1', testConfig().HOME_TOKEN);
  expect(worker.json.assignment.output).toEqual({
    destinationId: destination.id,
    publishUrl: `rtmps://a.rtmp.youtube.com/live2/${STREAM_KEY}`,
  });
  // Only the worker token sees it.
  expect((await f.call('GET', '/v1/worker/snapshot?workerId=w1', f.owner())).status).toBe(401);

  const g = setup();
  const recordOnly = await createMatch(g, g.owner(), { recordOnly: true });
  expect(recordOnly.json.snapshot.output).toEqual({ destinationId: null, recordOnly: true });
  const refused = await startBroadcast(g, g.owner());
  expect(refused.json).toMatchObject({ accepted: false, error: 'record_only_match' });
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

it('mints links only from PUBLIC_URL, never from the request Host header', async () => {
  const config = testConfig();
  const value = createApp(config);
  apps.push(value);
  const owner = ownerToken(value.matches);
  const created = await value.app.request('/v1/matches', {
    method: 'POST',
    headers: { authorization: `Bearer ${owner}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      id: 'game-1',
      deviceId: 'p',
      teams: { home: team('Home'), away: team('Away') },
      rules,
    }),
  });
  expect(created.status).toBe(201);
  for (const path of ['/v1/setup/links', '/v1/matches/game-1/invites']) {
    const response = await value.app.request(path, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${owner}`,
        host: 'attacker.example',
        'x-forwarded-host': 'attacker.example',
      },
    });
    expect(response.status).toBe(503);
    const text = await response.text();
    expect(JSON.parse(text).error).toBe('public_url_not_configured');
    expect(text).not.toContain('attacker');
  }
  expect(value.matches.listInvites('game-1')).toHaveLength(0);
});
