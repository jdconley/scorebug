import type { GoogleGrant, GoogleIdentity, GoogleOAuth } from '../src/worker/google.js';
import { GoogleOAuthError } from '../src/worker/google.js';

/** In-memory Google: `grant()` scripts the identity a later callback code exchanges for. */
export class FakeGoogle implements GoogleOAuth {
  private readonly grants = new Map<string, GoogleGrant>();
  private next = 0;
  readonly authorizeCalls: Parameters<GoogleOAuth['authorizeUrl']>[0][] = [];
  readonly revoked: string[] = [];
  /** Makes every revoke fail, as when Google is unreachable. */
  revokeFails = false;

  grant(identity: Partial<GoogleIdentity> & { email: string }): string {
    const code = `code-${++this.next}`;
    this.grants.set(code, {
      identity: {
        sub: identity.sub ?? `sub-${identity.email.trim().toLowerCase()}`,
        email: identity.email,
        emailVerified: identity.emailVerified ?? true,
        name: identity.name ?? 'Test Person',
        picture: identity.picture ?? null,
      },
      refreshToken: null,
      scopes: ['openid', 'email', 'profile'],
    });
    return code;
  }

  authorizeUrl(p: Parameters<GoogleOAuth['authorizeUrl']>[0]): string {
    this.authorizeCalls.push(p);
    const url = new URL('https://accounts.google.test/o/oauth2/v2/auth');
    url.searchParams.set('state', p.state);
    url.searchParams.set('scope', p.scopes.join(' '));
    url.searchParams.set('redirect_uri', p.redirectUri);
    url.searchParams.set('prompt', p.prompt);
    if (p.accessType) url.searchParams.set('access_type', p.accessType);
    return url.toString();
  }

  /** Scripts a channel-connection grant; `youtube: false` models an unticked box. */
  youtubeGrant(opts: { refreshToken?: string | null; youtube?: boolean } = {}): string {
    const code = `code-${++this.next}`;
    this.grants.set(code, {
      identity: { sub: 'unused', email: 'unused', emailVerified: true, name: null, picture: null },
      refreshToken: opts.refreshToken === undefined ? `refresh-${code}` : opts.refreshToken,
      scopes: opts.youtube === false ? [] : ['https://www.googleapis.com/auth/youtube'],
    });
    return code;
  }

  async exchangeForRefreshToken(code: string) {
    const grant = await this.exchange(code);
    return { refreshToken: grant.refreshToken, scopes: grant.scopes };
  }

  async revoke(refreshToken: string) {
    if (this.revokeFails) throw new GoogleOAuthError('google_unreachable');
    this.revoked.push(refreshToken);
  }

  async exchange(code: string): Promise<GoogleGrant> {
    const grant = this.grants.get(code);
    if (!grant) throw new GoogleOAuthError('invalid_grant');
    this.grants.delete(code);
    return grant;
  }
}
