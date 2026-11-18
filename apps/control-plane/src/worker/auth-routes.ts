import { Hono, type MiddlewareHandler } from 'hono';
import { createMiddleware } from 'hono/factory';
import { z } from 'zod';
import type { Person } from './directory.js';
import type { AppEnv, Env, PersonEnv } from './env.js';
import { GoogleOAuthError, type GoogleIdentity, type GoogleOAuth } from './google.js';
import { bearerToken, invalid, limited, readJson, serverTime } from './http.js';
import {
  CHALLENGE_PATTERN,
  normalizeEmail,
  normalizeTeamInviteCode,
  routeCodeHash,
  sha256Base64url,
  signState,
  STATE_TTL_MS,
  VERIFIER_PATTERN,
  verifyState,
  type OAuthState,
} from './state.js';

export type { Person };
export const SIGN_IN_SCOPES = ['openid', 'email', 'profile'];

/** Bearer session token → `c.var.person`, else 401. */
export function requirePerson(): MiddlewareHandler<PersonEnv> {
  return createMiddleware<PersonEnv>(async (c, next) => {
    const person = await c.var.directory.sessionPerson(bearerToken(c));
    if (!person) return c.json({ error: 'unauthorized' }, 401);
    c.set('person', person);
    await next();
  });
}

/** ADMIN_EMAILS, a comma-separated Worker secret, compared normalized. */
export const isAdmin = (env: Env, email: string) =>
  (env.ADMIN_EMAILS ?? '')
    .split(',')
    .map(normalizeEmail)
    .filter(Boolean)
    .includes(normalizeEmail(email));

export const callbackUrl = (env: Env) => `${env.PUBLIC_URL}/v1/auth/google/callback`;

export type SignInOutcome = { status: 'ok'; person: Person } | { status: 'cancelled' | 'error' };

export type SignInState = Exclude<OAuthState, { purpose: 'youtube' }>;
/** What the callback does with a signed-in admin browser; set up by the admin page. */
export type AdminCallback = (
  c: Parameters<MiddlewareHandler<AppEnv>>[0],
  state: SignInState,
  outcome: SignInOutcome,
) => Promise<Response>;
/** The YouTube channel connection leg of the shared callback (youtube-routes.ts). */
export type YouTubeCallback = (
  c: Parameters<MiddlewareHandler<AppEnv>>[0],
  state: Extract<OAuthState, { purpose: 'youtube' }>,
) => Promise<Response>;

/**
 * Signs in a Google-verified identity: stores the person and accepts every live invite bound
 * to its email, plus `invite` when it is a live team invite this person may accept. An admin
 * sign-in stores nothing for an account that is not an admin.
 */
async function admit(
  c: Parameters<MiddlewareHandler<AppEnv>>[0],
  identity: GoogleIdentity,
  invite: string | null,
  admin: boolean,
): Promise<Person | null> {
  if (!identity.emailVerified) return null;
  const dir = c.var.directory;
  const email = normalizeEmail(identity.email);
  if (admin && !isAdmin(c.env, email)) return null;
  const code = invite ? normalizeTeamInviteCode(invite) : null;
  const [emailInvites, linkRow] = await Promise.all([
    dir.emailInvites(email),
    code ? dir.liveInviteByHash(routeCodeHash(c.env.SERVER_SECRET, 'team-invite', code)) : null,
  ]);
  const link = linkRow && (linkRow.email === null || linkRow.email === email) ? linkRow : null;
  const person = await dir.upsertPerson({ ...identity, email });
  const teams = new Set([...emailInvites, ...(link ? [link] : [])].map((row) => row.team_id));
  for (const teamId of teams) await dir.join(teamId, person.id);
  return person;
}

