/** Worker process states, as the worker supervisor reports them. */
export const WORKER_STATES = [
  'idle',
  'starting',
  'producing_output',
  'stopping',
  'retrying',
  'failed',
  'closed',
] as const;
export const WORKER_REASONS = [
  'assignment_changed',
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
/** A report older than this is stale. */
export const WORKER_OBSERVATION_TTL_MS = 5000;
export type WorkerState = (typeof WORKER_STATES)[number];
export type WorkerReason = (typeof WORKER_REASONS)[number];
/** What the worker encodes for YouTube. */
export type WorkerOutput = { width: number; height: number; fps: number; bitrateKbps: number };
export type WorkerObservation = {
  gameId: string;
  generation: number;
  state: WorkerState;
  reason: WorkerReason | null;
  attempt: number;
  /** FFmpeg output counters for the current attempt. */
  frame: number | null;
  outTimeUs: number | null;
  scoreRevision: number | null;
  output?: WorkerOutput;
};
export type WorkerSessionRequest = { workerId: string; runId: string };
export type WorkerSessionResponse = { sessionId: string; serverTime: string };
export type WorkerObservationRequest = {
  workerId: string;
  sessionId: string;
  sequence: number;
  observation: WorkerObservation;
};
export type WorkerObservationResponse = { accepted: true; serverTime: string };

/** The broadcast status the app shows. */
export const WORKER_PHASES = ['idle', 'starting', 'live', 'reconnecting', 'error'] as const;
export type WorkerPhase = (typeof WORKER_PHASES)[number];
export type WorkerMediaStatus = {
  gameId: string;
  generation: number;
  workerId: string | null;
  phase: WorkerPhase;
  /** Output the worker last reported for this generation. */
  output: WorkerOutput | null;
  /** Detailed state; the iOS app decodes this one. */
  state: 'not_requested' | 'unknown' | 'stale' | WorkerState;
  observation: Omit<WorkerObservation, 'output'> | null;
  /** When the worker last reported. */
  observedAt: string | null;
  expiresAt: string | null;
};
export type WorkerMediaStatusResponse = { status: WorkerMediaStatus; serverTime: string };
