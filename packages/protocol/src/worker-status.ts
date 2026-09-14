/** Sanitized worker process observations; these never assert viewer delivery or fresh frames. */
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
};
export type WorkerSessionRequest = { workerId: string; runId: string };
export type WorkerSessionResponse = { sessionId: string; serverTime: string };
export type WorkerObservationRequest = {
  workerId: string;
  sessionId: string;
  sequence: number;
  observation: WorkerObservation;
};
export type WorkerMediaStatus = {
  gameId: string;
  generation: number;
  workerId: string | null;
  state: 'not_requested' | 'unknown' | 'stale' | WorkerState;
  observation: WorkerObservation | null;
  observedAt: string | null;
  expiresAt: string | null;
};
export type WorkerMediaStatusResponse = { status: WorkerMediaStatus; serverTime: string };
