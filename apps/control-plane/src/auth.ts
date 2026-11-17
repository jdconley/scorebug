import type { Context } from 'hono';
import { createMiddleware } from 'hono/factory';
import { timingSafeEqual } from 'node:crypto';

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

/** Client key for rate limits: the last X-Forwarded-For address, else one shared bucket. */
export function clientKey(c: Context): string {
  const forwarded = c.req.header('x-forwarded-for');
  return forwarded?.split(',').at(-1)?.trim() || 'direct';
}
