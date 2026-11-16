import { Hono, type Context } from 'hono';
import { z } from 'zod';
import { setupLink, formatInviteCode, type MatchCredential } from '@scorebug/protocol';
import { AccountStoreError } from '../account-store.js';
import { bearerToken, clientKey, ownerAuth, type OwnerEnv } from '../auth.js';
import type { Config } from '../config.js';
import { MatchStoreError, type MatchStore } from '../matches-store.js';
import type { RedeemGuard } from '../rate-limit.js';
import type { MatchAccess } from './matches.js';

const now = () => new Date().toISOString();
const deviceId = z
  .string()
  .min(1)
  .max(128)
  .regex(/^[A-Za-z0-9_-]+$/);

/** Parse an optional JSON body without echoing its contents back (it may hold a stream key). */
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
/**
 * Links always use the configured PUBLIC_URL, never the request's Host header,
 * so a spoofed Host cannot point a shared link at another server.
 */
const publicUrlMissing = (c: Context) => c.json({ error: 'public_url_not_configured' }, 503);

const statusFor: Record<string, 400 | 401 | 404 | 409 | 410> = {
  setup_code_invalid: 401,
  setup_code_used: 409,
  setup_code_expired: 410,
  device_id_taken: 409,
  device_not_found: 404,
  destination_not_found: 404,
  destination_in_use: 409,
  destination_limit: 409,
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
  if (error instanceof AccountStoreError || error instanceof MatchStoreError)
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
const guessFailures = new Set([
  'setup_code_invalid',
  'setup_code_used',
  'setup_code_expired',
  'invite_invalid',
  'invite_revoked',
  'invite_expired',
]);

/** Mounted at /v1/setup. */
export function setupRoutes(config: Config, store: MatchStore, guard: RedeemGuard) {
  const app = new Hono<OwnerEnv>();
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    await next();
  });
  const redeem = z
    .object({
      code: z
        .string()
        .min(16)
        .max(64)
        .regex(/^[A-Za-z0-9_-]+$/),
      deviceId: z.uuid(),
      deviceName: z.string().trim().min(1).max(64).default('iPhone'),
    })
    .strict();
  app.post('/redeem', async (c) => {
    const limited = rateLimited(c, guard);
    if (limited) return limited;
    const input = await body(c, redeem);
    if (!input) {
      guard.fail();
      return invalid(c);
    }
    try {
      const { device, token } = store.account.redeemSetupCode(input);
      return c.json({ device, token, serverTime: now() });
    } catch (error) {
      if (error instanceof AccountStoreError && guessFailures.has(error.code)) guard.fail();
      throw error;
    }
  });
  // Another owner phone (or the CLI) can mint a setup link for a new phone.
  app.post('/links', ownerAuth(store.account), async (c) => {
    const input = await body(
      c,
      z.object({ expiresInHours: z.number().int().min(1).max(720).optional() }).strict(),
      true,
    );
    if (!input) return invalid(c);
    if (!config.PUBLIC_URL) return publicUrlMissing(c);
    const minted = store.account.mintSetupCode(
      input.expiresInHours === undefined ? undefined : input.expiresInHours * 3_600_000,
    );
    return c.json({ ...minted, link: setupLink(config.PUBLIC_URL, minted.code) }, 201);
  });
  app.onError(storeError);
  return app;
}

/** Mounted at /v1/devices. Owner only. */
export function deviceRoutes(config: Config, store: MatchStore) {
  const app = new Hono<OwnerEnv>();
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    await next();
  });
  app.use('*', ownerAuth(store.account));
  app.get('/', (c) => c.json({ devices: store.account.listDevices(), serverTime: now() }));
  app.get('/me', (c) => {
    const { deviceId } = c.get('owner');
    const device = store.account.listDevices().find((d) => d.id === deviceId) ?? null;
    return c.json({ role: 'owner', device, serverTime: now() });
  });
  app.delete('/:id', (c) =>
    c.json({ device: store.account.revokeDevice(c.req.param('id')), serverTime: now() }),
  );
  app.onError(storeError);
  return app;
}

export const rtmpUrlSchema = z
  .string()
  .max(1024)
  .refine((value) => {
    try {
      const url = new URL(value);
      return (
        ['rtmp:', 'rtmps:'].includes(url.protocol) &&
        !!url.hostname &&
        !url.username &&
        !url.password &&
        !url.search &&
        !url.hash &&
        !/[\s'"\\]/.test(value)
      );
    } catch {
      return false;
    }
  });
// Printable ASCII without spaces, quotes or backslashes; query strings (Facebook) are fine.
export const streamKeySchema = z
  .string()
  .min(1)
  .max(512)
  .regex(/^[\x21-\x7e]+$/)
  .refine((value) => !/['"\\]/.test(value));
const destinationName = z.string().trim().min(1).max(64);

/** Mounted at /v1/destinations. Owner only. Stream keys are write-only. */
export function destinationRoutes(config: Config, store: MatchStore) {
  const app = new Hono<OwnerEnv>();
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    await next();
  });
  app.use('*', ownerAuth(store.account));
  app.get('/', (c) =>
    c.json({ destinations: store.account.listDestinations(), serverTime: now() }),
  );
  app.post('/', async (c) => {
    const input = await body(
      c,
      z
        .object({
          name: destinationName,
          rtmpUrl: rtmpUrlSchema,
          streamKey: streamKeySchema,
          isDefault: z.boolean().optional(),
        })
        .strict(),
    );
    if (!input) return invalid(c);
    return c.json({ destination: store.account.createDestination(input), serverTime: now() }, 201);
  });
  app.get('/:id', (c) => {
    const destination = store.account.getDestination(c.req.param('id'));
    return destination
      ? c.json({ destination, serverTime: now() })
      : c.json({ error: 'destination_not_found' }, 404);
  });
  app.patch('/:id', async (c) => {
    const input = await body(
      c,
      z
        .object({
          name: destinationName.optional(),
          rtmpUrl: rtmpUrlSchema.optional(),
          streamKey: streamKeySchema.optional(),
          isDefault: z.boolean().optional(),
        })
        .strict()
        .refine((value) => Object.keys(value).length > 0),
    );
    if (!input) return invalid(c);
    const patch = Object.fromEntries(
      Object.entries(input).filter(([, value]) => value !== undefined),
    );
    return c.json({
      destination: store.account.updateDestination(c.req.param('id'), patch),
      serverTime: now(),
    });
  });
  app.delete('/:id', (c) => {
    store.account.deleteDestination(c.req.param('id'));
    return c.json({ deleted: true, serverTime: now() });
  });
  app.onError(storeError);
  return app;
}

type InviteEnv = { Variables: { issuer: string } };

/** Mounted at /v1/matches/:id/invites. Owner-level callers (see MatchAccess) or the match's
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
    if (access.joinLink('') === null) return publicUrlMissing(c);
    const { invite, code } = store.issueInvite(
      c.req.param('id')!,
      c.get('issuer'),
      input.expiresInMinutes === undefined ? undefined : input.expiresInMinutes * 60_000,
    );
    await access.onInvite?.issued({
      inviteId: invite.id,
      code,
      gameId: invite.gameId,
      expiresAt: invite.expiresAt,
    });
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
