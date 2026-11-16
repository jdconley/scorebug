import type { Context } from 'hono';
import type { z } from 'zod';
import type { Env } from './env.js';

/** Parse a JSON body without echoing it back. Empty bodies parse as `{}` when `optional`. */
export async function readJson<T>(
  c: Context,
  schema: z.ZodType<T>,
  optional = false,
): Promise<T | null> {
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

export const invalid = (c: Context) => c.json({ error: 'invalid_request' }, 400);
export const serverTime = () => new Date().toISOString();
export const bearerToken = (c: Context) =>
  c.req.header('authorization')?.match(/^Bearer\s+(\S+)$/i)?.[1] ?? '';

/** Cloudflare sets cf-connecting-ip and overwrites any client-sent value. */
export async function limited<E extends { Bindings: Env }>(
  c: Context<E>,
  limit: RateLimit,
  scope: string,
): Promise<Response | null> {
  const ip = c.req.header('cf-connecting-ip') ?? 'unknown';
  const { success } = await limit.limit({ key: `${scope}:${ip}` });
  if (success) return null;
  c.header('Retry-After', '60');
  return c.json({ error: 'rate_limited' }, 429);
}
