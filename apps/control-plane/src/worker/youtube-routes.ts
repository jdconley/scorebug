import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { z } from 'zod';
import { requirePerson } from './auth-routes.js';
import { Channels, connectionView, type ConnectionRow, type ConnectionView } from './channels.js';
import type { AppEnv, Env, PersonEnv } from './env.js';
import { GoogleOAuthError, type GoogleOAuth } from './google.js';
import { invalid, readJson, serverTime } from './http.js';
import { signState, STATE_TTL_MS, type OAuthState } from './state.js';
import { YOUTUBE_SCOPE, YouTubeError, type YouTubeApi } from './youtube.js';

export const YOUTUBE_SCOPES = [YOUTUBE_SCOPE];
export const channels = (c: { env: Env }, now: () => number) =>
  new Channels(c.env.DB, c.env.SERVER_SECRET, now);

/** Where the connect flow ends: `scorebug://auth?purpose=youtube&status=…[&ticket=…]`. */
export type YouTubeCallbackStatus = 'ok' | 'cancelled' | 'scope_denied' | 'error';

/**
 * Finishes a connection from a refresh token: reads the channel, checks live streaming and
 * makes sure the connection has its reusable liveStream. A reconnect of the same channel
 * keeps its stream (and so its ingest URL).
 */
export async function completeConnection(
  store: Channels,
  youtube: YouTubeApi,
  personId: string,
  refreshToken: string,
): Promise<ConnectionRow> {
  const accessToken = await youtube.accessToken(refreshToken);
  const channel = await youtube.channel(accessToken);
  const existing = await store.connectionFor(personId, channel.id);
  const enabled = await youtube.liveEnabled(accessToken);
  let stream = null;
  if (enabled) {
    if (existing?.stream_id) stream = await youtube.stream(accessToken, existing.stream_id);
    stream ??= await youtube.createStream(accessToken);
  }
  return store.saveConnection({
    personId,
    channel,
    refreshToken,
    stream,
    status: enabled ? 'ready' : 'live_disabled',
  });
}

/** Maps adapter failures to API errors; invalid_grant marks the connection. */
export async function youtubeFailure(
  c: Context,
  store: Channels,
  error: unknown,
  connectionId?: string,
): Promise<Response> {
  if (!(error instanceof YouTubeError)) throw error;
  console.warn('youtube_call_failed', error.code, error.reason ?? '');
  if (error.code === 'invalid_grant') {
    if (connectionId) await store.setStatus(connectionId, 'needs_reconnect');
    return c.json({ error: 'youtube_needs_reconnect' }, 409);
  }
  if (error.code === 'no_channel') return c.json({ error: 'youtube_no_channel' }, 409);
  if (error.code === 'quota_exceeded') return c.json({ error: 'youtube_quota' }, 503);
  return c.json({ error: 'youtube_unavailable' }, 503);
}

/** The callback leg, called by /v1/auth/google/callback for `purpose: 'youtube'` states. */
export function youtubeCallback(google: GoogleOAuth, redirectUri: (env: Env) => string) {
  return async (
    c: Context<AppEnv>,
    state: Extract<OAuthState, { purpose: 'youtube' }>,
  ): Promise<Response> => {
    const toApp = (status: YouTubeCallbackStatus, ticket?: string) => {
      const query = new URLSearchParams({ purpose: 'youtube', status });
      if (ticket) query.set('ticket', ticket);
      return c.redirect(`${c.env.APP_AUTH_REDIRECT}?${query}`, 302);
    };
    const error = c.req.query('error');
    if (error) return toApp(error === 'access_denied' ? 'cancelled' : 'error');
    const code = c.req.query('code');
    if (!code) return toApp('error');
    let grant: { refreshToken: string | null; scopes: string[] };
    try {
      grant = await google.exchangeForRefreshToken(code, redirectUri(c.env));
    } catch (cause) {
      if (cause instanceof GoogleOAuthError) {
        console.warn('google_exchange_failed', cause.code);
        return toApp('error');
      }
      throw cause;
    }
    // Google's granular consent lets the person untick the YouTube box.
    if (!grant.scopes.includes(YOUTUBE_SCOPE)) return toApp('scope_denied');
    if (!grant.refreshToken) return toApp('error');
    const ticket = await channels(c, c.var.directory.now).storeGrant(
      state.person,
      grant.refreshToken,
    );
    return toApp('ok', ticket);
  };
}

