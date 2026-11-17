import type { MatchSnapshot, WorkerOutputAssignment } from '@scorebug/protocol';
import type { MatchStore } from '../matches-store.js';
import {
  MediaLifecycleError,
  type MediaLifecycle,
  type PublishAssignment,
  type PublishRequest,
  type WorkerConnection,
} from '../media-lifecycle.js';
import type { SqlDb } from '../sql.js';
import { Channels } from './channels.js';
import type { Env } from './env.js';
import type { MatchContainer, MediaAdapters } from './media-adapters.js';
import { inputName, StreamError, type LiveInput } from './stream.js';
import { YouTubeError } from './youtube.js';

/** The one worker and output a hosted match container registers. */
export const WORKER_ID = 'match';
export const OUTPUT_ID = 'youtube';
/**
 * Not a secret. The container reaches the team object only at http://api.internal/, through
 * an outbound intercept registered for this team's container, so it holds no credential. The
 * worker's config still requires a bearer value.
 */
export const WORKER_TOKEN = 'outbound-intercept-only-not-a-secret';

/** Teardown guards. */
export const MAX_LIVE_MS = 4 * 60 * 60 * 1000;
export const IDLE_MS = 10 * 60 * 1000;
export const ALARM_MS = 30 * 1000;
/** The platform stops a container the team object stops renewing (every alarm) after this. */
export const CONTAINER_TIMEOUT_MS = 5 * 60 * 1000;
const OUTPUT_SAVE_MS = 15 * 1000;

export type GoLiveRefusal =
  | 'youtube_not_set'
  | 'youtube_needs_reconnect'
  | 'youtube_live_disabled'
  | 'youtube_unavailable'
  | 'stream_unavailable'
  | 'container_unavailable'
  | 'busy'
  | 'time_limit';

/** The match's YouTube broadcast as the API shows it. One per match; the link never changes. */
export type MatchYouTube = {
  broadcastId: string;
  watchUrl: string;
  channelTitle: string;
  channelThumbnail: string | null;
  privacy: 'unlisted';
} | null;

type HostedRow = {
  gameId: string;
  /** Per-match Stream live input; null once deleted at the end of the match. */
  input: LiveInput | null;
  broadcast: {
    id: string;
    watchUrl: string;
    connectionId: string;
    channelTitle: string;
    channelThumbnail: string | null;
    streamId: string;
    /** RTMPS with the stream key: only for the match container. */
    ingestUrl: string;
  } | null;
  /** running: wanted and started. idle: parked by the idle guard until video returns. */
  container: 'stopped' | 'running' | 'idle';
  firstLiveAt: number | null;
  containerStartedAt: number | null;
  lastOutputAt: number | null;
  ended: boolean;
  endReason: 'match_ended' | 'time_limit' | null;
};

export type HostedMediaDeps = {
  sql: SqlDb;
  store: MatchStore;
  env: Env;
  adapters: MediaAdapters;
  container: MatchContainer | null;
  team: () => string | null;
  setAlarm: (at: number) => void;
  waitUntil: (promise: Promise<unknown>) => void;
  now?: () => number;
};

export function broadcastTitle(match: MatchSnapshot, timeZone: string | null, at: number): string {
  let day: string;
  try {
    day = new Intl.DateTimeFormat('en-US', {
      month: 'short',
      day: 'numeric',
      timeZone: timeZone ?? 'UTC',
    }).format(at);
  } catch {
    day = new Intl.DateTimeFormat('en-US', {
      month: 'short',
      day: 'numeric',
      timeZone: 'UTC',
    }).format(at);
  }
  return `${match.teams.home.name} vs ${match.teams.away.name} · ${day}`;
}

/**
 * A team's hosted media: per-match Stream input, YouTube broadcast and match container,
 * plus the guards that keep nothing billing after a match. Lives in the TeamObject; its rows
 * share the object's SQLite with the match store.
 */
export class HostedMedia implements MediaLifecycle {
  private readonly now: () => number;
  private readonly locks = new Map<string, Promise<unknown>>();

  constructor(private readonly deps: HostedMediaDeps) {
    this.now = deps.now ?? Date.now;
    deps.sql.exec(
      'CREATE TABLE IF NOT EXISTS hosted_media(game_id TEXT PRIMARY KEY, data TEXT NOT NULL)',
    );
  }

  // -------------------------------------------------------------------- rows

