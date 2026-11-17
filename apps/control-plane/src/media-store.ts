import type {
  BroadcastCommand,
  BroadcastOutcome,
  BroadcastSelection,
  MatchSnapshot,
  MediaBroadcast,
  MediaSnapshot,
  RecordingAssociation,
  RecordingReport,
  WorkerOutputAssignment,
} from '@scorebug/protocol';
import { canonical } from './canonical-json.js';
import type { SqlDb } from './sql.js';
import { applyBroadcastOperation, applyRecordingReport, MediaStateError } from './media-state.js';

export class MediaStoreError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
/** The worker and output a start command goes to. */
export type BroadcastWorker = Pick<BroadcastSelection, 'workerId' | 'outputId'>;

type Dependencies = {
  transaction: <T>(body: () => T) => T;
  match: (id: string) => MatchSnapshot | undefined;
  active: () => MatchSnapshot | undefined;
  updateBroadcast: (id: string, broadcast: MediaBroadcast) => void;
  output: (id: string) => WorkerOutputAssignment | null;
  now: () => number;
};

/** Shares the match database transaction, so match end and broadcast stop commit together. */
export class MediaStore {
  constructor(
    private readonly db: SqlDb,
    private readonly deps: Dependencies,
  ) {}

  static migrate(db: SqlDb): void {
    db.exec(`
      CREATE TABLE IF NOT EXISTS recordings(game_id TEXT NOT NULL REFERENCES matches(id), recording_id TEXT NOT NULL,
        device_id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(game_id, recording_id));
      CREATE TABLE IF NOT EXISTS media_broadcasts(game_id TEXT PRIMARY KEY REFERENCES matches(id), data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS media_commands(game_id TEXT NOT NULL REFERENCES matches(id), command_id TEXT NOT NULL,
        request TEXT NOT NULL, outcome TEXT NOT NULL, PRIMARY KEY(game_id, command_id));
    `);
  }
  private match(id: string): MatchSnapshot {
    const match = this.deps.match(id);
    if (!match) throw new MediaStoreError('match_not_found');
    return match;
  }
  private read(gameId: string): MediaSnapshot {
    const match = this.match(gameId);
    const row = this.db.get('SELECT data FROM media_broadcasts WHERE game_id=?', gameId) as
      | { data: string }
      | undefined;
    const recordings = this.db.all(
      'SELECT data FROM recordings WHERE game_id=? ORDER BY recording_id',
      gameId,
    ) as { data: string }[];
    return {
      gameId,
      recordings: recordings.map((row) => JSON.parse(row.data) as RecordingAssociation),
      broadcast: row
        ? (JSON.parse(row.data) as MediaBroadcast)
        : { ...match.broadcast, selection: null },
    };
  }
  get(gameId: string): MediaSnapshot {
    return this.deps.transaction(() => this.read(gameId));
  }
  /** `output` carries the stream key and is only for the authenticated worker. */
  workerAssignment(
    workerId: string,
  ): { match: MatchSnapshot; media: MediaSnapshot; output: WorkerOutputAssignment } | null {
    return this.deps.transaction(() => {
      const match = this.deps.active();
      if (!match) return null;
      const media = this.read(match.id);
      if (media.broadcast.desired !== 'running' || media.broadcast.selection?.workerId !== workerId)
        return null;
      const output = this.deps.output(match.id);
      return output ? { match, media, output } : null;
    });
  }
  reportRecording(gameId: string, deviceId: string, report: RecordingReport): RecordingAssociation {
    return this.deps.transaction(() => {
      this.match(gameId);
      const capture = this.db.get(
        "SELECT 1 FROM credentials WHERE game_id=? AND device_id=? AND role='capture'",
        gameId,
        deviceId,
      );
      if (!capture) throw new MediaStoreError('capture_access_required');
      const row = this.db.get(
        'SELECT data FROM recordings WHERE game_id=? AND recording_id=?',
        gameId,
        report.recordingId,
      ) as { data: string } | undefined;
      const next = applyRecordingReport(
        row ? (JSON.parse(row.data) as RecordingAssociation) : undefined,
        gameId,
        deviceId,
        report,
        new Date(this.deps.now()).toISOString(),
      );
      this.db.run(
        `INSERT INTO recordings(game_id,recording_id,device_id,data) VALUES(?,?,?,?)
        ON CONFLICT(game_id,recording_id) DO UPDATE SET data=excluded.data`,
        gameId,
        next.recordingId,
        deviceId,
        JSON.stringify(next),
      );
      return next;
    });
  }
  private saveBroadcast(gameId: string, broadcast: MediaBroadcast): void {
    this.db.run(
      `INSERT INTO media_broadcasts(game_id,data) VALUES(?,?)
      ON CONFLICT(game_id) DO UPDATE SET data=excluded.data`,
      gameId,
      JSON.stringify(broadcast),
    );
  }
  /** Internal: caller must already hold the transaction used to end this match. */
  stopForMatchEndWithinTransaction(gameId: string, generation: number): void {
    this.saveBroadcast(gameId, { desired: 'stopped', generation, selection: null });
  }
  receipt(gameId: string, commandId: string): BroadcastOutcome | undefined {
    const row = this.db.get(
      'SELECT outcome FROM media_commands WHERE game_id=? AND command_id=?',
      gameId,
      commandId,
    ) as { outcome: string } | undefined;
    return row ? (JSON.parse(row.outcome) as BroadcastOutcome) : undefined;
  }
  /** A start goes to `worker`. A retry of the same command replays its first outcome. */
  execute(command: BroadcastCommand, worker: BroadcastWorker): BroadcastOutcome {
    return this.deps.transaction(() => {
      if (
        !/^[A-Za-z0-9_-]{1,128}$/.test(command.commandId) ||
        !/^[A-Za-z0-9_-]{1,128}$/.test(command.gameId)
      )
        throw new MediaStoreError('invalid_id');
      const snapshot = this.read(command.gameId);
      const request = canonical(command);
      const previous = this.db.get(
        'SELECT request,outcome FROM media_commands WHERE game_id=? AND command_id=?',
        command.gameId,
        command.commandId,
      ) as { request: string; outcome: string } | undefined;
      if (previous)
        return previous.request === request
          ? (JSON.parse(previous.outcome) as BroadcastOutcome)
          : { commandId: command.commandId, accepted: false, error: 'command_id_reused', snapshot };
      const age = this.deps.now() - Date.parse(command.issuedAt);
      let error: string | null = null;
      if (!Number.isFinite(age) || age < -5000) error = 'clock_skew';
      else if (age > 10_000) error = 'command_expired';
      else if (
        !Number.isSafeInteger(command.expectedGeneration) ||
        command.expectedGeneration !== snapshot.broadcast.generation
      )
        error = 'generation_conflict';
      else if (command.operation.type === 'start' && this.match(command.gameId).output.recordOnly)
        error = 'record_only_match';
      else {
        try {
          const broadcast = applyBroadcastOperation(
            snapshot.broadcast,
            command.operation,
            worker,
            snapshot.recordings,
            this.match(command.gameId).status,
          );
          this.saveBroadcast(command.gameId, broadcast);
          this.deps.updateBroadcast(command.gameId, broadcast);
        } catch (cause) {
          if (cause instanceof MediaStateError) error = cause.code;
          else throw cause;
        }
      }
      const outcome: BroadcastOutcome = {
        commandId: command.commandId,
        accepted: error === null,
        error,
        snapshot: this.read(command.gameId),
      };
      this.db.run(
        'INSERT INTO media_commands(game_id,command_id,request,outcome) VALUES(?,?,?,?)',
        command.gameId,
        command.commandId,
        request,
        JSON.stringify(outcome),
      );
      return outcome;
    });
  }
}
