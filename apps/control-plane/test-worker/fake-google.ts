import type { GoogleGrant, GoogleIdentity, GoogleOAuth } from '../src/worker/google.js';
import { GoogleOAuthError } from '../src/worker/google.js';

/** In-memory Google: `grant()` scripts the identity a later callback code exchanges for. */
export class FakeGoogle implements GoogleOAuth {
  private readonly grants = new Map<string, GoogleGrant>();
  private next = 0;
  readonly authorizeCalls: Parameters<GoogleOAuth['authorizeUrl']>[0][] = [];

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
    return url.toString();
  }

  async exchange(code: string): Promise<GoogleGrant> {
    const grant = this.grants.get(code);
    if (!grant) throw new GoogleOAuthError('invalid_grant');
    this.grants.delete(code);
    return grant;
  }
}