  private row(gameId: string): HostedRow | undefined {
    const row = this.deps.sql.get<{ data: string }>(
      'SELECT data FROM hosted_media WHERE game_id=?',
      gameId,
    );
    return row ? (JSON.parse(row.data) as HostedRow) : undefined;
  }
  private fresh(gameId: string): HostedRow {
    return (
      this.row(gameId) ?? {
        gameId,
        input: null,
        broadcast: null,
        container: 'stopped',
        firstLiveAt: null,
        containerStartedAt: null,
        lastOutputAt: null,
        ended: false,
        endReason: null,
      }
    );
  }
  private save(row: HostedRow): void {
    this.deps.sql.run(
      `INSERT INTO hosted_media(game_id,data) VALUES(?,?)
      ON CONFLICT(game_id) DO UPDATE SET data=excluded.data`,
      row.gameId,
      JSON.stringify(row),
    );
  }
  private update(gameId: string, change: (row: HostedRow) => void): HostedRow {
    const row = this.fresh(gameId);
    change(row);
    this.save(row);
    return row;
  }
  private openRows(): HostedRow[] {
    return this.deps.sql
      .all<{ data: string }>('SELECT data FROM hosted_media')
      .map((row) => JSON.parse(row.data) as HostedRow)
      .filter((row) => !row.ended);
  }

  /** Serializes the slow steps for one match: concurrent Go Live retries make one input
   * and one broadcast. */
  private locked<T>(gameId: string, body: () => Promise<T>): Promise<T> {
    const previous = this.locks.get(gameId) ?? Promise.resolve();
    const result = previous.then(body, body);
    const tail = result.catch(() => undefined);
    this.locks.set(gameId, tail);
    void tail.then(() => {
      if (this.locks.get(gameId) === tail) this.locks.delete(gameId);
    });
    return result;
  }

  private get channels(): Channels {
    return new Channels(this.deps.env.DB, this.deps.env.SERVER_SECRET, this.now);
  }
  private get team(): string {
    const team = this.deps.team();
    if (!team) throw new Error('team_unknown');
    return team;
  }
  private get cap(): number {
    const cap = Number.parseInt(this.deps.env.LIVE_MATCH_CAP ?? '5', 10);
    return Number.isSafeInteger(cap) && cap >= 0 ? cap : 5;
  }

  // ------------------------------------------------------------------- views

  youtube(gameId: string): MatchYouTube {
    const broadcast = this.row(gameId)?.broadcast;
    return broadcast
      ? {
          broadcastId: broadcast.id,
          watchUrl: broadcast.watchUrl,
          channelTitle: broadcast.channelTitle,
          channelThumbnail: broadcast.channelThumbnail,
          privacy: 'unlisted',
        }
      : null;
  }

  /** The match store's worker output: the broadcast's ingest. Synchronous (in a transaction). */
  output(gameId: string): WorkerOutputAssignment | null {
    const broadcast = this.row(gameId)?.broadcast;
    return broadcast ? { publishUrl: broadcast.ingestUrl } : null;
  }

  /** Inputs that still belong to a live match: the daily sweep keeps these. */
  referencedInputs(): string[] {
    return this.openRows().flatMap((row) => (row.input ? [row.input.uid] : []));
  }

  // ------------------------------------------------------------ Stream input

  private ensureInput(gameId: string): Promise<LiveInput> {
    return this.locked(`input:${gameId}`, async () => {
      const existing = this.row(gameId);
      if (existing?.ended) throw new MediaLifecycleError('broadcast_changed');
      if (existing?.input) return existing.input;
      const input = await this.deps.adapters.stream.createInput(inputName(this.team, gameId));
      return this.update(gameId, (row) => {
        row.input = input;
      }).input!;
    });
  }

  /** The film screen opened (a capture join): create the input before Go Live. */
  prewarm(gameId: string): void {
    const match = this.deps.store.get(gameId);
    if (!match || match.status !== 'active' || match.output.recordOnly) return;
    this.deps.waitUntil(
      this.ensureInput(gameId).catch((error: unknown) =>
        console.warn('stream_prewarm_failed', String(error)),
      ),
    );
  }

  // ----------------------------------------------------------------- Go Live

