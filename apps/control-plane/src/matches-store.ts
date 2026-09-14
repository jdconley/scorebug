import { createHash, createHmac } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type {
  CommandOutcome,
  MatchCommand,
  MatchCredential,
  MatchRules,
  MatchSnapshot,
  ScoringState,
  Teams,
} from '@scorebug/protocol';
import { canonical } from './canonical-json.js';
import { MediaStore } from './media-store.js';
import { applyScoringOperation, initialScoringState, ScoringError } from './scoring.js';

export type CreateMatch = { id: string; deviceId: string; teams: Teams; rules: MatchRules };
type StoredMatch = Omit<
  MatchSnapshot,
  'score' | 'completedSets' | 'canUndo' | 'endReason' | 'status'
> & { scoring: ScoringState; creationRequest: string };
export class MatchStoreError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
const digest = (token: string) => createHash('sha256').update(token).digest('hex');
function snapshot(match: StoredMatch): MatchSnapshot {
  return {
    id: match.id,
    createdAt: match.createdAt,
    revision: match.revision,
    teams: match.teams,
    rules: match.rules,
    score: match.scoring.score,
    completedSets: match.scoring.completedSets,
    status: match.scoring.status,
    endReason: match.scoring.endReason,
    canUndo: match.scoring.status === 'active' && match.scoring.history.length > 0,
    scorer: match.scorer,
    broadcast: match.broadcast,
  };
}

