import type { Env } from './env.js';

/** The `youtube` scope: manage the channel's live broadcasts and streams. */
export const YOUTUBE_SCOPE = 'https://www.googleapis.com/auth/youtube';

export type Channel = { id: string; title: string; thumbnail: string | null };
/** `ingestUrl` is the RTMPS address with the stream key appended: a secret. */
export type LiveStreamInfo = { id: string; ingestUrl: string };
export type Broadcast = { id: string; watchUrl: string };
export type BroadcastRequest = { title: string; scheduledStartTime: string };

export type YouTubeErrorCode =
  /** The refresh token was revoked or expired: the person must connect again. */
  | 'invalid_grant'
  | 'live_streaming_not_enabled'
  | 'no_channel'
  | 'quota_exceeded'
  | 'not_found'
  | 'youtube_unavailable'
  | 'youtube_error';
export class YouTubeError extends Error {
  constructor(
    readonly code: YouTubeErrorCode,
    readonly reason: string | null = null,
  ) {
    super(code);
  }
}

/** The YouTube Data API calls Scorebug makes, behind an interface so tests need no network. */
export interface YouTubeApi {
  /** Trades a refresh token for an access token. Throws YouTubeError('invalid_grant'). */
  accessToken(refreshToken: string): Promise<string>;
  /** The channel the grant was made for. Throws YouTubeError('no_channel'). */
  channel(accessToken: string): Promise<Channel>;
  /** False until the channel has live streaming enabled (YouTube's 24-hour wait). */
  liveEnabled(accessToken: string): Promise<boolean>;
  /** A reusable RTMP stream: one per connection, bound to every broadcast. */
  createStream(accessToken: string): Promise<LiveStreamInfo>;
  /** Null when the stream no longer exists (deleted in YouTube Studio). */
  stream(accessToken: string, streamId: string): Promise<LiveStreamInfo | null>;
  createBroadcast(accessToken: string, request: BroadcastRequest): Promise<Broadcast>;
  bind(accessToken: string, broadcastId: string, streamId: string): Promise<void>;
  /** Ends a broadcast that went live; deletes one that never did. Missing is fine. */
  endBroadcast(accessToken: string, broadcastId: string): Promise<void>;
}

export const watchUrl = (broadcastId: string) =>
  `https://www.youtube.com/watch?v=${encodeURIComponent(broadcastId)}`;

const TOKEN = 'https://oauth2.googleapis.com/token';
const API = 'https://www.googleapis.com/youtube/v3/';
const TITLE_LIMIT = 100;

type ApiErrorBody = { error?: { errors?: { reason?: string }[]; status?: string } | string };
type StreamResource = {
  id?: string;
  cdn?: { ingestionInfo?: { rtmpsIngestionAddress?: string; streamName?: string } };
};

function streamInfo(resource: StreamResource | undefined): LiveStreamInfo | null {
  const address = resource?.cdn?.ingestionInfo?.rtmpsIngestionAddress;
  const name = resource?.cdn?.ingestionInfo?.streamName;
  if (!resource?.id || !address || !name) return null;
  return { id: resource.id, ingestUrl: `${address.replace(/\/$/, '')}/${name}` };
}

