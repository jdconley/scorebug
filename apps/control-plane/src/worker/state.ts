import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { INVITE_CODE_ALPHABET } from '@scorebug/protocol';
import { canonical } from '../canonical-json.js';

/** Carried through Google's consent screen and back, HMAC-signed so it can't be edited. */
export type OAuthState = {
  /** base64url(SHA-256(verifier)): the app (or the admin browser) proves the verifier later. */
  challenge: string;
  invite: string | null;
  purpose: 'app' | 'admin';
  exp: number;
};
export const STATE_TTL_MS = 10 * 60 * 1000;
export const CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
export const VERIFIER_PATTERN = /^[A-Za-z0-9._~-]{43,128}$/;
export const TEAM_INVITE_CODE_LENGTH = 8;

const mac = (secret: string, payload: string) =>
  createHmac('sha256', secret)
    .update(canonical(['oauth-state', payload]))
    .digest('base64url');

export function signState(secret: string, s: OAuthState): string {
  const payload = Buffer.from(JSON.stringify(s)).toString('base64url');
  return `${payload}.${mac(secret, payload)}`;
}

export function verifyState(secret: string, raw: string, now: number): OAuthState | null {
  const [payload, signature, extra] = raw.split('.');
  if (!payload || !signature || extra !== undefined) return null;
  const expected = Buffer.from(mac(secret, payload));
  const given = Buffer.from(signature);
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;
  let value: unknown;
  try {
    value = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  const s = value as Partial<OAuthState>;
  if (
    typeof s.challenge !== 'string' ||
    !CHALLENGE_PATTERN.test(s.challenge) ||
    (s.invite !== null && typeof s.invite !== 'string') ||
    (s.purpose !== 'app' && s.purpose !== 'admin') ||
    typeof s.exp !== 'number' ||
    s.exp <= now
  )
    return null;
  return { challenge: s.challenge, invite: s.invite ?? null, purpose: s.purpose, exp: s.exp };
}

/** Keyed hash for short codes (team invites, match join codes), so a copied D1 can't reveal
 * them. Callers normalize the code first. */
export function routeCodeHash(secret: string, purpose: string, code: string): string {
  return createHmac('sha256', secret)
    .update(canonical([purpose, code]))
    .digest('hex');
}

/** Uppercase, drop spaces and dashes; null unless exactly 8 alphabet characters remain. */
export function normalizeTeamInviteCode(input: string): string | null {
  const code = input.toUpperCase().replace(/[\s-]/g, '');
  if (code.length !== TEAM_INVITE_CODE_LENGTH) return null;
  for (const char of code) if (!INVITE_CODE_ALPHABET.includes(char)) return null;
  return code;
}

export const sha256Hex = (value: string) => createHash('sha256').update(value).digest('hex');
export const sha256Base64url = (value: string) =>
  createHash('sha256').update(value).digest('base64url');
export const randomToken = () => randomBytes(32).toString('base64url');
export const normalizeEmail = (email: string) => email.trim().toLowerCase();
