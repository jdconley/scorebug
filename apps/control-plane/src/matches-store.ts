import {
  createHash,
  createHmac,
  randomBytes,
  randomInt,
  randomUUID,
  timingSafeEqual,
} from 'node:crypto';
import type {
  CommandOutcome,
  InviteRedeemRequest,
  MatchCommand,
  MatchInvite,
  MatchOutput,
  MatchCredential,
  MatchRules,
  MatchSnapshot,
  ScorebugStyle,
  ScoringState,
  Teams,
  WorkerOutputAssignment,
} from '@scorebug/protocol';
import {
  DEFAULT_SCOREBUG_STYLE,
  INVITE_CODE_ALPHABET,
  INVITE_CODE_LENGTH,
  normalizeInviteCode,
} from '@scorebug/protocol';
import { canonical } from './canonical-json.js';
import { MediaStore } from './media-store.js';
import type { SqlDb } from './sql.js';
import {
  applyScoringOperation,
  initialScoringState,
  pendingSetEnd,
  ScoringError,
} from './scoring.js';

export type CreateMatch = {
  id: string;
  deviceId: string;
  teams: Teams;
  rules: MatchRules;
  scorebugStyle?: ScorebugStyle | undefined;
  recordOnly?: boolean | undefined;
};
const SCHEMA_VERSION = 5;
export const INVITE_TTL_MS = 6 * 60 * 60 * 1000;
const NO_OUTPUT: MatchOutput = { destinationId: null, recordOnly: false };
// Match rows are JSON documents: rows written before scorebugStyle existed lack
// the field and read back as the default style, so no SQL migration is needed.
// Rows from before match outputs lack `output` and read back as NO_OUTPUT.
type StoredMatch = Omit<
  MatchSnapshot,
  | 'score'
  | 'completedSets'
  | 'canUndo'
  | 'endReason'
  | 'status'
  | 'scorebugStyle'
  | 'pendingSetEnd'
  | 'output'
> & {
  scoring: ScoringState;
  creationRequest: string;
  scorebugStyle?: ScorebugStyle;
  output?: MatchOutput;
};
type InviteRow = {
  id: string;
  game_id: string;
  code_hash: string;
  created_at: number;
  expires_at: number;
  revoked_at: number | null;
};
export type MatchStoreOptions = {
  /** The worker's output for a match: the team's YouTube ingest once the match has a
   * broadcast. Null (or no option) means no output yet. */
  output?: (gameId: string) => WorkerOutputAssignment | null;
};
export class MatchStoreError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
const digest = (token: string) => createHash('sha256').update(token).digest('hex');
const matchesDigest = (stored: string, token: string) =>
  /^[a-f0-9]{64}$/.test(stored) &&
  timingSafeEqual(Buffer.from(stored, 'hex'), Buffer.from(digest(token), 'hex'));
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
    scorebugStyle: match.scorebugStyle ?? DEFAULT_SCOREBUG_STYLE,
    pendingSetEnd: pendingSetEnd(match.scoring, match.rules),
    output: match.output ?? NO_OUTPUT,
  };
}