export function authRoutes(google: GoogleOAuth, admin?: AdminCallback, youtube?: YouTubeCallback) {
  const app = new Hono<AppEnv>();
  app.use('*', async (c, next) => (await limited(c, c.env.AUTH_LIMIT, 'auth')) ?? next());

  app.get('/google/start', (c) => {
    const challenge = c.req.query('challenge') ?? '';
    const invite = c.req.query('invite') ?? null;
    const purpose = c.req.query('purpose') ?? 'app';
    if (
      !CHALLENGE_PATTERN.test(challenge) ||
      (purpose !== 'app' && purpose !== 'admin') ||
      (invite !== null && invite.length > 32)
    )
      return invalid(c);
    const now = c.var.directory.now();
    const state = signState(c.env.SERVER_SECRET, {
      challenge,
      invite,
      purpose,
      exp: now + STATE_TTL_MS,
    });
    return c.redirect(
      google.authorizeUrl({
        state,
        scopes: SIGN_IN_SCOPES,
        redirectUri: callbackUrl(c.env),
        prompt: 'select_account',
      }),
      302,
    );
  });

  app.get('/google/callback', async (c) => {
    const verified = verifyState(
      c.env.SERVER_SECRET,
      c.req.query('state') ?? '',
      c.var.directory.now(),
    );
    // One registered redirect URI serves sign-in and channel connections.
    if (verified?.purpose === 'youtube')
      return youtube ? youtube(c, verified) : c.json({ error: 'invalid_request' }, 400);
    const state = verified;
    const toApp = (outcome: SignInOutcome, ticket?: string) => {
      const query = new URLSearchParams({ status: outcome.status });
      if (ticket) query.set('ticket', ticket);
      return c.redirect(`${c.env.APP_AUTH_REDIRECT}?${query}`, 302);
    };
    const finish = async (outcome: SignInOutcome) => {
      if (state?.purpose === 'admin' && admin) return admin(c, state, outcome);
      if (outcome.status !== 'ok' || !state) return toApp(outcome);
      return toApp(outcome, await c.var.directory.createTicket(outcome.person.id, state.challenge));
    };
    const error = c.req.query('error');
    if (error) return finish({ status: error === 'access_denied' ? 'cancelled' : 'error' });
    const code = c.req.query('code');
    if (!state || !code) return finish({ status: 'error' });
    let identity: GoogleIdentity;
    try {
      identity = (await google.exchange(code, callbackUrl(c.env))).identity;
    } catch (cause) {
      if (cause instanceof GoogleOAuthError) {
        console.warn('google_exchange_failed', cause.code);
        return finish({ status: 'error' });
      }
      throw cause;
    }
    const person = await admit(c, identity, state.invite, state.purpose === 'admin');
    return finish(person ? { status: 'ok', person } : { status: 'error' });
  });

  const redeem = z
    .object({
      ticket: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
      verifier: z.string().regex(VERIFIER_PATTERN),
      deviceName: z.string().trim().min(1).max(64).optional(),
    })
    .strict();
  app.post('/session', async (c) => {
    const input = await readJson(c, redeem);
    if (!input) return invalid(c);
    const dir = c.var.directory;
    const personId = await dir.redeemTicket(input.ticket, sha256Base64url(input.verifier));
    const person = personId ? await dir.person(personId) : null;
    if (!person) return c.json({ error: 'ticket_invalid' }, 401);
    const token = await dir.createSession(person.id, input.deviceName ?? null);
    return c.json({ token, person, serverTime: serverTime() });
  });

  app.delete('/session', async (c) => {
    const token = bearerToken(c);
    if (!(await c.var.directory.sessionPerson(token)))
      return c.json({ error: 'unauthorized' }, 401);
    await c.var.directory.revokeSession(token);
    return c.body(null, 204);
  });
  return app;
}

export function meRoutes() {
  const app = new Hono<PersonEnv>();
  app.get('/', requirePerson(), async (c) => {
    const person = c.var.person;
    const teams = await c.var.directory.teamsFor(person.id);
    return c.json({
      person,
      teams: teams.map(({ id, name, shortName, color, role }) => ({
        id,
        name,
        shortName,
        color,
        role,
      })),
      serverTime: serverTime(),
    });
  });
  return app;
}
