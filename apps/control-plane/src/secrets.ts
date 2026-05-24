import { randomBytes, randomUUID } from 'node:crypto';

/** 32 random bytes, base64url-encoded, no padding. */
export function newSecret(): string {
  return randomBytes(32).toString('base64url');
}

export function newGameId(): string {
  return randomUUID();
}

/**
 * MediaMTX SRT stream IDs.
 *
 * - publish: `publish:game_<uuid>:<publishSecret>`
 * - read:    `read:game_<uuid>` (read secret enforced by SRT passphrase, not streamId)
 */
export function publishStreamId(gameId: string, publishSecret: string): string {
  return `publish:game_${gameId}:${publishSecret}`;
}

export function readStreamId(gameId: string): string {
  return `read:game_${gameId}`;
}
