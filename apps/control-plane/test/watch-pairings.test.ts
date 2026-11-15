import { fork } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { afterEach, expect, it } from 'vitest';
import { MatchStore } from '../src/matches-store.js';
import { createApp } from '../src/app.js';
import { testConfig } from './helpers.js';

const gameId = '10000000-0000-4000-8000-000000000001';
const phone = '20000000-0000-4000-8000-000000000001';
const watch = '30000000-0000-4000-8000-000000000001';
const pairingId = '40000000-0000-4000-8000-000000000001';
const redemptionId = '50000000-0000-4000-8000-000000000001';
const issue = { pairingId, watchDeviceId: watch };
const redeem = { redemptionId, deviceId: watch };
const recovery = Buffer.alloc(32, 17).toString('base64url');
const initialTime = Date.parse('2026-09-14T01:00:00Z');
const key = 'qa-pairing-key-not-production';
const stores: MatchStore[] = [],
  dirs: string[] = [];
afterEach(() => {
  for (const value of stores.splice(0)) value.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
function opened(path = ':memory:', secret = key, clock = () => initialTime) {
  const store = new MatchStore(path, secret, clock);
  stores.push(store);
  return store;
}
function setup(path = ':memory:', clock = () => initialTime) {
  const store = opened(path, key, clock);
  const snapshot = store.create({
    id: gameId,
    deviceId: phone,
    teams: {
      home: { name: 'Home', shortName: 'H', color: '#112233' },
      away: { name: 'Away', shortName: 'A', color: '#445566' },
    },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const credential = store.issueCredential(gameId, phone, 'score');
  return { store, snapshot, credential };
}
function ended(store: MatchStore, now: number) {
  expect(
    store.execute({
      commandId: randomUUID(),
      gameId,
      deviceId: phone,
      expectedRevision: 0,
      scorerEpoch: 1,
      issuedAt: new Date(now).toISOString(),
      operation: { type: 'end_match', reason: 'finished' },
    }).accepted,
  ).toBe(true);
}
function path() {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-pairing-'));
  dirs.push(dir);
  return join(dir, 'match.sqlite');
}

it('issues a score-only capability with stable fixed expiry and leaves match/media/scorer unchanged', () => {
  let now = initialTime;
  const { store, snapshot } = setup(':memory:', () => now);
  const media = store.media.get(gameId);
  const first = store.issueWatchPairing(gameId, issue);
  expect(first).toMatchObject({
    ...issue,
    gameId,
    role: 'score',
    expiresAt: '2026-09-14T01:05:00.000Z',
  });
  expect(first.pairingToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
  now += 10000;
  const retry = store.issueWatchPairing(gameId, issue);
  expect(retry.pairingToken).toBe(first.pairingToken);
  expect(retry.expiresAt).toBe(first.expiresAt);
  expect(store.get(gameId)).toEqual(snapshot);
  expect(store.media.get(gameId)).toEqual(media);
  expect(() => store.issueWatchPairing(gameId, { ...issue, watchDeviceId: randomUUID() })).toThrow(
    'pairing_id_reused',
  );
});

it('redeems atomically without takeover and exact retries recover even after expiry, end and restart', () => {
  let now = initialTime;
  const file = path();
  const { store, snapshot } = setup(file, () => now);
  const issued = store.issueWatchPairing(gameId, issue);
  const first = store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem);
  expect(first.credential).toMatchObject({ gameId, deviceId: watch, role: 'score' });
  expect(first.snapshot).toEqual(snapshot);
  expect(store.authenticate(gameId, first.credential.token)).toEqual({
    gameId,
    deviceId: watch,
    role: 'score',
  });
  expect(store.get(gameId)).toEqual(snapshot);
  ended(store, now);
  now += 600000;
  store.close();
  const restarted = opened(file, key, () => now);
  const retry = restarted.redeemWatchPairing(
    gameId,
    pairingId,
    issued.pairingToken,
    recovery,
    redeem,
  );
  expect(retry.credential).toEqual(first.credential);
  expect(retry.snapshot.status).toBe('ended');
  expect(restarted.issueWatchPairing(gameId, issue).pairingToken).toBe(issued.pairingToken);
  expect(() => restarted.issueWatchPairing(gameId, { ...issue, pairingId: randomUUID() })).toThrow(
    'match_ended',
  );
});

it('rejects new redemption exactly at expiry and after match end', () => {
  for (const stop of [false, true]) {
    let now = initialTime;
    const { store } = setup(':memory:', () => now);
    const issued = store.issueWatchPairing(gameId, issue);
    if (stop) ended(store, now);
    else now += 300000;
    expect(() =>
      store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
    ).toThrow(stop ? 'match_ended' : 'pairing_expired');
    expect(store.authenticate(gameId, issued.pairingToken)).toBeUndefined();
  }
});

it('durably expires unused capabilities across clock rollback, competing requests and reopen', () => {
  let now = initialTime;
  const file = path();
  const { store } = setup(file, () => now);
  const issued = store.issueWatchPairing(gameId, issue);
  const competitor = opened(file, key, () => initialTime);
  now += 300000;
  expect(() =>
    store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
  ).toThrow('pairing_expired');
  // A connection with an earlier clock cannot revive an expiry another connection committed.
  expect(() =>
    competitor.redeemWatchPairing(
      gameId,
      pairingId,
      issued.pairingToken,
      Buffer.alloc(32, 19).toString('base64url'),
      { ...redeem, redemptionId: randomUUID() },
    ),
  ).toThrow('pairing_expired');
  store.close();
  competitor.close();
  now = initialTime;
  const restarted = opened(file, key, () => now);
  expect(() =>
    restarted.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
  ).toThrow('pairing_expired');
  const db = new DatabaseSync(file);
  try {
    expect(
      db.prepare('SELECT COUNT(*) AS count FROM credentials WHERE device_id=?').get(watch),
    ).toEqual({ count: 0 });
  } finally {
    db.close();
  }
});

it('does not return definitive expiry if persisting its tombstone fails', async () => {
  let now = initialTime;
  const file = path();
  const { store } = setup(file, () => now);
  const issued = store.issueWatchPairing(gameId, issue);
  const db = new DatabaseSync(file);
  db.exec(`CREATE TRIGGER reject_expiry BEFORE UPDATE ON watch_pairings
    BEGIN SELECT RAISE(ABORT, 'injected_expiry_failure'); END;`);
  const { app } = createApp(testConfig(), {
    matches: store,
    log: { debug() {}, info() {}, warn() {}, error() {} },
  });
  now += 300000;
  const response = await app.request(`/v1/matches/${gameId}/watch-pairings/${pairingId}/redeem`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${issued.pairingToken}`,
      'X-Scorebug-Pairing-Recovery': recovery,
    },
    body: JSON.stringify(redeem),
  });
  try {
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: 'internal' });
    db.exec('DROP TRIGGER reject_expiry');
    now = initialTime;
    expect(
      store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem).credential
        .deviceId,
    ).toBe(watch);
  } finally {
    db.close();
  }
});

it('migrates development v3 pairing rows without losing issued capabilities or receipts', () => {
  const file = path();
  const { store } = setup(file);
  const issued = store.issueWatchPairing(gameId, issue);
  const receipt = store.redeemWatchPairing(
    gameId,
    pairingId,
    issued.pairingToken,
    recovery,
    redeem,
  );
  const unused = store.issueWatchPairing(gameId, { ...issue, pairingId: randomUUID() });
  store.close();
  const db = new DatabaseSync(file);
  try {
    const columns = db.prepare('PRAGMA table_info(watch_pairings)').all();
    if (columns.some((column) => column.name === 'expired'))
      db.exec('ALTER TABLE watch_pairings DROP COLUMN expired');
    db.exec('PRAGMA user_version=3');
  } finally {
    db.close();
  }
  const restarted = opened(file);
  expect(
    restarted.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem)
      .credential,
  ).toEqual(receipt.credential);
  expect(restarted.issueWatchPairing(gameId, { ...issue, pairingId: unused.pairingId })).toEqual(
    unused,
  );
  const migrated = new DatabaseSync(file);
  try {
    expect(migrated.prepare('PRAGMA user_version').get()).toEqual({ user_version: 4 });
    expect(migrated.prepare('SELECT expired FROM watch_pairings').all()).toEqual([
      { expired: 0 },
      { expired: 0 },
    ]);
  } finally {
    migrated.close();
  }
});

it('does not consume capabilities on wrong device and conflicts on changed redemption identity or key', () => {
  const { store } = setup();
  const issued = store.issueWatchPairing(gameId, issue);
  expect(() =>
    store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, {
      ...redeem,
      deviceId: randomUUID(),
    }),
  ).toThrow('pairing_device_mismatch');
  const first = store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem);
  for (const [body, secret] of [
    [{ ...redeem, redemptionId: randomUUID() }, recovery],
    [{ ...redeem, deviceId: randomUUID() }, recovery],
    [redeem, Buffer.alloc(32, 18).toString('base64url')],
  ] as const)
    expect(() =>
      store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, secret, body),
    ).toThrow('pairing_redemption_conflict');
  expect(
    store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem).credential,
  ).toEqual(first.credential);
});

it('reuses an existing device score credential without changing capture or match state', () => {
  const { store } = setup();
  const score = store.issueCredential(gameId, watch, 'score');
  const capture = store.issueCredential(gameId, watch, 'capture');
  const issued = store.issueWatchPairing(gameId, issue);
  expect(
    store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem).credential,
  ).toEqual(score);
  expect(store.authenticate(gameId, capture.token)?.role).toBe('capture');
  expect(store.issueCredential(gameId, watch, 'score')).toEqual(score);
});

it('retains all 64 pairing records, never evicts consumed or expired uncertainty', () => {
  let now = initialTime;
  const { store } = setup(':memory:', () => now);
  const first = store.issueWatchPairing(gameId, issue);
  store.redeemWatchPairing(gameId, pairingId, first.pairingToken, recovery, redeem);
  for (let index = 1; index < 64; index++)
    store.issueWatchPairing(gameId, { ...issue, pairingId: randomUUID() });
  now += 300001;
  expect(() => store.issueWatchPairing(gameId, { ...issue, pairingId: randomUUID() })).toThrow(
    'pairing_limit',
  );
  expect(store.issueWatchPairing(gameId, issue).pairingToken).toBe(first.pairingToken);
});

it('persists only hashes and canonical identities, never bearer or recovery secrets', () => {
  const file = path();
  const { store } = setup(file);
  const issued = store.issueWatchPairing(gameId, issue);
  const result = store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem);
  store.close();
  const db = new DatabaseSync(file);
  const rows = db.prepare('SELECT * FROM watch_pairings').all();
  db.close();
  const text = JSON.stringify(rows);
  for (const secret of [issued.pairingToken, recovery, result.credential.token]) {
    expect(text).not.toContain(secret);
    expect(readFileSync(file).includes(Buffer.from(secret))).toBe(false);
  }
  expect(text).toContain(createHash('sha256').update(recovery).digest('hex'));
});

it('fails closed after key rotation without rotating old receipts or an existing device credential', () => {
  const file = path();
  const { store } = setup(file);
  const issued = store.issueWatchPairing(gameId, issue);
  const old = store.redeemWatchPairing(
    gameId,
    pairingId,
    issued.pairingToken,
    recovery,
    redeem,
  ).credential;
  store.close();
  const rotated = opened(file, 'another-credential-key-long-enough');
  expect(() => rotated.issueWatchPairing(gameId, issue)).toThrow('pairing_key_changed');
  expect(() =>
    rotated.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
  ).toThrow('pairing_credential_changed');
  const newIssue = { ...issue, pairingId: randomUUID() };
  const newPair = rotated.issueWatchPairing(gameId, newIssue);
  expect(() =>
    rotated.redeemWatchPairing(gameId, newPair.pairingId, newPair.pairingToken, recovery, redeem),
  ).toThrow('pairing_credential_changed');
  expect(rotated.authenticate(gameId, old.token)?.deviceId).toBe(watch);
});

it('serializes competing redemptions across store connections and preserves the winner', async () => {
  const file = path();
  const { store } = setup(file);
  const issued = store.issueWatchPairing(gameId, issue);
  const other = opened(file);
  const results = await Promise.allSettled([
    Promise.resolve().then(() =>
      store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
    ),
    Promise.resolve().then(() =>
      other.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, {
        ...redeem,
        redemptionId: randomUUID(),
      }),
    ),
  ]);
  expect(results.map((r) => r.status)).toEqual(['fulfilled', 'rejected']);
  expect(
    other.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem).credential,
  ).toEqual((results[0] as PromiseFulfilledResult<any>).value.credential);
});

function routeFixture() {
  const f = setup();
  const config = testConfig();
  const { app } = createApp(config, { matches: f.store });
  const post = (
    route: string,
    body: unknown,
    token = config.PHONE_TOKEN,
    secret: string | null = recovery,
  ) =>
    app.request(`/v1/matches/${route}`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
        ...(secret === null ? {} : { 'X-Scorebug-Pairing-Recovery': secret }),
      },
      body: JSON.stringify(body),
    });
  return { ...f, config, post };
}
it('routes installation-only issuance and capability-only scoring redemption without leaking snapshots on errors', async () => {
  const f = routeFixture();
  const route = `${gameId}/watch-pairings`;
  for (const token of [
    'bad',
    f.credential.token,
    f.store.issueCredential(gameId, phone, 'capture').token,
    f.config.HOME_TOKEN,
  ]) {
    const response = await f.post(route, issue, token);
    expect(response.status).toBe(401);
    expect(await response.text()).not.toContain('snapshot');
  }
  const response = await f.post(route, issue);
  expect(response.status).toBe(201);
  const issued = await response.json();
  for (const target of [
    `${route}/${pairingId}/redeem`,
    `${randomUUID()}/watch-pairings/${pairingId}/redeem`,
  ]) {
    const invalid = await f.post(target, { bad: 'raw' }, 'wrong');
    expect(invalid.status).toBe(401);
    expect(await invalid.text()).not.toContain('snapshot');
  }
  for (const wrongRoute of [
    `${randomUUID()}/watch-pairings/${pairingId}/redeem`,
    `${route}/${randomUUID()}/redeem`,
  ]) {
    const wrong = await f.post(wrongRoute, redeem, issued.pairingToken);
    expect(wrong.status).toBe(401);
    expect(await wrong.text()).not.toContain('snapshot');
  }
  const result = await f.post(`${route}/${pairingId}/redeem`, redeem, issued.pairingToken);
  expect(result.status).toBe(200);
  expect((await result.json()).credential.role).toBe('score');
  const missing = await f.post(`${randomUUID()}/watch-pairings`, issue);
  expect(missing.status).toBe(409);
  expect(await missing.text()).not.toContain('snapshot');
  expect(
    (await f.post(`${gameId}/join`, { deviceId: watch, role: 'score' }, issued.pairingToken))
      .status,
  ).toBe(401);
});

it('rejects strict malformed issuance/redemption bodies and noncanonical recovery headers', async () => {
  const f = routeFixture();
  const route = `${gameId}/watch-pairings`;
  for (const body of [
    { ...issue, role: 'capture' },
    { ...issue, pairingId: 'short' },
    { ...issue, watchDeviceId: { raw: 'secret' } },
    { ...issue, nested: { token: 'raw' } },
    {},
  ])
    expect((await f.post(route, body)).status).toBe(400);
  const issued = await (await f.post(route, issue)).json();
  for (const body of [
    { ...redeem, role: 'capture' },
    { ...redeem, deviceId: 'short' },
    { ...redeem, redemptionId: 42 },
    { ...redeem, nested: { raw: 'secret' } },
    {},
  ])
    expect((await f.post(`${route}/${pairingId}/redeem`, body, issued.pairingToken)).status).toBe(
      400,
    );
  for (const secret of [null, 'short', '!'.repeat(43), 'B'.repeat(43)])
    expect(
      (await f.post(`${route}/${pairingId}/redeem`, redeem, issued.pairingToken, secret)).status,
    ).toBe(400);
  expect((await f.post(`${route}/${pairingId}/redeem`, redeem, issued.pairingToken)).status).toBe(
    200,
  );
});

it('fails closed for an unused capability minted before key rotation', () => {
  const file = path();
  const { store } = setup(file);
  const issued = store.issueWatchPairing(gameId, issue);
  store.close();
  const rotated = opened(file, 'rotated-key-for-unused-pairing');
  expect(() =>
    rotated.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
  ).toThrow('pairing_key_changed');
});

it('rolls back credential issuance if committing capability consumption fails', () => {
  const file = path();
  const { store } = setup(file);
  const issued = store.issueWatchPairing(gameId, issue);
  const db = new DatabaseSync(file);
  db.exec(
    "CREATE TRIGGER reject_redemption BEFORE UPDATE ON watch_pairings BEGIN SELECT RAISE(ABORT, 'injected'); END",
  );
  expect(() =>
    store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
  ).toThrow('injected');
  expect(
    db.prepare('SELECT 1 FROM credentials WHERE game_id=? AND device_id=?').get(gameId, watch),
  ).toBeUndefined();
  expect(db.prepare('SELECT redemption_request FROM watch_pairings').get()).toMatchObject({
    redemption_request: null,
  });
  db.exec('DROP TRIGGER reject_redemption');
  db.close();
  expect(
    store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem).credential
      .deviceId,
  ).toBe(watch);
});

it('matches the canonical issued/redeemed fixture consumed by native clients', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../packages/protocol/fixtures/watch-pairing-v1.json', import.meta.url),
      'utf8',
    ),
  );
  const { store } = setup();
  const issued = store.issueWatchPairing(gameId, issue);
  expect(issued).toEqual(fixture.issued);
  expect(
    store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
  ).toEqual({
    ...fixture.redeemed,
    // The shared v1 fixture predates scorebugStyle; native decoders ignore it.
    snapshot: { ...fixture.redeemed.snapshot, scorebugStyle: 'bar' },
  });
});

it('commits exactly one winner when independent Node processes redeem concurrently', async () => {
  const file = path();
  const { store } = setup(file);
  const issued = store.issueWatchPairing(gameId, issue);
  const workerPath = join(file, '..', 'redeemer.mjs');
  writeFileSync(
    workerPath,
    `
    import {MatchStore} from ${JSON.stringify(new URL('../src/matches-store.ts', import.meta.url).href)};
    process.send({ready:true});
    process.once('message', data => {
      const store=new MatchStore(data.file,data.key,()=>data.now);
      let result;
      try { const value=store.redeemWatchPairing(data.gameId,data.pairingId,data.token,data.recovery,data.redeem); result={ok:true,redemptionId:value.redemptionId}; }
      catch(error) { result={ok:false,code:error.code}; }
      store.close();
      process.send(result,()=>process.disconnect());
    });
  `,
  );
  const children = [0, 1].map(() => {
    const child = fork(workerPath, [], {
      execArgv: ['--import', import.meta.resolve('tsx')],
      stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
    });
    let ready!: () => void;
    const entered = new Promise<void>((resolve, reject) => {
      ready = resolve;
      child.once('error', reject);
      child.once('exit', () => reject(new Error('Pairing fixture exited before readiness')));
    });
    const result = new Promise<{ ok: boolean; redemptionId?: string; code?: string }>(
      (resolve, reject) => {
        child.once('error', reject);
        child.on('message', (message: any) => {
          if (message.ready) ready();
          else resolve(message);
        });
      },
    );
    return { child, entered, result };
  });
  try {
    await Promise.all(children.map((value) => value.entered));
    for (const [index, { child }] of children.entries())
      child.send({
        file,
        key,
        now: initialTime,
        gameId,
        pairingId,
        token: issued.pairingToken,
        recovery,
        redeem: { ...redeem, redemptionId: index === 0 ? redemptionId : randomUUID() },
      });
    const results = await Promise.all(children.map((value) => value.result));
    expect(results.filter((value) => value.ok)).toHaveLength(1);
    expect(results.find((value) => !value.ok)?.code).toBe('pairing_redemption_conflict');
    const winner = results.find((value) => value.ok)!;
    expect(
      store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, {
        ...redeem,
        redemptionId: winner.redemptionId!,
      }).credential.deviceId,
    ).toBe(watch);
  } finally {
    for (const { child } of children) child.kill();
  }
});

it('identifies an unused expired capability even when its match has ended', () => {
  let now = initialTime;
  const { store } = setup(':memory:', () => now);
  const issued = store.issueWatchPairing(gameId, issue);
  ended(store, now);
  now += 300000;
  expect(() =>
    store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem),
  ).toThrow('pairing_expired');
});

it('does not change an active recording, selected broadcast, scorer, or match revision', () => {
  const { store } = setup();
  const capture = store.issueCredential(gameId, phone, 'capture');
  const recordingId = randomUUID();
  store.media.reportRecording(gameId, phone, {
    recordingId,
    sequence: 1,
    status: 'recording',
    startedAt: new Date(initialTime).toISOString(),
  });
  expect(
    store.media.execute({
      commandId: randomUUID(),
      gameId,
      expectedGeneration: 0,
      issuedAt: new Date(initialTime).toISOString(),
      operation: {
        type: 'start',
        selection: { workerId: 'worker', outputId: 'output', captureDeviceId: phone, recordingId },
      },
    }).accepted,
  ).toBe(true);
  const before = { match: store.get(gameId), media: store.media.get(gameId) };
  const issued = store.issueWatchPairing(gameId, issue);
  store.redeemWatchPairing(gameId, pairingId, issued.pairingToken, recovery, redeem);
  expect({ match: store.get(gameId), media: store.media.get(gameId) }).toEqual(before);
  expect(store.authenticate(gameId, capture.token)?.role).toBe('capture');
});
