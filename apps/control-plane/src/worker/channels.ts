import { randomUUID } from 'node:crypto';
import { INGEST_URL, open, REFRESH_TOKEN, seal } from './secret-box.js';
import { randomToken, sha256Hex } from './state.js';
import type { Channel, LiveStreamInfo } from './youtube.js';

export type ConnectionStatus = 'ready' | 'live_disabled' | 'needs_reconnect';
/** What the API shows about a connection. Tokens and the stream key never leave the server. */
export type ConnectionView = {
  id: string;
  channelId: string;
  channelTitle: string;
  channelThumbnail: string | null;
  status: ConnectionStatus;
  createdAt: string;
  updatedAt: string;
};
export type ConnectionRow = {
  id: string;
  person_id: string;
  channel_id: string;
  channel_title: string;
  channel_thumbnail: string | null;
  refresh_token_enc: string;
  stream_id: string | null;
  ingest_enc: string | null;
  status: ConnectionStatus;
  created_at: number;
  updated_at: number;
};
/** Everything the team object needs to go live on the team's channel. */
export type TeamChannel = {
  connection: ConnectionRow;
  refreshToken: string | null;
  ingestUrl: string | null;
};

export const GRANT_TTL_MS = 10 * 60 * 1000;
/** A live slot not renewed for this long no longer counts (its team object stopped). */
export const SLOT_STALE_MS = 3 * 60 * 1000;
const iso = (ms: number) => new Date(ms).toISOString();

export const connectionView = (row: ConnectionRow): ConnectionView => ({
  id: row.id,
  channelId: row.channel_id,
  channelTitle: row.channel_title,
  channelThumbnail: row.channel_thumbnail,
  status: row.status,
  createdAt: iso(row.created_at),
  updatedAt: iso(row.updated_at),
});

/** D1 access for YouTube connections, grants, team channels and the beta-wide live cap. */
export class Channels {
  constructor(
    private readonly db: D1Database,
    private readonly secret: string,
    private readonly now: () => number = Date.now,
  ) {}

  // ------------------------------------------------------------------ grants

  /** Holds a fresh refresh token until the person's own session claims it. */
  async storeGrant(personId: string, refreshToken: string): Promise<string> {
    const ticket = randomToken();
    const now = this.now();
    await this.db.batch([
      this.db.prepare('DELETE FROM youtube_grants WHERE expires_at<=?').bind(now),
      this.db
        .prepare(
          'INSERT INTO youtube_grants(ticket_hash,person_id,refresh_token_enc,expires_at) VALUES(?,?,?,?)',
        )
        .bind(
          sha256Hex(ticket),
          personId,
          await seal(this.secret, REFRESH_TOKEN, refreshToken),
          now + GRANT_TTL_MS,
        ),
    ]);
    return ticket;
  }

  /** Single use, and only for the person who started the connection. */
  async redeemGrant(ticket: string, personId: string): Promise<string | null> {
    const row = await this.db
      .prepare(
        'DELETE FROM youtube_grants WHERE ticket_hash=? AND person_id=? AND expires_at>? RETURNING refresh_token_enc',
      )
      .bind(sha256Hex(ticket), personId, this.now())
      .first<{ refresh_token_enc: string }>();
    return row ? open(this.secret, REFRESH_TOKEN, row.refresh_token_enc) : null;
  }

  // ------------------------------------------------------------- connections

  async saveConnection(input: {
    personId: string;
    channel: Channel;
    refreshToken: string;
    stream: LiveStreamInfo | null;
    status: ConnectionStatus;
  }): Promise<ConnectionRow> {
    const now = this.now();
    const row = await this.db
      .prepare(
        `INSERT INTO youtube_connections(id,person_id,channel_id,channel_title,channel_thumbnail,
          refresh_token_enc,stream_id,ingest_enc,status,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(person_id,channel_id) DO UPDATE SET channel_title=excluded.channel_title,
          channel_thumbnail=excluded.channel_thumbnail, refresh_token_enc=excluded.refresh_token_enc,
          stream_id=excluded.stream_id, ingest_enc=excluded.ingest_enc, status=excluded.status,
          updated_at=excluded.updated_at
        RETURNING *`,
      )
      .bind(
        randomUUID(),
        input.personId,
        input.channel.id,
        input.channel.title,
        input.channel.thumbnail,
        await seal(this.secret, REFRESH_TOKEN, input.refreshToken),
        input.stream?.id ?? null,
        input.stream ? await seal(this.secret, INGEST_URL, input.stream.ingestUrl) : null,
        input.status,
        now,
        now,
      )
      .first<ConnectionRow>();
    return row!;
  }

  /** The existing connection for a person's channel, so a reconnect keeps its stream. */
  connectionFor(personId: string, channelId: string): Promise<ConnectionRow | null> {
    return this.db
      .prepare('SELECT * FROM youtube_connections WHERE person_id=? AND channel_id=?')
      .bind(personId, channelId)
      .first<ConnectionRow>();
  }

