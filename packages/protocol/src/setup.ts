import type { MatchCredential, MatchSnapshot } from './matches.js';

/**
 * Phone setup, match invites and streaming destinations. See docs/api.md.
 *
 * Link formats (query values are percent-encoded as usual for URLs):
 *   scorebug://connect?server=<https-url>&code=<setup-code>   one-time phone setup
 *   scorebug://join?server=<https-url>&code=<invite-code>     score a match
 */
export const SETUP_LINK_PREFIX = 'scorebug://connect';
export const JOIN_LINK_PREFIX = 'scorebug://join';

/** Owner devices can create matches, manage destinations, mint invites and run broadcasts. */
export type DeviceRole = 'owner';
export type Device = {
  id: string;
  name: string;
  role: DeviceRole;
  createdAt: string;
  lastSeenAt: string | null;
  revokedAt: string | null;
};
export type SetupLink = { code: string; link: string; expiresAt: string };
/** `deviceId` is a client-generated UUID; repeating the same request shortly after success returns the same token. */
export type SetupRedeemRequest = { code: string; deviceId: string; deviceName: string };
export type SetupRedeemed = { device: Device; token: string; serverTime: string };

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

/** The stream key is write-only: responses carry only its last four characters. */
export type Destination = {
  id: string;
  name: string;
  rtmpUrl: string;
  streamKeyLast4: string;
  isDefault: boolean;
  createdAt: string;
  updatedAt: string;
};
export type DestinationCreate = {
  name: string;
  rtmpUrl: string;
  streamKey: string;
  isDefault?: boolean | undefined;
};
export type DestinationUpdate = Partial<DestinationCreate>;

/**
 * Where a match's broadcast goes. `destinationId: null` without `recordOnly`
 * means the worker's own OUTPUT_URL (legacy/default).
 */
export type MatchOutput = { destinationId: string | null; recordOnly: boolean };

/**
 * Part of the worker snapshot assignment. `publishUrl` contains the stream key;
 * null means "use the worker's OUTPUT_URL".
 */
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

export function setupLink(server: string, code: string): string {
  return `${SETUP_LINK_PREFIX}?${query(server, code)}`;
}

export function joinLink(server: string, code: string): string {
  return `${JOIN_LINK_PREFIX}?${query(server, code)}`;
}
