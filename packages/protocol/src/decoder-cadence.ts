import type { DecodedVideoInvalidReason } from './worker-status.js';

export const WORKER_DECODER_CADENCE_PROTOCOL = 'decoder-cadence-v1';
type Counts = {
  firstPTS: number | null;
  lastPTS: number | null;
  freshFrames: number;
  duplicateFrames: number;
  reorderedFrames: number;
};
export type DecoderCadenceWindow = Counts & {
  sequence: number;
  durationMs: 1000 | 2000;
  ageMs: number;
  valid: boolean;
};
export type DecoderCadenceSnapshot = {
  formatVersion: 1;
  scopeID: string;
  oneSecond: DecoderCadenceWindow | null;
  twoSeconds: DecoderCadenceWindow | null;
  /** Decoder-arrival progress only; never source lateness or viewer delivery. */
  progress: { lastFreshPTS: number; ageMs: number; stalled: boolean } | null;
  invalidReason: DecodedVideoInvalidReason | null;
  ended: boolean;
};
