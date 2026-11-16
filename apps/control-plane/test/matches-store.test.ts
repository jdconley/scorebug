import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { afterEach, expect, it } from 'vitest';
import type { MatchCommand } from '@scorebug/protocol';
import { MatchStore } from '../src/matches-store.js';
import { openNodeSqlite } from '../src/sql-node.js';

const teams = {
  home: { name: 'Home', shortName: 'H', color: '#112233' },
  away: { name: 'Away', shortName: 'A', color: '#445566' },
};
const rules = {
  bestOf: 3 as const,
  pointsToWin: 25,
  decidingPointsToWin: 15,
  winBy: 2,
  pointCap: null,
};
const now = Date.parse('2026-09-14T01:00:00Z');
const stores: MatchStore[] = [];
const dirs: string[] = [];
afterEach(() => {
  for (const store of stores.splice(0)) store.close();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
function store(path = ':memory:') {
  const value = new MatchStore(openNodeSqlite(path), 'qa-credential-key-not-production', () => now);
  stores.push(value);
  return value;
}
function created(db: MatchStore) {
  db.create({ id: 'game-1', deviceId: 'phone-a', teams, rules });
  return db.issueCredential('game-1', 'phone-a', 'score');
}
function command(overrides: Partial<MatchCommand> = {}): MatchCommand {
  return {
    commandId: 'point-1',
    gameId: 'game-1',
    deviceId: 'phone-a',
    expectedRevision: 0,
    scorerEpoch: 1,
    issuedAt: new Date(now).toISOString(),
    operation: { type: 'award_point', side: 'home' },
    ...overrides,
  };
}

it('persists match, scorer, credential and applied command across a database reopen', () => {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-db-'));
  dirs.push(dir);
  const path = join(dir, 'matches.sqlite');
  const first = store(path);
  const credential = created(first);
  const result = first.execute(command());
  expect(result.accepted).toBe(true);
  first.close();
  const second = store(path);
  expect(second.active()?.score.home).toBe(1);
  expect(second.authenticate('game-1', credential.token)?.deviceId).toBe('phone-a');
  expect(second.execute(command())).toEqual(result);
  expect(second.get('game-1')?.revision).toBe(1);
  expect(readFileSync(path).includes(Buffer.from(credential.token))).toBe(false);
});
it('deduplicates before revision and expiry checks and returns the original receipt', () => {
  const db = store();
  created(db);
  const first = db.execute(command());
  db.execute(command({ commandId: 'point-2', expectedRevision: 1 }));
  expect(db.execute(command())).toEqual(first);
  expect(db.get('game-1')?.score.home).toBe(2);
  expect(db.receipt('game-1', 'phone-a', 'point-1')).toEqual(first);
});
it('rejects reuse of a command ID with changed content without overwriting its receipt', () => {
  const db = store();
  created(db);
  const first = db.execute(command());
  const second = db.execute(command({ operation: { type: 'award_point', side: 'away' } }));
  expect(second.error).toBe('command_id_reused');
  expect(db.receipt('game-1', 'phone-a', 'point-1')).toEqual(first);
});
it('serializes takeover against revision and rejects delayed commands from the old scorer', () => {
  const db = store();
  created(db);
  db.issueCredential('game-1', 'phone-b', 'score');
  db.issueCredential('game-1', 'watch-c', 'score');
  const takeover = db.execute(command({ deviceId: 'phone-b', operation: { type: 'take_over' } }));
  expect(takeover.accepted).toBe(true);
  expect(takeover.snapshot.scorer).toEqual({ deviceId: 'phone-b', epoch: 2 });
  expect(db.execute(command({ deviceId: 'watch-c', operation: { type: 'take_over' } })).error).toBe(
    'revision_conflict',
  );
  expect(db.execute(command({ commandId: 'late', expectedRevision: 1 })).error).toBe(
    'scorer_changed',
  );
  expect(
    db.execute(
      command({
        commandId: 'next-point',
        deviceId: 'phone-b',
        expectedRevision: 1,
        scorerEpoch: 2,
      }),
    ).accepted,
  ).toBe(true);
});
it('rejects stale new points but permits querying an uncertain applied command', () => {
  const db = store();
  created(db);
  expect(db.execute(command({ issuedAt: new Date(now - 10_001).toISOString() })).error).toBe(
    'command_expired',
  );
  expect(db.get('game-1')?.revision).toBe(0);
});
it('does not let a capture-only credential acquire scoring authority', () => {
  const db = store();
  created(db);
  db.issueCredential('game-1', 'camera', 'capture');
  expect(db.execute(command({ deviceId: 'camera', operation: { type: 'take_over' } })).error).toBe(
    'scoring_access_required',
  );
});
it('enforces one active match and makes retried creation idempotent', () => {
  const db = store();
  created(db);
  db.execute(command());
  expect(db.create({ id: 'game-1', deviceId: 'phone-a', teams, rules }).revision).toBe(1);
  expect(() => db.create({ id: 'game-2', deviceId: 'phone-a', teams, rules })).toThrow(
    'match_in_flight',
  );
});
it('rolls back score and receipt together if the transaction cannot persist the outcome', () => {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-rollback-'));
  dirs.push(dir);
  const path = join(dir, 'matches.sqlite');
  const db = store(path);
  created(db);
  // A separate connection installs a failure at the durable receipt boundary.
  const { DatabaseSync } = require('node:sqlite');
  const probe = new DatabaseSync(path);
  probe.exec(
    "CREATE TRIGGER fail_receipt BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;",
  );
  expect(() => db.execute(command())).toThrow('fixture failure');
  expect(db.get('game-1')?.score.home).toBe(0);
  expect(db.receipt('game-1', 'phone-a', 'point-1')).toBeUndefined();
  probe.close();
});
it('preserves a receipt after expiry and a later scorer takeover', () => {
  let clock = now;
  const db = new MatchStore(
    openNodeSqlite(':memory:'),
    'qa-credential-key-not-production',
    () => clock,
  );
  stores.push(db);
  created(db);
  const first = db.execute(command());
  db.issueCredential('game-1', 'phone-b', 'score');
  db.execute(
    command({
      commandId: 'takeover',
      deviceId: 'phone-b',
      expectedRevision: 1,
      operation: { type: 'take_over' },
    }),
  );
  clock += 60_000;
  expect(db.execute(command())).toEqual(first);
  expect(db.get('game-1')?.scorer.deviceId).toBe('phone-b');
});
it('uses the same scoped credential after reopening with the installation key', () => {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-credential-'));
  dirs.push(dir);
  const path = join(dir, 'match.sqlite');
  const first = store(path);
  const credential = created(first);
  first.close();
  expect(store(path).issueCredential('game-1', 'phone-a', 'score')).toEqual(credential);
});
it('serializes conflicting takeovers through separate SQLite connections', () => {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-takeover-'));
  dirs.push(dir);
  const path = join(dir, 'match.sqlite');
  const first = store(path);
  created(first);
  first.issueCredential('game-1', 'phone-b', 'score');
  first.issueCredential('game-1', 'watch-c', 'score');
  const second = store(path);
  expect(
    first.execute(command({ deviceId: 'phone-b', operation: { type: 'take_over' } })).accepted,
  ).toBe(true);
  expect(
    second.execute(command({ deviceId: 'watch-c', operation: { type: 'take_over' } })).error,
  ).toBe('revision_conflict');
  expect(second.get('game-1')?.scorer.deviceId).toBe('phone-b');
});
it('matches the shared native/TypeScript JSON contract fixture', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../packages/protocol/fixtures/match-v1.json', import.meta.url),
      'utf8',
    ),
  );
  // The shared v1 fixture is mirrored byte-for-byte in the Swift test bundle and
  // carries scorebugStyle, pendingSetEnd and output, which the Swift app decodes.
  const db = store();
  expect(db.create(fixture.creation)).toEqual(fixture.snapshot);
  db.issueCredential(fixture.creation.id, fixture.creation.deviceId, 'score');
  expect(db.execute(fixture.command)).toEqual(fixture.outcome);
});
it('keeps the scorebug style outside scoring history and requires the current scorer', () => {
  const db = store();
  created(db);
  expect(db.get('game-1')?.scorebugStyle).toBe('bar');
  db.execute(command());
  db.issueCredential('game-1', 'watch-b', 'score');
  expect(
    db.execute(
      command({
        commandId: 'style-other',
        deviceId: 'watch-b',
        expectedRevision: 1,
        operation: { type: 'set_scorebug_style', style: 'lowerThird' },
      }),
    ).error,
  ).toBe('scorer_changed');
  const styled = db.execute(
    command({
      commandId: 'style-1',
      expectedRevision: 1,
      operation: { type: 'set_scorebug_style', style: 'lowerThird' },
    }),
  );
  expect(styled.accepted).toBe(true);
  expect(styled.snapshot).toMatchObject({ scorebugStyle: 'lowerThird', revision: 2 });
  const undone = db.execute(
    command({ commandId: 'undo-1', expectedRevision: 2, operation: { type: 'undo' } }),
  );
  expect(undone.snapshot).toMatchObject({
    scorebugStyle: 'lowerThird',
    score: { home: 0 },
    canUndo: false,
  });
});
it('reads matches stored before scorebug styles existed as the default bar style', () => {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-db-'));
  dirs.push(dir);
  const path = join(dir, 'matches.sqlite');
  const first = store(path);
  first.create({ id: 'game-1', deviceId: 'phone-a', teams, rules, scorebugStyle: 'setCard' });
  first.close();
  const legacy = new DatabaseSync(path);
  const row = legacy.prepare('SELECT data FROM matches WHERE id=?').get('game-1') as {
    data: string;
  };
  const data = JSON.parse(row.data) as Record<string, unknown>;
  delete data.scorebugStyle;
  legacy.prepare('UPDATE matches SET data=? WHERE id=?').run(JSON.stringify(data), 'game-1');
  legacy.close();
  expect(store(path).get('game-1')?.scorebugStyle).toBe('bar');
});
it('drops the retired watch_pairings table from an existing database', () => {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-db-'));
  dirs.push(dir);
  const path = join(dir, 'matches.sqlite');
  const first = store(path);
  first.create({ id: 'game-1', deviceId: 'phone-a', teams, rules });
  first.close();
  const old = new DatabaseSync(path);
  old.exec(`CREATE TABLE watch_pairings(game_id TEXT NOT NULL REFERENCES matches(id), pairing_id TEXT NOT NULL,
    PRIMARY KEY(game_id,pairing_id));
    INSERT INTO watch_pairings VALUES('game-1','pairing');`);
  old.close();
  expect(store(path).get('game-1')?.id).toBe('game-1');
  const reopened = new DatabaseSync(path);
  expect(
    reopened.prepare("SELECT name FROM sqlite_master WHERE name='watch_pairings'").all(),
  ).toEqual([]);
  reopened.close();
});
