/** Sanitized process observations and decoder-ingress cadence; never viewer delivery. */
export const WORKER_STATES = [
  'idle',
  'waiting_source',
  'starting',
  'producing_output',
  'stopping',
  'retrying',
  'failed',
  'closed',
] as const;
export const WORKER_REASONS = [
  'assignment_changed',
  'source_unavailable',
  'output_mismatch',
  'control_unavailable',
  'control_timeout',
  'output_timeout',
  'process_exited',
  'score_write_failed',
  'start_failed',
  'retry_budget',
  'retry_delay',
  'shutdown',
] as const;
export const WORKER_OBSERVATION_TTL_MS = 5000;
/** Signed decoder PTS at 90 kHz, preserving the input timestamp origin.
 * Compare with MPEG-TS timestamps modulo 2^33. This identifies coordinates only;
 * it makes no claim about source loss, receipt time, or delivery. */
export const DECODED_VIDEO_TRANSPORT_CLOCK = 'mpegts-pts-90k-v1';
export const DECODED_VIDEO_INVALID_REASONS = [
  'framing',
  'numeric',
  'ordinal',
  'oversized',
  'incomplete',
  'callback',
  'clock',
  'overflow',
] as const;
export type DecodedVideoInvalidReason = (typeof DECODED_VIDEO_INVALID_REASONS)[number];
/** Worker decoder/filter ingress, before cap/overlay/output encoding. Not viewer delivery.
 * PTS are signed safe-integer ticks at a fixed timebase of 1/90000 seconds. */
export type DecodedVideoWindow = {
  sequence: number;
  durationMs: 5000;
  /** Lower-bound age; server adds receipt residence, excluding unmeasured report transit. */
  ageMs: number;
  firstPTS: number | null;
  lastPTS: number | null;
  freshFrames: number;
  duplicateFrames: number;
  reorderedFrames: number;
  valid: boolean;
};
export type DecodedVideoSnapshot = {
  /** Optional coordinate convention; absence does not prove transport-clock alignment. */
  clock?: string;
  completed: DecodedVideoWindow | null;
  invalidReason: DecodedVideoInvalidReason | null;
  ended: boolean;
};
export type WorkerState = (typeof WORKER_STATES)[number];
export type WorkerReason = (typeof WORKER_REASONS)[number];
export type WorkerObservation = {
  gameId: string;
  generation: number;
  state: WorkerState;
  reason: WorkerReason | null;
  attempt: number;
  frame: number | null;
  outTimeUs: number | null;
  scoreRevision: number | null;
  /** Omitted by legacy workers; absence is unknown, never healthy. */
  decodedVideo?: DecodedVideoSnapshot;
};
export type WorkerSessionRequest = { workerId: string; runId: string };
export type WorkerSessionResponse = {
  /** Clock convention accepted by this API session. */
  decodedVideoClock?: string;
  sessionId: string;
  serverTime: string;
  /** Opaque server monotonic timing provenance; echo with a later snapshot. */
  timingToken?: string;
};
export type WorkerObservationRequest = {
  workerId: string;
  sessionId: string;
  sequence: number;
  timingToken?: string;
  observation: WorkerObservation;
};
export type WorkerObservationResponse = {
  accepted: true;
  serverTime: string;
  timingToken?: string;
};
export type WorkerMediaStatus = {
  gameId: string;
  generation: number;
  workerId: string | null;
  state: 'not_requested' | 'unknown' | 'stale' | WorkerState;
  observation: WorkerObservation | null;
  /** Proven upper age including report transit and server residence, rounded up in ms.
   * Omitted when unavailable; server-owned, never supplied by the worker. */
  decodedVideoAgeUpperBoundMs?: number;
  observedAt: string | null;
  expiresAt: string | null;
};
export type WorkerMediaStatusResponse = { status: WorkerMediaStatus; serverTime: string };