/** Mounted at /v1/youtube. */
export function youtubeRoutes(
  google: GoogleOAuth,
  youtube: () => YouTubeApi,
  redirectUri: (env: Env) => string,
) {
  const app = new Hono<PersonEnv>();
  app.use('*', requirePerson() as MiddlewareHandler<PersonEnv>);

  /** Step 1: the app opens `url` in ASWebAuthenticationSession. */
  app.post('/connect', (c) => {
    const state = signState(c.env.SERVER_SECRET, {
      purpose: 'youtube',
      person: c.var.person.id,
      exp: c.var.directory.now() + STATE_TTL_MS,
    });
    const url = google.authorizeUrl({
      state,
      scopes: YOUTUBE_SCOPES,
      redirectUri: redirectUri(c.env),
      // Consent every time, so Google returns a refresh token; the account chooser lets a
      // club owner pick the club's Google account (and Google then asks which channel).
      prompt: 'select_account consent',
      accessType: 'offline',
    });
    return c.json({ url, serverTime: serverTime() });
  });

  /** Step 2: the app claims the callback's ticket with its own session. */
  const claim = z.object({ ticket: z.string().regex(/^[A-Za-z0-9_-]{43}$/) }).strict();
  app.post('/connections', async (c) => {
    const input = await readJson(c, claim);
    if (!input) return invalid(c);
    const store = channels(c, c.var.directory.now);
    const refreshToken = await store.redeemGrant(input.ticket, c.var.person.id);
    if (!refreshToken) return c.json({ error: 'ticket_invalid' }, 404);
    let row: ConnectionRow;
    try {
      row = await completeConnection(store, youtube(), c.var.person.id, refreshToken);
    } catch (error) {
      return youtubeFailure(c, store, error);
    }
    return c.json({ connection: connectionView(row), serverTime: serverTime() }, 201);
  });

  app.get('/connections', async (c) =>
    c.json({
      connections: await channels(c, c.var.directory.now).connections(c.var.person.id),
      serverTime: serverTime(),
    }),
  );

  /** Re-checks a connection: after YouTube's 24-hour live-streaming wait, for example. */
  app.post('/connections/:id/check', async (c) => {
    const store = channels(c, c.var.directory.now);
    const row = await store.connection(c.req.param('id'));
    if (!row || row.person_id !== c.var.person.id)
      return c.json({ error: 'connection_not_found' }, 404);
    const refreshToken = await store.refreshToken(row);
    if (!refreshToken) {
      await store.setStatus(row.id, 'needs_reconnect');
      return c.json({ error: 'youtube_needs_reconnect' }, 409);
    }
    let checked: ConnectionRow;
    try {
      checked = await completeConnection(store, youtube(), c.var.person.id, refreshToken);
    } catch (error) {
      return youtubeFailure(c, store, error, row.id);
    }
    return c.json({ connection: connectionView(checked), serverTime: serverTime() });
  });

  app.delete('/connections/:id', async (c) => {
    const removed = await channels(c, c.var.directory.now).remove(
      c.var.person.id,
      c.req.param('id'),
    );
    return removed ? c.body(null, 204) : c.json({ error: 'connection_not_found' }, 404);
  });
  return app;
}

/** The team's channel as members see it. */
export type TeamYouTube = {
  connectionId: string;
  channelTitle: string;
  channelThumbnail: string | null;
  status: ConnectionView['status'];
  /** The person whose connection this is (only that person can fix it). */
  connectedBy: string;
} | null;

export const teamYouTubeView = (row: ConnectionRow | null): TeamYouTube =>
  row
    ? {
        connectionId: row.id,
        channelTitle: row.channel_title,
        channelThumbnail: row.channel_thumbnail,
        status: row.status,
        connectedBy: row.person_id,
      }
    : null;
