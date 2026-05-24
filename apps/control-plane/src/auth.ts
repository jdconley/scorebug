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

/**
 * Used for the MediaMTX `runOnReady` webhook and the home WS query-string token.
 * Returns true if the provided token matches; constant-time compare.
 */
export function tokensMatch(provided: string, expected: string): boolean {
  if (provided.length !== expected.length) return false;
  return timingSafeEqual(Buffer.from(provided), Buffer.from(expected));
}
