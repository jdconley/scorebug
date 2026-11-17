import { Hono, type Context } from 'hono';
import { z } from 'zod';
import { formatInviteCode, type MatchCredential } from '@scorebug/protocol';
import { bearerToken, clientKey } from '../auth.js';
import { MatchStoreError, type MatchStore } from '../matches-store.js';
import type { RedeemGuard } from '../rate-limit.js';
import type { MatchAccess } from './matches.js';

const now = () => new Date().toISOString();
const deviceId = z
  .string()
  .min(1)
  .max(128)
  .regex(/^[A-Za-z0-9_-]+$/);

/** Parse an optional JSON body without echoing its contents back. */
async function body<T>(c: Context, schema: z.ZodType<T>, optional = false): Promise<T | null> {
  let raw: unknown;
  try {
    const text = await c.req.text();
    raw = text.trim() === '' && optional ? {} : JSON.parse(text);
  } catch {
    return null;
  }
  const parsed = schema.safeParse(raw);
  return parsed.success ? parsed.data : null;
}
const invalid = (c: Context) => c.json({ error: 'invalid_request' }, 400);

const statusFor: Record<string, 400 | 401 | 404 | 409 | 410> = {
  device_id_taken: 409,
  invalid_ttl: 400,
  invite_invalid: 401,
  invite_revoked: 410,
  invite_expired: 410,
  invite_not_found: 404,
  invite_limit: 409,
  match_ended: 410,
  match_not_found: 404,
};
function storeError(error: Error, c: Context) {
  if (error instanceof MatchStoreError)
    return c.json({ error: error.code }, statusFor[error.code] ?? 409);
  throw error;
}
function rateLimited(c: Context, guard: RedeemGuard): Response | undefined {
  const wait = guard.admit(clientKey(c));
  if (!wait) return undefined;
  c.header('Retry-After', String(wait));
  return c.json({ error: 'rate_limited' }, 429);
}
/** Redeem failures that mean "wrong code" count toward the global brute-force limit. */
const guessFailures = new Set(['invite_invalid', 'invite_revoked', 'invite_expired']);

type InviteEnv = { Variables: { issuer: string } };

/** Mounted at /v1/matches/:id/invites. Team members (see MatchAccess) or the match's
 * capture device. */
export function inviteRoutes(store: MatchStore, access: MatchAccess) {
  const app = new Hono<InviteEnv>();
  app.use('*', async (c, next) => {
    const token = bearerToken(c);
    const gameId = c.req.param('id') ?? '';
    let issuer = access.issuer(c);
    if (!issuer) {
      const credential: Omit<MatchCredential, 'token'> | undefined = store.authenticate(
        gameId,
        token,
      );
      if (credential?.role === 'capture') issuer = `capture:${credential.deviceId}`;
      else if (credential) return c.json({ error: 'forbidden' }, 403);
    }
    if (!issuer) return c.json({ error: 'unauthorized' }, 401);
    c.set('issuer', issuer);
    await next();
  });
  app.post('/', async (c) => {
    const input = await body(
      c,
      z.object({ expiresInMinutes: z.number().int().min(1).max(1440).optional() }).strict(),
      true,
    );
    if (!input) return invalid(c);
    const { invite, code } = store.issueInvite(
      c.req.param('id')!,
      c.get('issuer'),
      input.expiresInMinutes === undefined ? undefined : input.expiresInMinutes * 60_000,
    );
    try {
      await access.onInvite?.issued({
        inviteId: invite.id,
        code,
        gameId: invite.gameId,
        expiresAt: invite.expiresAt,
      });
    } catch (error) {
      // A code nobody can route to must not linger or count toward the invite limit.
      store.revokeInvite(invite.gameId, invite.id);
      throw error;
    }
    return c.json(
      {
        invite,
        code: formatInviteCode(code),
        link: access.joinLink(code),
        expiresAt: invite.expiresAt,
      },
      201,
    );
  });
  app.get('/', (c) =>
    c.json({ invites: store.listInvites(c.req.param('id')!), serverTime: now() }),
  );
  app.delete('/:inviteId', async (c) => {
    const invite = store.revokeInvite(c.req.param('id')!, c.req.param('inviteId'));
    await access.onInvite?.revoked({ inviteId: invite.id, gameId: invite.gameId });
    return c.json({ invite, serverTime: now() });
  });
  app.onError(storeError);
  return app;
}

/** Mounted at /v1/invites. Unauthenticated: the code is the capability. */
export function inviteRedeemRoutes(store: MatchStore, guard: RedeemGuard) {
  const app = new Hono();
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    await next();
  });
  app.post('/redeem', async (c) => {
    const limited = rateLimited(c, guard);
    if (limited) return limited;
    const input = await body(c, z.object({ code: z.string().max(16), deviceId }).strict());
    if (!input) {
      guard.fail();
      return invalid(c);
    }
    try {
      return c.json({ ...store.redeemInvite(input), serverTime: now() });
    } catch (error) {
      if (error instanceof MatchStoreError && guessFailures.has(error.code)) guard.fail();
      throw error;
    }
  });
  app.onError(storeError);
  return app;
}
