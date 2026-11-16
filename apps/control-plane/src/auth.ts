import type { Context } from 'hono';
import { createMiddleware } from 'hono/factory';
import { timingSafeEqual } from 'node:crypto';
import type { AccountStore } from './account-store.js';

/** Bearer-token middleware. Constant-time compare against the configured token. */
export function bearer(expectedToken: string, role: string) {
  const expected = Buffer.from(expectedToken);
  return createMiddleware(async (c, next) => {
    const header = c.req.header('authorization') ?? '';
    const m = /^Bearer\s+(.+)$/i.exec(header);
    if (!m) {
      return c.json({ error: 'unauthorized', role }, 401);
    }
    const got = Buffer.from(m[1]!);
    if (got.length !== expected.length || !timingSafeEqual(got, expected)) {
      return c.json({ error: 'unauthorized', role }, 401);
    }
    return next();
  });
}

export function bearerToken(c: Context): string {
  return c.req.header('authorization')?.match(/^Bearer\s+(.+)$/i)?.[1] ?? '';
}

/** An enrolled owner phone. Setup links are the only way to become one. */
export type Owner = { kind: 'device'; deviceId: string };
export type OwnerEnv = { Variables: { owner: Owner } };

/** Owner identity for a bearer token: an enrolled, unrevoked device. */
export function resolveOwner(token: string, account: AccountStore): Owner | undefined {
  if (!token) return undefined;
  const device = account.authenticateDevice(token);
  return device ? { kind: 'device', deviceId: device.id } : undefined;
}

/** Owner-only routes. The 401 keeps the historical `installation` role label. */
export function ownerAuth(account: AccountStore) {
  return createMiddleware<OwnerEnv>(async (c, next) => {
    const owner = resolveOwner(bearerToken(c), account);
    if (!owner) return c.json({ error: 'unauthorized', role: 'installation' }, 401);
    c.set('owner', owner);
    await next();
  });
}

/** Client key for rate limits: the address Caddy appended, else one shared bucket. */
export function clientKey(c: Context): string {
  const forwarded = c.req.header('x-forwarded-for');
  return forwarded?.split(',').at(-1)?.trim() || 'direct';
}
