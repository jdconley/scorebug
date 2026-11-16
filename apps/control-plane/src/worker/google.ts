import type { Env } from './env.js';

export type GoogleIdentity = {
  sub: string;
  email: string;
  emailVerified: boolean;
  name: string | null;
  picture: string | null;
};
export type GoogleGrant = {
  identity: GoogleIdentity;
  refreshToken: string | null;
  scopes: string[];
};
export class GoogleOAuthError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
/** Google's OAuth endpoints, behind an interface so tests need no network. */
export interface GoogleOAuth {
  authorizeUrl(p: {
    state: string;
    scopes: string[];
    redirectUri: string;
    prompt: 'select_account' | 'consent';
    loginHint?: string;
  }): string;
  /** Throws GoogleOAuthError. */
  exchange(code: string, redirectUri: string): Promise<GoogleGrant>;
}

const AUTHORIZE = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN = 'https://oauth2.googleapis.com/token';
const ISSUERS = new Set(['https://accounts.google.com', 'accounts.google.com']);

function decodeJwtPayload(jwt: string): Record<string, unknown> {
  const part = jwt.split('.')[1];
  if (!part) throw new GoogleOAuthError('id_token_invalid');
  try {
    const json = new TextDecoder().decode(
      Uint8Array.from(atob(part.replace(/-/g, '+').replace(/_/g, '/')), (ch) => ch.charCodeAt(0)),
    );
    return JSON.parse(json) as Record<string, unknown>;
  } catch {
    throw new GoogleOAuthError('id_token_invalid');
  }
}

/** Reads identity claims from an id_token received straight from Google's token endpoint over
 * TLS, so the signature check (JWKS) is not needed; audience, issuer and expiry still are. */
export function identityFromIdToken(
  idToken: string,
  clientId: string,
  nowMs: number,
): GoogleIdentity {
  const claims = decodeJwtPayload(idToken);
  const aud = claims.aud;
  if (aud !== clientId && !(Array.isArray(aud) && aud.includes(clientId)))
    throw new GoogleOAuthError('id_token_audience');
  if (typeof claims.iss !== 'string' || !ISSUERS.has(claims.iss))
    throw new GoogleOAuthError('id_token_issuer');
  if (typeof claims.exp !== 'number' || claims.exp * 1000 <= nowMs)
    throw new GoogleOAuthError('id_token_expired');
  if (typeof claims.sub !== 'string' || !claims.sub || typeof claims.email !== 'string')
    throw new GoogleOAuthError('id_token_invalid');
  return {
    sub: claims.sub,
    email: claims.email,
    emailVerified: claims.email_verified === true || claims.email_verified === 'true',
    name: typeof claims.name === 'string' ? claims.name : null,
    picture: typeof claims.picture === 'string' ? claims.picture : null,
  };
}

export function realGoogle(
  env: Pick<Env, 'GOOGLE_CLIENT_ID' | 'GOOGLE_CLIENT_SECRET'>,
  fetcher: typeof fetch = fetch,
  now: () => number = Date.now,
): GoogleOAuth {
  return {
    authorizeUrl({ state, scopes, redirectUri, prompt, loginHint }) {
      const url = new URL(AUTHORIZE);
      url.searchParams.set('client_id', env.GOOGLE_CLIENT_ID);
      url.searchParams.set('redirect_uri', redirectUri);
      url.searchParams.set('response_type', 'code');
      url.searchParams.set('scope', scopes.join(' '));
      url.searchParams.set('state', state);
      url.searchParams.set('prompt', prompt);
      url.searchParams.set('include_granted_scopes', 'true');
      if (loginHint) url.searchParams.set('login_hint', loginHint);
      return url.toString();
    },
    async exchange(code, redirectUri) {
      let response: Response;
      try {
        response = await fetcher(TOKEN, {
          method: 'POST',
          headers: { 'content-type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            code,
            client_id: env.GOOGLE_CLIENT_ID,
            client_secret: env.GOOGLE_CLIENT_SECRET,
            redirect_uri: redirectUri,
            grant_type: 'authorization_code',
          }),
        });
      } catch {
        throw new GoogleOAuthError('google_unreachable');
      }
      if (!response.ok) throw new GoogleOAuthError('token_exchange_failed');
      const body = (await response.json()) as {
        id_token?: string;
        refresh_token?: string;
        scope?: string;
      };
      if (!body.id_token) throw new GoogleOAuthError('id_token_missing');
      return {
        identity: identityFromIdToken(body.id_token, env.GOOGLE_CLIENT_ID, now()),
        refreshToken: body.refresh_token ?? null,
        scopes: (body.scope ?? '').split(' ').filter(Boolean),
      };
    },
  };
}
