import { createHash, createHmac, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
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
  WatchPairingIssueRequest,
  WatchPairingRedeemRequest,
  WatchPairingIssued,
  WatchPairingRedeemed,
} from '@scorebug/protocol';
import {
  DEFAULT_SCOREBUG_STYLE,
  INVITE_CODE_ALPHABET,
  INVITE_CODE_LENGTH,
  normalizeInviteCode,
} from '@scorebug/protocol';
import { AccountStore } from './account-store.js';
import { canonical } from './canonical-json.js';
import { MediaStore } from './media-store.js';
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
  destinationId?: string | undefined;
  recordOnly?: boolean | undefined;
};
export const INVITE_TTL_MS = 6 * 60 * 60 * 1000;
const NO_OUTPUT: MatchOutput = { destinationId: null, recordOnly: false };
// Match rows are JSON documents: rows written before scorebugStyle existed lack
// the field and read back as the default style, so no SQL migration is needed.
// Rows from before destinations lack `output` and use the worker's OUTPUT_URL.
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
export class MatchStoreError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
const digest = (token: string) => createHash('sha256').update(token).digest('hex');
const matchesDigest = (stored: string, token: string) =>
  /^[a-f0-9]{64}$/.test(stored) &&
  timingSafeEqual(Buffer.from(stored, 'hex'), Buffer.from(digest(token), 'hex'));
