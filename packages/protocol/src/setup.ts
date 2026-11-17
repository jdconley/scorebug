/** Match invites and match outputs. See docs/api.md. */
export type MatchInvite = {
  id: string;
  gameId: string;
  createdAt: string;
  expiresAt: string;
  revokedAt: string | null;
  redemptions: number;
};
export type InviteRedeemRequest = { code: string; deviceId: string };

/** A match streams to its team's YouTube channel unless it only records. */
export type MatchOutput = { recordOnly: boolean };

/** Part of the worker snapshot assignment: the YouTube RTMPS ingest URL with its stream key. */
export type WorkerOutputAssignment = { publishUrl: string };

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
