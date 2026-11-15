import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { afterEach, expect, it } from 'vitest';
import { MatchStore } from '../src/matches-store.js';

const now = Date.parse('2026-09-14T03:00:00Z');
const issuedAt = new Date(now).toISOString();
const selection = {
  workerId: 'mac',
  outputId: 'local-sink',
  captureDeviceId: 'phone',
  recordingId: 'archive-1',
};
const start = {
  commandId: 'start-1',
  gameId: 'match',
  expectedGeneration: 0,
  issuedAt,
  operation: { type: 'start' as const, selection },
};
const report = {
  recordingId: 'archive-1',
  sequence: 0,
  status: 'recording' as const,
  startedAt: issuedAt,
};
const stores: MatchStore[] = [];
const directories: string[] = [];
afterEach(() => {
  stores.splice(0).forEach((value) => value.close());
  directories.splice(0).forEach((dir) => rmSync(dir, { recursive: true, force: true }));
});
function open(path = ':memory:', clock = () => now) {
  const value = new MatchStore(path, 'qa-media-key-not-production', clock);
  stores.push(value);
  return value;
}
function databasePath() {
  const dir = mkdtempSync(join(tmpdir(), 'scorebug-media-'));
  directories.push(dir);
  return join(dir, 'match.sqlite');
}
function create(db: MatchStore) {
  const team = { name: 'Team', shortName: 'T', color: '#123456' };
  db.create({
    id: 'match',
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  db.issueCredential('match', 'scorer', 'score');
  db.issueCredential('match', 'phone', 'capture');
}
function recording(db: MatchStore) {
  return db.media.reportRecording('match', 'phone', report);
}

it('persists independent recording association without changing the scoring revision', () => {
  const path = databasePath();
  const first = open(path);
  create(first);
  const recorded = recording(first);
  expect(first.get('match')?.revision).toBe(0);
  expect(first.media.get('match').broadcast.desired).toBe('stopped');
  first.close();
  const second = open(path);
  expect(second.media.get('match').recordings).toEqual([recorded]);
  expect(second.media.reportRecording('match', 'phone', report)).toEqual(recorded);
});
it('accepts only recording reports from a registered capture device', () => {
  const db = open();
  create(db);
  expect(() => db.media.reportRecording('match', 'scorer', report)).toThrow(
    'capture_access_required',
  );
  recording(db);
  db.issueCredential('match', 'other', 'capture');
  expect(() => db.media.reportRecording('match', 'other', { ...report, sequence: 1 })).toThrow(
    'recording_ownership_mismatch',
  );
});
it('persists broadcast command receipts and rejects older/new-generation conflicts without replay', () => {
  let clock = now;
  const path = databasePath();
  const first = open(path, () => clock);
  create(first);
  recording(first);
  const accepted = first.media.execute(start);
  expect(accepted.accepted).toBe(true);
  expect(first.get('match')).toMatchObject({
    revision: 1,
    broadcast: { desired: 'running', generation: 1 },
  });
  const stopped = first.media.execute({
    ...start,
    commandId: 'stop',
    expectedGeneration: 1,
    operation: { type: 'stop' },
  });
  expect(stopped.snapshot.broadcast).toMatchObject({ desired: 'stopped', generation: 2 });
  first.close();
  clock += 60_000;
  const second = open(path, () => clock);
  expect(second.media.execute(start)).toEqual(accepted);
  expect(second.media.receipt('match', 'start-1')).toEqual(accepted);
  expect(
    second.media.execute({ ...start, commandId: 'late', issuedAt: new Date(clock).toISOString() })
      .error,
  ).toBe('generation_conflict');
  expect(second.media.get('match').broadcast.desired).toBe('stopped');
  expect(second.media.get('match').recordings[0]?.status).toBe('recording');
});
it('does not replace an original receipt when a broadcast command ID is reused', () => {
  const db = open();
  create(db);
  recording(db);
  const original = db.media.execute(start);
  expect(db.media.execute({ ...start, operation: { type: 'stop' } }).error).toBe(
    'command_id_reused',
  );
  expect(db.media.receipt('match', start.commandId)).toEqual(original);
});
it('ends the match and stops broadcast atomically while local recording continues', () => {
  const db = open();
  create(db);
  recording(db);
  db.media.execute(start);
  const ended = db.execute({
    commandId: 'end',
    gameId: 'match',
    deviceId: 'scorer',
    expectedRevision: 1,
    scorerEpoch: 1,
    issuedAt,
    operation: { type: 'end_match', reason: 'Finished' },
  });
  expect(ended.accepted).toBe(true);
  expect(ended.snapshot.broadcast).toEqual({ desired: 'stopped', generation: 2 });
  expect(db.media.get('match').broadcast).toMatchObject({ desired: 'stopped', generation: 2 });
  expect(db.media.get('match').recordings[0]?.status).toBe('recording');
  expect(
    db.media.reportRecording('match', 'phone', { ...report, sequence: 1, status: 'stopped' })
      .status,
  ).toBe('stopped');
  expect(db.media.execute({ ...start, commandId: 'restart', expectedGeneration: 2 }).error).toBe(
    'match_ended',
  );
});
it('rolls back both broadcast state and the match summary when receipt persistence fails', () => {
  const path = databasePath();
  const db = open(path);
  create(db);
  recording(db);
  const probe = new DatabaseSync(path);
  try {
    probe.exec(
      "CREATE TRIGGER fail_media_receipt BEFORE INSERT ON media_commands BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;",
    );
    expect(() => db.media.execute(start)).toThrow('fixture failure');
    expect(db.media.get('match').broadcast.generation).toBe(0);
    expect(db.get('match')?.revision).toBe(0);
    expect(db.media.receipt('match', start.commandId)).toBeUndefined();
  } finally {
    probe.close();
  }
});
it('rolls back broadcast stop when a match-end receipt cannot be saved', () => {
  const path = databasePath();
  const db = open(path);
  create(db);
  recording(db);
  db.media.execute(start);
  const probe = new DatabaseSync(path);
  try {
    probe.exec(
      "CREATE TRIGGER fail_match_receipt BEFORE INSERT ON commands BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;",
    );
    expect(() =>
      db.execute({
        commandId: 'end',
        gameId: 'match',
        deviceId: 'scorer',
        expectedRevision: 1,
        scorerEpoch: 1,
        issuedAt,
        operation: { type: 'end_match', reason: 'Finished' },
      }),
    ).toThrow('fixture failure');
    expect(db.get('match')?.status).toBe('active');
    expect(db.media.get('match').broadcast).toMatchObject({ desired: 'running', generation: 1 });
  } finally {
    probe.close();
  }
});
it('upgrades the previous database layout without losing scoring credentials or state', () => {
  const path = databasePath();
  const first = open(path);
  create(first);
  const credential = first.issueCredential('match', 'scorer', 'score');
  const point = {
    commandId: 'before-upgrade',
    gameId: 'match',
    deviceId: 'scorer',
    expectedRevision: 0,
    scorerEpoch: 1,
    issuedAt,
    operation: { type: 'award_point' as const, side: 'home' as const },
  };
  const receipt = first.execute(point);
  first.close();
  const previous = new DatabaseSync(path);
  previous.exec(
    'DROP TABLE IF EXISTS media_commands; DROP TABLE IF EXISTS media_broadcasts; DROP TABLE IF EXISTS recordings; PRAGMA user_version=1;',
  );
  previous.close();
  const upgraded = open(path);
  expect(upgraded.get('match')?.scorer.deviceId).toBe('scorer');
  expect(upgraded.authenticate('match', credential.token)?.deviceId).toBe('scorer');
  expect(upgraded.receipt('match', 'scorer', point.commandId)).toEqual(receipt);
  expect(upgraded.execute(point)).toEqual(receipt);
  expect(upgraded.get('match')).toMatchObject({ revision: 1, score: { home: 1 } });
  expect(recording(upgraded).recordingId).toBe('archive-1');
  expect(upgraded.media.get('match').broadcast).toEqual({
    desired: 'stopped',
    generation: 0,
    selection: null,
  });
});

it('matches the media JSON fixture shared with native clients', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../packages/protocol/fixtures/media-v1.json', import.meta.url),
      'utf8',
    ),
  );
  const db = open();
  create(db);
  expect(db.media.reportRecording('match', 'phone', fixture.recordingReport)).toEqual(
    fixture.recordingResponse.recording,
  );
  expect(db.media.get('match')).toEqual(fixture.snapshotResponse.snapshot);
  expect(db.media.execute(fixture.command)).toEqual(fixture.outcome);
});
it('serializes competing broadcasts through separate SQLite connections', () => {
  const path = databasePath();
  const first = open(path);
  create(first);
  recording(first);
  const second = open(path);
  expect(first.media.execute(start).accepted).toBe(true);
  expect(
    second.media.execute({
      ...start,
      commandId: 'competing',
      operation: { type: 'start', selection: { ...selection, workerId: 'cloud' } },
    }).error,
  ).toBe('generation_conflict');
  expect(second.media.workerAssignment('mac')?.media.broadcast.generation).toBe(1);
  expect(second.media.workerAssignment('cloud')).toBeNull();
});