  /**
   * Everything a start command needs before the store accepts it: the team channel, the
   * Stream input, the match's one YouTube broadcast and a beta live slot. Null when ready.
   * Record-only and ended matches are left for the store to reject.
   */
  async prepareGoLive(gameId: string, timeZone: string | null): Promise<GoLiveRefusal | null> {
    const match = this.deps.store.get(gameId);
    if (!match || match.status !== 'active' || match.output.recordOnly) return null;
    if (this.row(gameId)?.endReason === 'time_limit') return 'time_limit';
    if (!this.deps.container) return 'container_unavailable';
    const refusal = await this.locked(`broadcast:${gameId}`, () =>
      this.ensureBroadcast(match, timeZone),
    );
    if (refusal) return refusal;
    try {
      await this.ensureInput(gameId);
    } catch (error) {
      if (error instanceof StreamError) return 'stream_unavailable';
      throw error;
    }
    return (await this.channels.claimSlot(gameId, this.team, this.cap)) ? null : 'busy';
  }

  private async ensureBroadcast(
    match: MatchSnapshot,
    timeZone: string | null,
  ): Promise<GoLiveRefusal | null> {
    if (this.row(match.id)?.broadcast) return null;
    const channels = this.channels;
    const team = await channels.teamChannel(this.team);
    if (!team) return 'youtube_not_set';
    const { connection } = team;
    if (connection.status === 'needs_reconnect') return 'youtube_needs_reconnect';
    if (!team.refreshToken) {
      await channels.setStatus(connection.id, 'needs_reconnect');
      return 'youtube_needs_reconnect';
    }
    const youtube = this.deps.adapters.youtube;
    try {
      const token = await youtube.accessToken(team.refreshToken);
      let stream =
        connection.stream_id && team.ingestUrl
          ? await youtube.stream(token, connection.stream_id)
          : null;
      if (!stream) {
        // Deleted in YouTube Studio, or connected before live streaming was enabled.
        if (!(await youtube.liveEnabled(token))) {
          await channels.setStatus(connection.id, 'live_disabled');
          return 'youtube_live_disabled';
        }
        stream = await youtube.createStream(token);
        await channels.setStream(connection.id, stream);
      } else if (connection.status !== 'ready') {
        await channels.setStatus(connection.id, 'ready');
      }
      const broadcast = await youtube.createBroadcast(token, {
        title: broadcastTitle(match, timeZone, this.now()),
        scheduledStartTime: new Date(this.now()).toISOString(),
      });
      await youtube.bind(token, broadcast.id, stream.id);
      this.update(match.id, (row) => {
        row.broadcast = {
          id: broadcast.id,
          watchUrl: broadcast.watchUrl,
          connectionId: connection.id,
          channelTitle: connection.channel_title,
          channelThumbnail: connection.channel_thumbnail,
          streamId: stream.id,
          ingestUrl: stream.ingestUrl,
        };
      });
      return null;
    } catch (error) {
      if (!(error instanceof YouTubeError)) throw error;
      console.warn('youtube_go_live_failed', error.code, error.reason ?? '');
      if (error.code === 'invalid_grant') {
        await channels.setStatus(connection.id, 'needs_reconnect');
        return 'youtube_needs_reconnect';
      }
      if (error.code === 'live_streaming_not_enabled') {
        await channels.setStatus(connection.id, 'live_disabled');
        return 'youtube_live_disabled';
      }
      return 'youtube_unavailable';
    }
  }

  /** The store accepted a start: run the container. */
  async started(gameId: string): Promise<void> {
    if (this.deps.store.media.get(gameId).broadcast.desired !== 'running') return;
    await this.startContainer(gameId);
  }

  /** The store accepted a stop: the input and broadcast stay for the next Go Live. */
  async stopped(gameId: string): Promise<void> {
    if (this.deps.store.media.get(gameId).broadcast.desired !== 'stopped') return;
    await this.stopContainer(gameId, 'stopped');
  }

  /** A start the store refused gives its live slot back. */
  async refused(gameId: string): Promise<void> {
    if (this.row(gameId)?.container !== 'running') await this.channels.releaseSlot(gameId);
  }

