import type { MatchCredential, MatchSnapshot } from './matches.js';

/**
 * Match invites and match outputs. See docs/api.md.
 *
 * Join link format (query values are percent-encoded as usual for URLs):
 *   scorebug://join?server=<https-url>&code=<invite-code>     score a match
 */
export const JOIN_LINK_PREFIX = 'scorebug://join';

export type MatchInvite = {
  id: string;
  gameId: string;
  createdAt: string;
  expiresAt: string;
  revokedAt: string | null;
  redemptions: number;
};
/** `code` is displayed grouped (`K7P-4QX`); redemption ignores case, spaces and dashes. */
export type MatchInviteIssued = {
  invite: MatchInvite;
  code: string;
  link: string;
  expiresAt: string;
};
export type InviteRedeemRequest = { code: string; deviceId: string };
/** Always a per-match `score` credential. */
export type InviteRedeemed = {
  credential: MatchCredential;
  snapshot: MatchSnapshot;
  serverTime: string;
};

/** `destinationId` is always null: matches stream to the team's YouTube channel. */
export type MatchOutput = { destinationId: string | null; recordOnly: boolean };

/** Part of the worker snapshot assignment. `publishUrl` is the YouTube ingest URL with its stream key. */
export type WorkerOutputAssignment = { destinationId: string | null; publishUrl: string | null };

/** Unambiguous invite alphabet: no 0/O, 1/I/L or U. */
export const INVITE_CODE_ALPHABET = '23456789ABCDEFGHJKMNPQRSTVWXYZ';
export const INVITE_CODE_LENGTH = 6;

/** Uppercase and drop separators; returns null unless exactly six alphabet characters remain. */
export function normalizeInviteCode(input: string): string | null {
  const code = input.toUpperCase().replace(/[\s-]/g, '');
  if (code.length !== INVITE_CODE_LENGTH) return null;
  for (const char of code) if (!INVITE_CODE_ALPHABET.includes(char)) return null;
  return code;
}

export function formatInviteCode(code: string): string {
  return `${code.slice(0, 3)}-${code.slice(3)}`;
}

const query = (server: string, code: string) =>
  `server=${encodeURIComponent(server)}&code=${encodeURIComponent(code)}`;

export function joinLink(server: string, code: string): string {
  return `${JOIN_LINK_PREFIX}?${query(server, code)}`;
}