/** Synchronous transactions serialize all commands, including competing processes. */
export class MatchStore {
  private readonly db: DatabaseSync;
  readonly media: MediaStore;
  private closed = false;
  constructor(
    path: string,
    private readonly credentialKey: string,
    private readonly now: () => number = Date.now,
  ) {
    if (credentialKey.length < 16) throw new MatchStoreError('credential_key_too_short');
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    try {
      this.db.exec(
        'PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;',
      );
      const version = this.db.prepare('PRAGMA user_version').get() as { user_version: number };
      if (version.user_version > 2) throw new MatchStoreError('unsupported_database_version');
      this.transaction(() => {
        this.db.exec(`
          CREATE TABLE IF NOT EXISTS matches(id TEXT PRIMARY KEY, status TEXT NOT NULL, data TEXT NOT NULL);
          CREATE UNIQUE INDEX IF NOT EXISTS one_active_match ON matches(status) WHERE status='active';
          CREATE TABLE IF NOT EXISTS credentials(game_id TEXT NOT NULL REFERENCES matches(id), device_id TEXT NOT NULL,
            role TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, PRIMARY KEY(game_id, device_id, role));
          CREATE TABLE IF NOT EXISTS commands(game_id TEXT NOT NULL REFERENCES matches(id), device_id TEXT NOT NULL,
            command_id TEXT NOT NULL, request TEXT NOT NULL, outcome TEXT NOT NULL, PRIMARY KEY(game_id, device_id, command_id));

        `);
        MediaStore.migrate(this.db);
        this.db.exec('PRAGMA user_version=2;');
      });
      this.media = new MediaStore(this.db, {
        transaction: (body) => this.transaction(body),
        match: (id) => this.get(id),
        active: () => this.active(),
        updateBroadcast: (id, broadcast) => {
          const match = this.load(id);
          match.broadcast = { desired: broadcast.desired, generation: broadcast.generation };
          match.revision++;
          this.save(match);
        },
        now: this.now,
      });
    } catch (error) {
      this.db.close();
      this.closed = true;
      throw error;
    }
  }
  close(): void {
    if (!this.closed) {
      this.db.close();
      this.closed = true;
    }
  }
  private transaction<T>(body: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = body();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }
  private load(id: string): StoredMatch {
    const row = this.db.prepare('SELECT data FROM matches WHERE id=?').get(id) as
      | { data: string }
      | undefined;
    if (!row) throw new MatchStoreError('match_not_found');
    return JSON.parse(row.data) as StoredMatch;
  }
  private save(match: StoredMatch): void {
    this.db
      .prepare('UPDATE matches SET status=?,data=? WHERE id=?')
      .run(match.scoring.status, JSON.stringify(match), match.id);
  }
  get(id: string): MatchSnapshot | undefined {
    try {
      return snapshot(this.load(id));
    } catch (error) {
      if (error instanceof MatchStoreError && error.code === 'match_not_found') return undefined;
      throw error;
    }
  }
  active(): MatchSnapshot | undefined {
    const row = this.db.prepare("SELECT data FROM matches WHERE status='active'").get() as
      | { data: string }
      | undefined;
    return row ? snapshot(JSON.parse(row.data) as StoredMatch) : undefined;
  }
  create(input: CreateMatch): MatchSnapshot {
    return this.transaction(() => {
      if (this.get(input.id)) {
        const match = this.load(input.id);
        if (match.creationRequest !== canonical(input))
          throw new MatchStoreError('match_id_reused');
        return snapshot(match);
      }
      if (this.active()) throw new MatchStoreError('match_in_flight');
      const match: StoredMatch = {
        id: input.id,
        createdAt: new Date(this.now()).toISOString(),
        teams: input.teams,
        rules: input.rules,
        revision: 0,
        scoring: initialScoringState(),
        scorer: { deviceId: input.deviceId, epoch: 1 },
        broadcast: { desired: 'stopped', generation: 0 },
        creationRequest: canonical(input),
      };
      this.db
        .prepare('INSERT INTO matches(id,status,data) VALUES(?,?,?)')
        .run(input.id, 'active', JSON.stringify(match));
      return snapshot(match);
    });
  }
  issueCredential(
    gameId: string,
    deviceId: string,
    role: MatchCredential['role'],
  ): MatchCredential {
    return this.transaction(() => {
      this.load(gameId);
      // Stable per-role token makes lost create/join replies safe to retry. The
      // installation secret stays outside SQLite; only its token digest is stored.
      const token = createHmac('sha256', this.credentialKey)
        .update(canonical(['scorebug-scoped-credential-v1', gameId, deviceId, role]))
        .digest('base64url');
      this.db
        .prepare(
          `INSERT INTO credentials(game_id,device_id,role,token_hash) VALUES(?,?,?,?)
        ON CONFLICT(game_id,device_id,role) DO UPDATE SET token_hash=excluded.token_hash`,
        )
        .run(gameId, deviceId, role, digest(token));
      return { gameId, deviceId, role, token };
    });
  }
  authenticate(gameId: string, token: string): Omit<MatchCredential, 'token'> | undefined {
    const row = this.db
      .prepare('SELECT device_id,role FROM credentials WHERE game_id=? AND token_hash=?')
      .get(gameId, digest(token)) as
      | { device_id: string; role: MatchCredential['role'] }
      | undefined;
    return row ? { gameId, deviceId: row.device_id, role: row.role } : undefined;
  }
  receipt(gameId: string, deviceId: string, commandId: string): CommandOutcome | undefined {
    const row = this.db
      .prepare('SELECT outcome FROM commands WHERE game_id=? AND device_id=? AND command_id=?')
      .get(gameId, deviceId, commandId) as { outcome: string } | undefined;
    return row ? (JSON.parse(row.outcome) as CommandOutcome) : undefined;
  }
  execute(command: MatchCommand): CommandOutcome {
    return this.transaction(() => {
      const match = this.load(command.gameId);
      const request = canonical(command);
      const existing = this.db
        .prepare(
          'SELECT request,outcome FROM commands WHERE game_id=? AND device_id=? AND command_id=?',
        )
        .get(command.gameId, command.deviceId, command.commandId) as
        | { request: string; outcome: string }
        | undefined;
      if (existing)
        return existing.request === request
          ? (JSON.parse(existing.outcome) as CommandOutcome)
          : {
              commandId: command.commandId,
              accepted: false,
              error: 'command_id_reused',
              snapshot: snapshot(match),
            };
      let error: string | null = null;
      const canScore = this.db
        .prepare("SELECT 1 FROM credentials WHERE game_id=? AND device_id=? AND role='score'")
        .get(command.gameId, command.deviceId);
      const age = this.now() - Date.parse(command.issuedAt);
      if (!canScore) error = 'scoring_access_required';
      else if (match.scoring.status === 'ended') error = 'match_ended';
      else if (!Number.isFinite(age) || age < -5000) error = 'clock_skew';
      else if (age > 10_000) error = 'command_expired';
      else if (command.expectedRevision !== match.revision) error = 'revision_conflict';
      else if (
        command.operation.type !== 'take_over' &&
        (command.deviceId !== match.scorer.deviceId || command.scorerEpoch !== match.scorer.epoch)
      )
        error = 'scorer_changed';
      else if (command.operation.type === 'take_over' && command.scorerEpoch !== match.scorer.epoch)
        error = 'scorer_changed';
      else {
        try {
          if (command.operation.type === 'take_over')
            match.scorer = { deviceId: command.deviceId, epoch: match.scorer.epoch + 1 };
          else match.scoring = applyScoringOperation(match.scoring, match.rules, command.operation);
          if (match.scoring.status === 'ended') {
            match.broadcast = { desired: 'stopped', generation: match.broadcast.generation + 1 };
            this.media.stopForMatchEndWithinTransaction(match.id, match.broadcast.generation);
          }
          match.revision++;
          this.save(match);
        } catch (cause) {
          if (cause instanceof ScoringError) error = cause.code;
          else throw cause;
        }
      }
      const outcome: CommandOutcome = {
        commandId: command.commandId,
        accepted: error === null,
        error,
        snapshot: snapshot(match),
      };
      this.db
        .prepare(
          'INSERT INTO commands(game_id,device_id,command_id,request,outcome) VALUES(?,?,?,?,?)',
        )
        .run(command.gameId, command.deviceId, command.commandId, request, JSON.stringify(outcome));
      return outcome;
    });
  }
}
