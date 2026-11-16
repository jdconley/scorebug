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
  /** Comma-separated emails that may open /admin. A secret, so no address is committed. */
  ADMIN_EMAILS: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  /** At least 32 characters: HMAC key for OAuth state, route codes and match credentials. */
  SERVER_SECRET: string;
}

export type AppEnv = { Bindings: Env; Variables: { directory: Directory } };
export type PersonEnv = { Bindings: Env; Variables: { directory: Directory; person: Person } };