  private containerEnv(): Record<string, string> {
    const env = this.deps.env;
    return {
      CONTROL_PLANE_URL: 'http://api.internal/',
      HOME_TOKEN: WORKER_TOKEN,
      WORKER_ID,
      OUTPUT_ID,
      VIDEO_PROFILE: env.VIDEO_PROFILE || '1080p30',
      LOG_LEVEL: 'info',
      // Tuning from the Stream + Container spike (docs/superpowers/specs).
      SCORE_DELAY_MS: env.SCORE_DELAY_MS || '1100',
      INPUT_PROBE: 'fast',
      INPUT_READ_TIMEOUT_MS: '4000',
      OUTPUT_TIMEOUT_MS: '15000',
      RETRY_MAX_ATTEMPTS: '6',
      RETRY_FREE_AFTER_MS: '3000',
    };
  }

  private async startContainer(gameId: string): Promise<void> {
    const container = this.deps.container;
    if (!container) return;
    const now = this.now();
    this.update(gameId, (row) => {
      row.container = 'running';
      row.containerStartedAt = now;
      row.firstLiveAt ??= now;
      row.lastOutputAt = null;
    });
    this.deps.setAlarm(now + ALARM_MS);
    try {
      if (!container.running) await container.start(this.containerEnv());
    } catch (error) {
      // The alarm tries again; the row says it should be running.
      console.error('container_start_failed', String(error));
    }
  }

  private async stopContainer(gameId: string, next: 'stopped' | 'idle'): Promise<void> {
    const others = this.openRows().some(
      (row) => row.gameId !== gameId && row.container === 'running',
    );
    if (!others && this.deps.container?.running) await this.deps.container.destroy();
    this.update(gameId, (row) => {
      row.container = next;
    });
    await this.channels.releaseSlot(gameId);
  }

  /** The worker reported fresh output: the idle guard's clock. */
  onOutput(gameId: string): void {
    const row = this.row(gameId);
    if (!row || row.ended) return;
    const now = this.now();
    if (row.lastOutputAt !== null && now - row.lastOutputAt < OUTPUT_SAVE_MS) return;
    row.lastOutputAt = now;
    this.save(row);
  }

  /** Called after every request: an ended match is torn down by the next alarm, now. */
  checkEnded(): void {
    if (this.openRows().some((row) => this.deps.store.get(row.gameId)?.status !== 'active'))
      this.deps.setAlarm(this.now());
  }

  // --------------------------------------------------------- MediaLifecycle

  async publish(request: PublishRequest): Promise<PublishAssignment> {
    const current = () => this.deps.store.media.get(request.gameId).broadcast;
    const check = () => {
      const broadcast = current();
      if (broadcast.desired !== 'running' || broadcast.generation !== request.generation)
        throw new MediaLifecycleError('broadcast_changed');
      if (
        broadcast.selection?.captureDeviceId !== request.deviceId ||
        broadcast.selection.recordingId !== request.recordingId
      )
        throw new MediaLifecycleError('capture_not_selected');
    };
    check();
    let input: LiveInput;
    try {
      input = await this.ensureInput(request.gameId);
    } catch (error) {
      if (error instanceof MediaLifecycleError) throw error;
      throw new MediaLifecycleError('stream_unavailable');
    }
    check();
    // The phone is back after the idle guard parked the container: start it again.
    if (this.row(request.gameId)?.container === 'idle')
      this.deps.waitUntil(this.resume(request.gameId));
    return {
      gameId: request.gameId,
      generation: request.generation,
      recordingId: request.recordingId,
      // Stream's own stream ID and passphrase: the phone checks only the srt:// shape.
      publishUrl: input.publishUrl,
      publishingAttemptId: request.publishingAttemptId,
    };
  }

  async worker(workerId: string): Promise<WorkerConnection | null> {
    if (workerId !== WORKER_ID) return null;
    const assignment = this.deps.store.media.workerAssignment(workerId);
    if (!assignment) return null;
    const input = this.row(assignment.match.id)?.input;
    if (!input) return null;
    return {
      gameId: assignment.match.id,
      generation: assignment.media.broadcast.generation,
      readUrl: input.readUrl,
    };
  }

  // ------------------------------------------------------------------ guards

  private async resume(gameId: string): Promise<void> {
    if (this.row(gameId)?.container === 'running') return;
    if (!(await this.channels.claimSlot(gameId, this.team, this.cap))) {
      console.warn('match_resume_busy', gameId);
      return;
    }
    await this.startContainer(gameId);
  }