export function realYouTube(
  env: Pick<Env, 'GOOGLE_CLIENT_ID' | 'GOOGLE_CLIENT_SECRET'>,
  fetcher: typeof fetch = fetch,
): YouTubeApi {
  async function call<T>(
    accessToken: string,
    method: 'GET' | 'POST' | 'DELETE',
    path: string,
    query: Record<string, string>,
    body?: unknown,
  ): Promise<T> {
    const url = new URL(path, API);
    for (const [name, value] of Object.entries(query)) url.searchParams.set(name, value);
    let response: Response;
    try {
      response = await fetcher(url, {
        method,
        headers: {
          authorization: `Bearer ${accessToken}`,
          ...(body === undefined ? {} : { 'content-type': 'application/json' }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    } catch {
      throw new YouTubeError('youtube_unavailable');
    }
    if (response.ok) {
      const text = await response.text();
      return (text ? JSON.parse(text) : {}) as T;
    }
    const error = (await response.json().catch(() => ({}))) as ApiErrorBody;
    const reason =
      typeof error.error === 'object' ? (error.error.errors?.[0]?.reason ?? null) : null;
    if (reason === 'liveStreamingNotEnabled' || reason === 'insufficientLivePermissions')
      throw new YouTubeError('live_streaming_not_enabled', reason);
    if (reason === 'quotaExceeded' || reason === 'rateLimitExceeded')
      throw new YouTubeError('quota_exceeded', reason);
    if (response.status === 404) throw new YouTubeError('not_found', reason);
    if (response.status >= 500) throw new YouTubeError('youtube_unavailable', reason);
    throw new YouTubeError('youtube_error', reason ?? `http_${response.status}`);
  }

  return {
    async accessToken(refreshToken) {
      let response: Response;
      try {
        response = await fetcher(TOKEN, {
          method: 'POST',
          headers: { 'content-type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: env.GOOGLE_CLIENT_ID,
            client_secret: env.GOOGLE_CLIENT_SECRET,
            refresh_token: refreshToken,
            grant_type: 'refresh_token',
          }),
        });
      } catch {
        throw new YouTubeError('youtube_unavailable');
      }
      const body = (await response.json().catch(() => ({}))) as {
        access_token?: string;
        error?: string;
      };
      if (body.error === 'invalid_grant') throw new YouTubeError('invalid_grant');
      if (!response.ok || !body.access_token)
        throw new YouTubeError(
          response.status >= 500 ? 'youtube_unavailable' : 'youtube_error',
          body.error ?? null,
        );
      return body.access_token;
    },

    async channel(accessToken) {
      const body = await call<{
        items?: {
          id?: string;
          snippet?: { title?: string; thumbnails?: Record<string, { url?: string }> };
        }[];
      }>(accessToken, 'GET', 'channels', { part: 'snippet', mine: 'true' });
      const item = body.items?.[0];
      if (!item?.id) throw new YouTubeError('no_channel');
      const thumbnails = item.snippet?.thumbnails ?? {};
      return {
        id: item.id,
        title: item.snippet?.title ?? 'YouTube channel',
        thumbnail: thumbnails.medium?.url ?? thumbnails.default?.url ?? null,
      };
    },

    async liveEnabled(accessToken) {
      try {
        await call(accessToken, 'GET', 'liveBroadcasts', {
          part: 'id',
          mine: 'true',
          maxResults: '1',
        });
        return true;
      } catch (error) {
        if (error instanceof YouTubeError && error.code === 'live_streaming_not_enabled')
          return false;
        throw error;
      }
    },

    async createStream(accessToken) {
      const body = await call<StreamResource>(
        accessToken,
        'POST',
        'liveStreams',
        { part: 'snippet,cdn,contentDetails' },
        {
          snippet: { title: 'Scorebug' },
          cdn: { ingestionType: 'rtmp', resolution: 'variable', frameRate: 'variable' },
          contentDetails: { isReusable: true },
        },
      );
      const info = streamInfo(body);
      if (!info) throw new YouTubeError('youtube_error', 'stream_without_ingest');
      return info;
    },

    async stream(accessToken, streamId) {
      const body = await call<{ items?: StreamResource[] }>(accessToken, 'GET', 'liveStreams', {
        part: 'cdn',
        id: streamId,
      });
      return streamInfo(body.items?.[0]);
    },

    async createBroadcast(accessToken, request) {
      const title = Array.from(request.title).slice(0, TITLE_LIMIT).join('');
      const body = await call<{ id?: string }>(
        accessToken,
        'POST',
        'liveBroadcasts',
        { part: 'snippet,status,contentDetails' },
        {
          snippet: { title, scheduledStartTime: request.scheduledStartTime },
          status: { privacyStatus: 'unlisted', selfDeclaredMadeForKids: false },
          contentDetails: {
            enableAutoStart: true,
            enableAutoStop: false,
            latencyPreference: 'low',
            enableDvr: true,
            monitorStream: { enableMonitorStream: false },
          },
        },
      );
      if (!body.id) throw new YouTubeError('youtube_error', 'broadcast_without_id');
      return { id: body.id, watchUrl: watchUrl(body.id) };
    },

    async bind(accessToken, broadcastId, streamId) {
      await call(accessToken, 'POST', 'liveBroadcasts/bind', {
        id: broadcastId,
        streamId,
        part: 'id',
      });
    },

    async endBroadcast(accessToken, broadcastId) {
      try {
        await call(accessToken, 'POST', 'liveBroadcasts/transition', {
          broadcastStatus: 'complete',
          id: broadcastId,
          part: 'status',
        });
      } catch (error) {
        if (!(error instanceof YouTubeError)) throw error;
        if (error.code === 'not_found' || error.reason === 'redundantTransition') return;
        // Never went live (still "ready"): remove the empty scheduled event instead.
        if (error.reason === 'invalidTransition') {
          try {
            await call(accessToken, 'DELETE', 'liveBroadcasts', { id: broadcastId });
          } catch (cause) {
            if (!(cause instanceof YouTubeError && cause.code === 'not_found')) throw cause;
          }
          return;
        }
        throw error;
      }
    },
  };
}