/** Synchronous transactions serialize all commands, including competing processes. */
export class MatchStore {
  readonly media: MediaStore;
  /** Keys code hashes, so a copied database does not reveal short codes. */
  private readonly codeKey: Buffer;
  constructor(
    private readonly db: SqlDb,
    private readonly credentialKey: string,
    private readonly now: () => number = Date.now,
    options: MatchStoreOptions = {},
  ) {
    try {
      if (credentialKey.length < 16) throw new MatchStoreError('credential_key_too_short');
      // Durable Objects reject PRAGMA user_version, so the version lives in a table.
      db.exec('CREATE TABLE IF NOT EXISTS schema_meta(key TEXT PRIMARY KEY, value TEXT)');
      const version = db.get<{ value: string }>(
        "SELECT value FROM schema_meta WHERE key='version'",
      );
      if (Number(version?.value ?? 0) > SCHEMA_VERSION)
        throw new MatchStoreError('unsupported_database_version');
      this.transaction(() => {
        this.db.exec(`
          CREATE TABLE IF NOT EXISTS matches(id TEXT PRIMARY KEY, status TEXT NOT NULL, data TEXT NOT NULL);
          CREATE UNIQUE INDEX IF NOT EXISTS one_active_match ON matches(status) WHERE status='active';
          CREATE TABLE IF NOT EXISTS credentials(game_id TEXT NOT NULL REFERENCES matches(id), device_id TEXT NOT NULL,
            role TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, PRIMARY KEY(game_id, device_id, role));
          CREATE TABLE IF NOT EXISTS commands(game_id TEXT NOT NULL REFERENCES matches(id), device_id TEXT NOT NULL,
            command_id TEXT NOT NULL, request TEXT NOT NULL, outcome TEXT NOT NULL, PRIMARY KEY(game_id, device_id, command_id));
          -- Retired Watch pairing capabilities: the Watch now mirrors the iPhone.
          DROP TABLE IF EXISTS watch_pairings;
        `);
        MediaStore.migrate(this.db);
        this.db.exec(`
          CREATE TABLE IF NOT EXISTS server_keys(name TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS match_invites(id TEXT PRIMARY KEY, game_id TEXT NOT NULL REFERENCES matches(id),
            code_hash TEXT NOT NULL UNIQUE, created_by TEXT NOT NULL, created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL, revoked_at INTEGER);
          CREATE TABLE IF NOT EXISTS invite_redemptions(game_id TEXT NOT NULL REFERENCES matches(id), device_id TEXT NOT NULL,
            invite_id TEXT NOT NULL REFERENCES match_invites(id), redeemed_at INTEGER NOT NULL, PRIMARY KEY(game_id,device_id));
        `);
        this.db.run(
          "INSERT INTO schema_meta(key,value) VALUES('version',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          String(SCHEMA_VERSION),
        );
        this.db.run(
          "INSERT OR IGNORE INTO server_keys(name,value) VALUES('hmac',?)",
          randomBytes(32).toString('base64url'),
        );
      });
      const key = db.get<{ value: string }>("SELECT value FROM server_keys WHERE name='hmac'")!;
      this.codeKey = Buffer.from(key.value, 'base64url');
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
        output: (id) => options.output?.(id) ?? { destinationId: null, publishUrl: null },
        now: this.now,
      });
    } catch (error) {
      db.close();
      throw error;
    }
  }
  close(): void {
    this.db.close();
  }
  private transaction<T>(body: () => T): T {
    return this.db.transaction(body);
  }
  private codeHash(purpose: string, code: string): string {
    return createHmac('sha256', this.codeKey)
      .update(canonical([purpose, code]))
      .digest('hex');
  }
  private load(id: string): StoredMatch {
    const row = this.db.get('SELECT data FROM matches WHERE id=?', id) as
      | { data: string }
      | undefined;
    if (!row) throw new MatchStoreError('match_not_found');
    return JSON.parse(row.data) as StoredMatch;
  }
  private save(match: StoredMatch): void {
    this.db.run(
      'UPDATE matches SET status=?,data=? WHERE id=?',
      match.scoring.status,
      JSON.stringify(match),
      match.id,
    );
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
    const row = this.db.get("SELECT data FROM matches WHERE status='active'") as
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
      const output: MatchOutput = { destinationId: null, recordOnly: input.recordOnly === true };
      const match: StoredMatch = {
        id: input.id,
        createdAt: new Date(this.now()).toISOString(),
        teams: input.teams,
        rules: input.rules,
        revision: 0,
        scoring: initialScoringState(),
        scorer: { deviceId: input.deviceId, epoch: 1 },
        broadcast: { desired: 'stopped', generation: 0 },
        scorebugStyle: input.scorebugStyle ?? DEFAULT_SCOREBUG_STYLE,
        output,
        creationRequest: canonical(input),
      };
      this.db.run(
        'INSERT INTO matches(id,status,data) VALUES(?,?,?)',
        input.id,
        'active',
        JSON.stringify(match),
      );
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
      return this.issueCredentialWithinTransaction(gameId, deviceId, role);
    });
  }
  private credential(
    gameId: string,
    deviceId: string,
    role: MatchCredential['role'],
  ): MatchCredential {
    // Deterministic per match, device and role, so a retried create or join gets the same token.
    const token = createHmac('sha256', this.credentialKey)
      .update(canonical(['scorebug-scoped-credential-v1', gameId, deviceId, role]))
      .digest('base64url');
    return { gameId, deviceId, role, token };
  }
  private issueCredentialWithinTransaction(
    gameId: string,
    deviceId: string,
    role: MatchCredential['role'],
  ): MatchCredential {
    const credential = this.credential(gameId, deviceId, role);
    this.db.run(
      `INSERT INTO credentials(game_id,device_id,role,token_hash) VALUES(?,?,?,?)
        ON CONFLICT(game_id,device_id,role) DO UPDATE SET token_hash=excluded.token_hash`,
      gameId,
      deviceId,
      role,
      digest(credential.token),
    );
    return credential;
  }
  // ---------------------------------------------------------------- invites

  private inviteView(row: InviteRow): MatchInvite {
    const { count } = this.db.get(
      'SELECT COUNT(*) AS count FROM invite_redemptions WHERE invite_id=?',
      row.id,
    ) as { count: number };
    return {
      id: row.id,
      gameId: row.game_id,
      createdAt: new Date(row.created_at).toISOString(),
      expiresAt: new Date(row.expires_at).toISOString(),
      revokedAt: row.revoked_at === null ? null : new Date(row.revoked_at).toISOString(),
      redemptions: count,
    };
  }
  /** Multi-use until revoked, expired or the match ends. Returns the only copy of the code. */
  issueInvite(
    gameId: string,
    createdBy: string,
    ttlMs = INVITE_TTL_MS,
  ): { invite: MatchInvite; code: string } {
    if (!Number.isSafeInteger(ttlMs) || ttlMs < 60_000 || ttlMs > 24 * 60 * 60 * 1000)
      throw new MatchStoreError('invalid_ttl');
    return this.transaction(() => {
      if (this.load(gameId).scoring.status !== 'active') throw new MatchStoreError('match_ended');
      const now = this.now();
      const { count } = this.db.get(
        'SELECT COUNT(*) AS count FROM match_invites WHERE game_id=? AND revoked_at IS NULL AND expires_at>?',
        gameId,
        now,
      ) as { count: number };
      if (count >= 16) throw new MatchStoreError('invite_limit');
      for (let attempt = 0; attempt < 8; attempt++) {
        let code = '';
        for (let i = 0; i < INVITE_CODE_LENGTH; i++)
          code += INVITE_CODE_ALPHABET[randomInt(INVITE_CODE_ALPHABET.length)];
        const hash = this.codeHash('match-invite', code);
        if (this.db.get('SELECT 1 FROM match_invites WHERE code_hash=?', hash)) continue;
        const id = randomUUID();
        this.db.run(
          'INSERT INTO match_invites(id,game_id,code_hash,created_by,created_at,expires_at) VALUES(?,?,?,?,?,?)',
          id,
          gameId,
          hash,
          createdBy,
          now,
          now + ttlMs,
        );
        return { invite: this.inviteView(this.inviteRow(gameId, id)!), code };
      }
      throw new MatchStoreError('invite_code_exhausted');
    });
  }
  private inviteRow(gameId: string, inviteId: string): InviteRow | undefined {
    return this.db.get('SELECT * FROM match_invites WHERE game_id=? AND id=?', gameId, inviteId) as
      | InviteRow
      | undefined;
  }
  listInvites(gameId: string): MatchInvite[] {
    return this.transaction(() => {
      this.load(gameId);
      return (
        this.db.all(
          'SELECT * FROM match_invites WHERE game_id=? ORDER BY created_at, rowid',
          gameId,
        ) as InviteRow[]
      ).map((row) => this.inviteView(row));
    });
  }
  /** Also removes the scoring credentials handed out through this invite. */
  revokeInvite(gameId: string, inviteId: string): MatchInvite {
    return this.transaction(() => {
      const row = this.inviteRow(gameId, inviteId);
      if (!row) throw new MatchStoreError('invite_not_found');
      if (row.revoked_at === null) {
        this.db.run('UPDATE match_invites SET revoked_at=? WHERE id=?', this.now(), inviteId);
        this.db.run(
          `DELETE FROM credentials WHERE game_id=? AND role='score' AND device_id IN
            (SELECT device_id FROM invite_redemptions WHERE invite_id=?)`,
          gameId,
          inviteId,
        );
      }
      return this.inviteView(this.inviteRow(gameId, inviteId)!);
    });
  }
  /** Unauthenticated: the code is the capability. Returns a per-match `score` credential. */
  redeemInvite(input: InviteRedeemRequest): {
    credential: MatchCredential;
    snapshot: MatchSnapshot;
  } {
    return this.transaction(() => {
      const code = normalizeInviteCode(input.code);
      if (!code) throw new MatchStoreError('invite_invalid');
      const hash = this.codeHash('match-invite', code);
      const row = this.db.get('SELECT * FROM match_invites WHERE code_hash=?', hash) as
        | InviteRow
        | undefined;
      if (!row || !timingSafeEqual(Buffer.from(row.code_hash), Buffer.from(hash)))
        throw new MatchStoreError('invite_invalid');
      if (row.revoked_at !== null) throw new MatchStoreError('invite_revoked');
      if (this.now() >= row.expires_at) throw new MatchStoreError('invite_expired');
      if (this.load(row.game_id).scoring.status !== 'active')
        throw new MatchStoreError('match_ended');
      const redeemed = this.db.get(
        'SELECT 1 FROM invite_redemptions WHERE game_id=? AND device_id=?',
        row.game_id,
        input.deviceId,
      );
      // Invite device IDs must not alias the owner's or another device's existing credentials.
      if (
        !redeemed &&
        this.db.get(
          'SELECT 1 FROM credentials WHERE game_id=? AND device_id=?',
          row.game_id,
          input.deviceId,
        )
      )
        throw new MatchStoreError('device_id_taken');
      const credential = this.issueCredentialWithinTransaction(
        row.game_id,
        input.deviceId,
        'score',
      );
      this.db.run(
        `INSERT INTO invite_redemptions(game_id,device_id,invite_id,redeemed_at) VALUES(?,?,?,?)
          ON CONFLICT(game_id,device_id) DO UPDATE SET invite_id=excluded.invite_id`,
        row.game_id,
        input.deviceId,
        row.id,
        this.now(),
      );
      return { credential, snapshot: snapshot(this.load(row.game_id)) };
    });
  }
  authenticate(gameId: string, token: string): Omit<MatchCredential, 'token'> | undefined {
    const row = this.db.get(
      'SELECT device_id,role FROM credentials WHERE game_id=? AND token_hash=?',
      gameId,
      digest(token),
    ) as { device_id: string; role: MatchCredential['role'] } | undefined;
    return row ? { gameId, deviceId: row.device_id, role: row.role } : undefined;
  }
  receipt(gameId: string, deviceId: string, commandId: string): CommandOutcome | undefined {
    const row = this.db.get(
      'SELECT outcome FROM commands WHERE game_id=? AND device_id=? AND command_id=?',
      gameId,
      deviceId,
      commandId,
    ) as { outcome: string } | undefined;
    return row ? (JSON.parse(row.outcome) as CommandOutcome) : undefined;
  }
  execute(command: MatchCommand): CommandOutcome {
    return this.transaction(() => {
      const match = this.load(command.gameId);
      const request = canonical(command);
      const existing = this.db.get(
        'SELECT request,outcome FROM commands WHERE game_id=? AND device_id=? AND command_id=?',
        command.gameId,
        command.deviceId,
        command.commandId,
      ) as { request: string; outcome: string } | undefined;
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
      const canScore = this.db.get(
        "SELECT 1 FROM credentials WHERE game_id=? AND device_id=? AND role='score'",
        command.gameId,
        command.deviceId,
      );
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
          else if (command.operation.type === 'set_scorebug_style')
            // Presentation only: outside scoring history, so undo never reverts it.
            match.scorebugStyle = command.operation.style;
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
      this.db.run(
        'INSERT INTO commands(game_id,device_id,command_id,request,outcome) VALUES(?,?,?,?,?)',
        command.gameId,
        command.deviceId,
        command.commandId,
        request,
        JSON.stringify(outcome),
      );
      return outcome;
    });
  }
}
