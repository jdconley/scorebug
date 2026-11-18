import type { Directory, Person } from './directory.js';
import type { TeamObject } from './team-object.js';

/** Bindings from wrangler.jsonc, plus the secrets set with `wrangler secret put`. */
export interface Env {
  DB: D1Database;
  /** Files in public/ (fonts and icons). Cloudflare serves them before the Worker runs. */
  ASSETS: Fetcher;
  TEAM: DurableObjectNamespace<TeamObject>;
  /** 20 requests / 60 s per client IP: /v1/auth/*. */
  AUTH_LIMIT: RateLimit;
  /** 10 requests / 60 s per client IP: match code redemption and team invite accept. */
  REDEEM_LIMIT: RateLimit;
  /** https://scorebug.live */
  PUBLIC_URL: string;
  /** scorebug://auth */
  APP_AUTH_REDIRECT: string;
  /** The app's App Store page. Empty until it's live: the site then says "Coming soon". */
  APP_STORE_URL: string;
  /** Comma-separated emails that may open /admin. A secret, so no address is committed. */
  ADMIN_EMAILS: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  /** At least 32 characters: HMAC key for OAuth state, route codes and match credentials,
   * and the root of the key that encrypts YouTube tokens in D1. */
  SERVER_SECRET: string;
  /** Cloudflare account that owns the Stream live inputs (a var, not a secret). */
  CF_ACCOUNT_ID: string;
  /** Stream:Edit API token. A secret. */
  STREAM_API_TOKEN: string;
  /** Service-wide live cap: concurrent live matches across every team, to bound the bill. */
  LIVE_MATCH_CAP: string;
  /** Hold score changes this long in the match container (Stream intake delay). */
  SCORE_DELAY_MS: string;
  /** The match container's video profile: 1080p30, or 720p30 as the fallback. */
  VIDEO_PROFILE: string;
}

export type AppEnv = { Bindings: Env; Variables: { directory: Directory } };
export type PersonEnv = { Bindings: Env; Variables: { directory: Directory; person: Person } };