type PairingRow = {
  game_id: string;
  pairing_id: string;
  watch_device_id: string;
  request: string;
  token_hash: string;
  expires_at: number;
  expired: number;
  redemption_request: string | null;
  recovery_hash: string | null;
  credential_hash: string | null;
};
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
  private readonly db: DatabaseSync;
  readonly media: MediaStore;
  readonly account: AccountStore;
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
      if (version.user_version > 5) throw new MatchStoreError('unsupported_database_version');
      this.transaction(() => {
        this.db.exec(`
          CREATE TABLE IF NOT EXISTS matches(id TEXT PRIMARY KEY, status TEXT NOT NULL, data TEXT NOT NULL);
          CREATE UNIQUE INDEX IF NOT EXISTS one_active_match ON matches(status) WHERE status='active';
          CREATE TABLE IF NOT EXISTS credentials(game_id TEXT NOT NULL REFERENCES matches(id), device_id TEXT NOT NULL,
            role TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, PRIMARY KEY(game_id, device_id, role));
          CREATE TABLE IF NOT EXISTS commands(game_id TEXT NOT NULL REFERENCES matches(id), device_id TEXT NOT NULL,
            command_id TEXT NOT NULL, request TEXT NOT NULL, outcome TEXT NOT NULL, PRIMARY KEY(game_id, device_id, command_id));
          CREATE TABLE IF NOT EXISTS watch_pairings(game_id TEXT NOT NULL REFERENCES matches(id), pairing_id TEXT NOT NULL,
            watch_device_id TEXT NOT NULL, request TEXT NOT NULL, token_hash TEXT NOT NULL, expires_at INTEGER NOT NULL,
            redemption_request TEXT, recovery_hash TEXT, credential_hash TEXT,
            expired INTEGER NOT NULL DEFAULT 0 CHECK(expired IN (0,1)), PRIMARY KEY(game_id,pairing_id));

        `);
        MediaStore.migrate(this.db);
        AccountStore.migrate(this.db);
        this.db.exec(`
          CREATE TABLE IF NOT EXISTS match_invites(id TEXT PRIMARY KEY, game_id TEXT NOT NULL REFERENCES matches(id),
            code_hash TEXT NOT NULL UNIQUE, created_by TEXT NOT NULL, created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL, revoked_at INTEGER);
          CREATE TABLE IF NOT EXISTS invite_redemptions(game_id TEXT NOT NULL REFERENCES matches(id), device_id TEXT NOT NULL,
            invite_id TEXT NOT NULL REFERENCES match_invites(id), redeemed_at INTEGER NOT NULL, PRIMARY KEY(game_id,device_id));
        `);
        // Development v3 databases already contain pairing receipts. Add the terminal
        // expiry flag in place, without replacing rows or losing uncertain redemptions.
        const pairingColumns = this.db.prepare('PRAGMA table_info(watch_pairings)').all();
        if (!pairingColumns.some((column) => column.name === 'expired'))
          this.db.exec(
            'ALTER TABLE watch_pairings ADD COLUMN expired INTEGER NOT NULL DEFAULT 0 CHECK(expired IN (0,1))',
          );
        this.db.exec('PRAGMA user_version=5;');
      });
      this.account = new AccountStore(this.db, {
        transaction: (body) => this.transaction(body),
        now: this.now,
        destinationInUse: (id) => this.active()?.output.destinationId === id,
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
        output: (id) => {
          const output = this.get(id)?.output ?? NO_OUTPUT;
          return {
            destinationId: output.destinationId,
            publishUrl: output.destinationId ? this.account.publishUrl(output.destinationId) : null,
          };
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
      if (input.recordOnly && input.destinationId !== undefined)
        throw new MatchStoreError('invalid_output');
      if (input.destinationId !== undefined && !this.account.getDestination(input.destinationId))
        throw new MatchStoreError('destination_not_found');
      const output: MatchOutput = input.recordOnly
        ? { destinationId: null, recordOnly: true }
        : {
            destinationId: input.destinationId ?? this.account.defaultDestinationId(),
            recordOnly: false,
          };
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
      return this.issueCredentialWithinTransaction(gameId, deviceId, role);
    });
  }
  private credential(
    gameId: string,
    deviceId: string,
    role: MatchCredential['role'],
  ): MatchCredential {
    // Existing installation-authorized joins retain their stable token domain.
    const token = createHmac('sha256', this.credentialKey)
      .update(canonical(['scorebug-scoped-credential-v1', gameId, deviceId, role]))
      .digest('base64url');
    return { gameId, deviceId, role, token };
  }
  private issueCredentialWithinTransaction(
    gameId: string,
    deviceId: string,
    role: MatchCredential['role'],
    preserveExisting = false,
  ): MatchCredential {
    const credential = this.credential(gameId, deviceId, role);
    if (preserveExisting) {
      const existing = this.db
        .prepare('SELECT token_hash FROM credentials WHERE game_id=? AND device_id=? AND role=?')
        .get(gameId, deviceId, role) as { token_hash: string } | undefined;
      if (existing && !matchesDigest(existing.token_hash, credential.token))
        throw new MatchStoreError('pairing_credential_changed');
    }
    this.db
      .prepare(
        `INSERT INTO credentials(game_id,device_id,role,token_hash) VALUES(?,?,?,?)
        ON CONFLICT(game_id,device_id,role) DO UPDATE SET token_hash=excluded.token_hash`,
      )
      .run(gameId, deviceId, role, digest(credential.token));
    return credential;
  }
  private pairing(gameId: string, pairingId: string): PairingRow | undefined {
    return this.db
      .prepare('SELECT * FROM watch_pairings WHERE game_id=? AND pairing_id=?')
      .get(gameId, pairingId) as PairingRow | undefined;
  }
  private pairingToken(
    gameId: string,
    pairingId: string,
    watchDeviceId: string,
    expiresAt: number,
  ): string {
    return createHmac('sha256', this.credentialKey)
      .update(canonical(['scorebug-watch-pairing-v1', gameId, pairingId, watchDeviceId, expiresAt]))
      .digest('base64url');
  }
  authenticateWatchPairing(gameId: string, pairingId: string, token: string): boolean {
    const row = this.pairing(gameId, pairingId);
    return !!row && matchesDigest(row.token_hash, token);
  }
  issueWatchPairing(gameId: string, input: WatchPairingIssueRequest): WatchPairingIssued {
    return this.transaction(() => {
      const request = canonical(input);
      const existing = this.pairing(gameId, input.pairingId);
      let expiresAt: number;
      if (existing) {
        if (existing.request !== request) throw new MatchStoreError('pairing_id_reused');
        expiresAt = existing.expires_at;
      } else {
        if (this.load(gameId).scoring.status !== 'active') throw new MatchStoreError('match_ended');
        const { count } = this.db
          .prepare('SELECT COUNT(*) AS count FROM watch_pairings WHERE game_id=?')
          .get(gameId) as { count: number };
        if (count >= 64) throw new MatchStoreError('pairing_limit');
        expiresAt = this.now() + 300000;
      }
      const pairingToken = this.pairingToken(
        gameId,
        input.pairingId,
        input.watchDeviceId,
        expiresAt,
      );
      if (existing && !matchesDigest(existing.token_hash, pairingToken))
        throw new MatchStoreError('pairing_key_changed');
      if (!existing)
        this.db
          .prepare(
            'INSERT INTO watch_pairings(game_id,pairing_id,watch_device_id,request,token_hash,expires_at) VALUES(?,?,?,?,?,?)',
          )
          .run(
            gameId,
            input.pairingId,
            input.watchDeviceId,
            request,
            digest(pairingToken),
            expiresAt,
          );
      return {
        ...input,
        gameId,
        role: 'score',
        pairingToken,
        expiresAt: new Date(expiresAt).toISOString(),
        serverTime: new Date(this.now()).toISOString(),
      };
    });
  }
  redeemWatchPairing(
    gameId: string,
    pairingId: string,
    token: string,
    recoveryKey: string,
    input: WatchPairingRedeemRequest,
  ): WatchPairingRedeemed {
    const outcome = this.transaction<WatchPairingRedeemed | null>(() => {
      const row = this.pairing(gameId, pairingId);
      if (!row || !matchesDigest(row.token_hash, token)) throw new MatchStoreError('unauthorized');
      const request = canonical(input);
      let credential: MatchCredential;
      if (row.redemption_request !== null) {
        // Receipt first: expiry/match end cannot erase an uncertain committed redemption.
        if (
          row.redemption_request !== request ||
          !row.recovery_hash ||
          !matchesDigest(row.recovery_hash, recoveryKey)
        )
          throw new MatchStoreError('pairing_redemption_conflict');
        credential = this.credential(gameId, row.watch_device_id, 'score');
        if (
          !row.credential_hash ||
          !matchesDigest(row.credential_hash, credential.token) ||
          !this.authenticate(gameId, credential.token)
        )
          throw new MatchStoreError('pairing_credential_changed');
      } else {
        if (row.expired || this.now() >= row.expires_at) {
          if (!row.expired)
            this.db
              .prepare('UPDATE watch_pairings SET expired=1 WHERE game_id=? AND pairing_id=?')
              .run(gameId, pairingId);
          // Return through COMMIT: throwing here would roll back definitive expiry.
          return null;
        }
        if (
          !matchesDigest(
            row.token_hash,
            this.pairingToken(gameId, pairingId, row.watch_device_id, row.expires_at),
          )
        )
          throw new MatchStoreError('pairing_key_changed');
        if (this.load(gameId).scoring.status !== 'active') throw new MatchStoreError('match_ended');
        if (input.deviceId !== row.watch_device_id)
          throw new MatchStoreError('pairing_device_mismatch');
        credential = this.issueCredentialWithinTransaction(gameId, input.deviceId, 'score', true);
        this.db
          .prepare(
            'UPDATE watch_pairings SET redemption_request=?,recovery_hash=?,credential_hash=? WHERE game_id=? AND pairing_id=?',
          )
          .run(request, digest(recoveryKey), digest(credential.token), gameId, pairingId);
      }
      return {
        pairingId,
        redemptionId: input.redemptionId,
        credential,
        snapshot: snapshot(this.load(gameId)),
        serverTime: new Date(this.now()).toISOString(),
      };
    });
    // Only a durable terminal expiry permits a client to discard uncertain intent.
    if (outcome === null) throw new MatchStoreError('pairing_expired');
    return outcome;
  }
  // ---------------------------------------------------------------- invites

  private inviteView(row: InviteRow): MatchInvite {
    const { count } = this.db
      .prepare('SELECT COUNT(*) AS count FROM invite_redemptions WHERE invite_id=?')
      .get(row.id) as { count: number };
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
      const { count } = this.db
        .prepare(
          'SELECT COUNT(*) AS count FROM match_invites WHERE game_id=? AND revoked_at IS NULL AND expires_at>?',
        )
        .get(gameId, now) as { count: number };
      if (count >= 16) throw new MatchStoreError('invite_limit');
      for (let attempt = 0; attempt < 8; attempt++) {
        let code = '';
        for (let i = 0; i < INVITE_CODE_LENGTH; i++)
          code += INVITE_CODE_ALPHABET[randomInt(INVITE_CODE_ALPHABET.length)];
        const hash = this.account.codeHash('match-invite', code);
        if (this.db.prepare('SELECT 1 FROM match_invites WHERE code_hash=?').get(hash)) continue;
        const id = randomUUID();
        this.db
          .prepare(
            'INSERT INTO match_invites(id,game_id,code_hash,created_by,created_at,expires_at) VALUES(?,?,?,?,?,?)',
          )
          .run(id, gameId, hash, createdBy, now, now + ttlMs);
        return { invite: this.inviteView(this.inviteRow(gameId, id)!), code };
      }
      throw new MatchStoreError('invite_code_exhausted');
    });
  }
  private inviteRow(gameId: string, inviteId: string): InviteRow | undefined {
    return this.db
      .prepare('SELECT * FROM match_invites WHERE game_id=? AND id=?')
      .get(gameId, inviteId) as InviteRow | undefined;
  }
  listInvites(gameId: string): MatchInvite[] {
    return this.transaction(() => {
      this.load(gameId);
      return (
        this.db
          .prepare('SELECT * FROM match_invites WHERE game_id=? ORDER BY created_at, rowid')
          .all(gameId) as InviteRow[]
      ).map((row) => this.inviteView(row));
    });
  }
  /** Also removes the scoring credentials handed out through this invite. */
  revokeInvite(gameId: string, inviteId: string): MatchInvite {
    return this.transaction(() => {
      const row = this.inviteRow(gameId, inviteId);
      if (!row) throw new MatchStoreError('invite_not_found');
      if (row.revoked_at === null) {
        this.db
          .prepare('UPDATE match_invites SET revoked_at=? WHERE id=?')
          .run(this.now(), inviteId);
        this.db
          .prepare(
            `DELETE FROM credentials WHERE game_id=? AND role='score' AND device_id IN
            (SELECT device_id FROM invite_redemptions WHERE invite_id=?)`,
          )
          .run(gameId, inviteId);
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
      const hash = this.account.codeHash('match-invite', code);
      const row = this.db.prepare('SELECT * FROM match_invites WHERE code_hash=?').get(hash) as
        | InviteRow
        | undefined;
      if (!row || !timingSafeEqual(Buffer.from(row.code_hash), Buffer.from(hash)))
        throw new MatchStoreError('invite_invalid');
      if (row.revoked_at !== null) throw new MatchStoreError('invite_revoked');
      if (this.now() >= row.expires_at) throw new MatchStoreError('invite_expired');
      if (this.load(row.game_id).scoring.status !== 'active')
        throw new MatchStoreError('match_ended');
      const redeemed = this.db
        .prepare('SELECT 1 FROM invite_redemptions WHERE game_id=? AND device_id=?')
        .get(row.game_id, input.deviceId);
      // Invite device IDs must not alias the owner's or another device's existing credentials.
      if (
        !redeemed &&
        this.db
          .prepare('SELECT 1 FROM credentials WHERE game_id=? AND device_id=?')
          .get(row.game_id, input.deviceId)
      )
        throw new MatchStoreError('device_id_taken');
      const credential = this.issueCredentialWithinTransaction(
        row.game_id,
        input.deviceId,
        'score',
      );
      this.db
        .prepare(
          `INSERT INTO invite_redemptions(game_id,device_id,invite_id,redeemed_at) VALUES(?,?,?,?)
          ON CONFLICT(game_id,device_id) DO UPDATE SET invite_id=excluded.invite_id`,
        )
        .run(row.game_id, input.deviceId, row.id, this.now());
      return { credential, snapshot: snapshot(this.load(row.game_id)) };
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
      this.db
        .prepare(
          'INSERT INTO commands(game_id,device_id,command_id,request,outcome) VALUES(?,?,?,?,?)',
        )
        .run(command.gameId, command.deviceId, command.commandId, request, JSON.stringify(outcome));
      return outcome;
    });
  }
}