  connection(id: string): Promise<ConnectionRow | null> {
    return this.db
      .prepare('SELECT * FROM youtube_connections WHERE id=?')
      .bind(id)
      .first<ConnectionRow>();
  }

  async connections(personId: string): Promise<ConnectionView[]> {
    const { results } = await this.db
      .prepare('SELECT * FROM youtube_connections WHERE person_id=? ORDER BY created_at')
      .bind(personId)
      .all<ConnectionRow>();
    return results.map(connectionView);
  }

  async setStatus(id: string, status: ConnectionStatus): Promise<void> {
    await this.db
      .prepare('UPDATE youtube_connections SET status=?, updated_at=? WHERE id=?')
      .bind(status, this.now(), id)
      .run();
  }

  async setStream(id: string, stream: LiveStreamInfo): Promise<void> {
    await this.db
      .prepare(
        'UPDATE youtube_connections SET stream_id=?, ingest_enc=?, status=?, updated_at=? WHERE id=?',
      )
      .bind(
        stream.id,
        await seal(this.secret, INGEST_URL, stream.ingestUrl),
        'ready',
        this.now(),
        id,
      )
      .run();
  }

  /** Removes a person's connection; teams that streamed to it have no channel afterwards. */
  async remove(personId: string, id: string): Promise<boolean> {
    const owned = await this.db
      .prepare('SELECT 1 AS ok FROM youtube_connections WHERE id=? AND person_id=?')
      .bind(id, personId)
      .first();
    if (!owned) return false;
    await this.db.batch([
      this.db
        .prepare('UPDATE teams SET youtube_connection_id=NULL WHERE youtube_connection_id=?')
        .bind(id),
      this.db.prepare('DELETE FROM youtube_connections WHERE id=?').bind(id),
    ]);
    return true;
  }

  refreshToken(row: ConnectionRow): Promise<string | null> {
    return open(this.secret, REFRESH_TOKEN, row.refresh_token_enc);
  }

  ingestUrl(row: ConnectionRow): Promise<string | null> {
    return row.ingest_enc ? open(this.secret, INGEST_URL, row.ingest_enc) : Promise.resolve(null);
  }

  // ------------------------------------------------------------ team channel

  async teamConnection(teamId: string): Promise<ConnectionRow | null> {
    return this.db
      .prepare(
        `SELECT c.* FROM teams t JOIN youtube_connections c ON c.id=t.youtube_connection_id
        WHERE t.id=?`,
      )
      .bind(teamId)
      .first<ConnectionRow>();
  }

  async teamChannel(teamId: string): Promise<TeamChannel | null> {
    const connection = await this.teamConnection(teamId);
    if (!connection) return null;
    const [refreshToken, ingestUrl] = await Promise.all([
      this.refreshToken(connection),
      this.ingestUrl(connection),
    ]);
    return { connection, refreshToken, ingestUrl };
  }

  async setTeamChannel(teamId: string, connectionId: string | null): Promise<void> {
    await this.db
      .prepare('UPDATE teams SET youtube_connection_id=? WHERE id=?')
      .bind(connectionId, teamId)
      .run();
  }

  // ------------------------------------------------------------- live slots

  /**
   * Claims (or renews) a live slot for the match. False when `cap` other matches already
   * hold fresh slots: the beta cost guard.
   */
  async claimSlot(gameId: string, teamId: string, cap: number): Promise<boolean> {
    const now = this.now();
    const fresh = now - SLOT_STALE_MS;
    const renewed = await this.db
      .prepare('UPDATE live_slots SET renewed_at=? WHERE game_id=? AND renewed_at>?')
      .bind(now, gameId, fresh)
      .run();
    if (renewed.meta.changes > 0) return true;
    // One statement, so concurrent claims from different team objects cannot both pass.
    const claimed = await this.db
      .prepare(
        `INSERT INTO live_slots(game_id,team_id,claimed_at,renewed_at)
        SELECT ?,?,?,? WHERE (SELECT COUNT(*) FROM live_slots WHERE renewed_at>? AND game_id<>?)<?
        ON CONFLICT(game_id) DO UPDATE SET team_id=excluded.team_id, claimed_at=excluded.claimed_at,
          renewed_at=excluded.renewed_at`,
      )
      .bind(gameId, teamId, now, now, fresh, gameId, cap)
      .run();
    return claimed.meta.changes > 0;
  }

  async releaseSlot(gameId: string): Promise<void> {
    await this.db.prepare('DELETE FROM live_slots WHERE game_id=?').bind(gameId).run();
  }

  async liveCount(): Promise<number> {
    const row = await this.db
      .prepare('SELECT COUNT(*) AS n FROM live_slots WHERE renewed_at>?')
      .bind(this.now() - SLOT_STALE_MS)
      .first<{ n: number }>();
    return row?.n ?? 0;
  }
}
