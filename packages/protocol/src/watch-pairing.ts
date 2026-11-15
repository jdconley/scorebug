import type { MatchCredential, MatchSnapshot } from './matches.js';

/** Installation-authorized issuance. Pairing and device IDs are UUIDs. */
export type WatchPairingIssueRequest = { pairingId: string; watchDeviceId: string };
/** Capability bearer auth plus X-Scorebug-Pairing-Recovery (32 random base64url bytes). */
export type WatchPairingRedeemRequest = { redemptionId: string; deviceId: string };
export type WatchPairingIssued = {
  pairingId: string;
  gameId: string;
  watchDeviceId: string;
  role: 'score';
  pairingToken: string;
  expiresAt: string;
  serverTime: string;
};
export type WatchPairingRedeemed = {
  pairingId: string;
  redemptionId: string;
  credential: MatchCredential;
  snapshot: MatchSnapshot;
  serverTime: string;
};