  /** End of match (or the 4-hour cap): nothing for this match keeps billing. */
  async teardown(gameId: string, reason: 'match_ended' | 'time_limit'): Promise<void> {
    await this.locked(`teardown:${gameId}`, async () => {
      const row = this.row(gameId);
      if (!row || row.ended) return;
      if (reason === 'time_limit') {
        const broadcast = this.deps.store.media.get(gameId).broadcast;
        if (broadcast.desired === 'running')
          this.deps.store.media.execute(
            {
              commandId: `time-limit-${broadcast.generation}`,
              gameId,
              expectedGeneration: broadcast.generation,
              issuedAt: new Date(this.now()).toISOString(),
              operation: { type: 'stop' },
            },
            { workerId: WORKER_ID, outputId: OUTPUT_ID },
          );
      }
      await this.stopContainer(gameId, 'stopped');
      if (row.input) {
        try {
          await this.deps.adapters.stream.deleteInput(row.input.uid);
        } catch (error) {
          // The daily sweep deletes it.
          console.error('stream_delete_failed', String(error));
        }
      }
      if (row.broadcast) await this.endBroadcast(row.broadcast);
      this.update(gameId, (next) => {
        next.input = null;
        next.ended = true;
        next.endReason = reason;
        next.container = 'stopped';
      });
      console.log('match_media_torn_down', gameId, reason);
    });
  }

  private async endBroadcast(broadcast: NonNullable<HostedRow['broadcast']>): Promise<void> {
    const channels = this.channels;
    const connection = await channels.connection(broadcast.connectionId);
    const refreshToken = connection ? await channels.refreshToken(connection) : null;
    if (!connection || !refreshToken) {
      console.error('youtube_end_skipped', broadcast.id);
      return;
    }
    try {
      const youtube = this.deps.adapters.youtube;
      await youtube.endBroadcast(await youtube.accessToken(refreshToken), broadcast.id);
    } catch (error) {
      if (!(error instanceof YouTubeError)) throw error;
      console.error('youtube_end_failed', error.code, broadcast.id);
      if (error.code === 'invalid_grant')
        await channels.setStatus(connection.id, 'needs_reconnect');
    }
  }

  /**
   * Every 30 s while anything is open: renew the container and its live slot, and apply the
   * guards (match end, 4-hour cap, 10-minute idle, restart when video returns or after a
   * container crash).
   */
  async alarm(): Promise<void> {
    const now = this.now();
    let again = false;
    for (const row of this.openRows()) {
      const match = this.deps.store.get(row.gameId);
      if (!match || match.status !== 'active') {
        await this.teardown(row.gameId, 'match_ended');
        continue;
      }
      if (row.firstLiveAt !== null && now - row.firstLiveAt >= MAX_LIVE_MS) {
        console.error('match_time_limit', row.gameId);
        await this.teardown(row.gameId, 'time_limit');
        continue;
      }
      const desired = this.deps.store.media.get(row.gameId).broadcast.desired === 'running';
      if (!desired) {
        if (row.container !== 'stopped') await this.stopContainer(row.gameId, 'stopped');
        continue;
      }
      again = true;
      const container = this.deps.container;
      if (row.container === 'running') {
        const last = Math.max(row.lastOutputAt ?? 0, row.containerStartedAt ?? 0);
        if (now - last >= IDLE_MS) {
          console.warn('match_idle', row.gameId);
          await this.stopContainer(row.gameId, 'idle');
          continue;
        }
        await this.channels.claimSlot(row.gameId, this.team, this.cap);
        if (container && !container.running) {
          console.warn('container_restart', row.gameId);
          await this.startContainer(row.gameId);
        } else await container?.renew(CONTAINER_TIMEOUT_MS);
      } else if (row.input) {
        // Parked: start again once video reaches Stream (a long gym outage recovers alone).
        let connected: boolean | null = false;
        try {
          connected = await this.deps.adapters.stream.connected(row.input.uid);
        } catch (error) {
          console.warn('stream_status_failed', String(error));
        }
        if (connected) await this.resume(row.gameId);
      }
    }
    if (again) this.deps.setAlarm(now + ALARM_MS);
  }

  /** Daily sweep: run the guards, then stop a container nothing wants. */
  async sweep(): Promise<{ inputs: string[] }> {
    await this.alarm();
    const container = this.deps.container;
    if (container?.running && !this.openRows().some((row) => row.container === 'running')) {
      console.error('sweep_orphan_container', this.deps.team() ?? 'unknown');
      await container.destroy();
    }
    return { inputs: this.referencedInputs() };
  }
}
