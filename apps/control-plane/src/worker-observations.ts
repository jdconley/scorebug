import { randomUUID } from 'node:crypto';
import {
  WORKER_OBSERVATION_TTL_MS,
  type WorkerMediaStatus,
  type WorkerMediaStatusResponse,
  type WorkerObservation,
  type WorkerObservationRequest,
  type WorkerObservationResponse,
  type WorkerPhase,
  type WorkerSessionRequest,
  type WorkerSessionResponse,
} from '@scorebug/protocol';
import { canonical } from './canonical-json.js';
import type { MediaStore } from './media-store.js';
import { MediaStateError } from './media-state.js';

export class WorkerObservationError extends Error {
  constructor(
    readonly code:
      | 'worker_session_unknown'
      | 'worker_session_retired'
      | 'broadcast_changed'
      | 'observation_conflict',
  ) {
    super(code);
  }
}

type Report = {
  sequence: number;
  request: string;
  observation: WorkerObservation;
  /** Counter high-water marks for this attempt; a null report does not reset them. */
  counters: Counters;
  /** Monotonic receipt time; freshness never depends on wall clocks. */
  receivedAt: number;
  observedAt: number;
  /** This generation produced output at least once, so a later gap is a reconnect. */
  wasLive: boolean;
};
type Counters = Pick<WorkerObservation, 'frame' | 'outTimeUs' | 'scoreRevision'>;
type Session = { runId: string; sessionId: string; report?: Report };
type Worker = {
  current: Session;
  retiredRuns: Set<string>;
  retiredSessions: Set<string>;
  outputId?: string;
};

function phaseOf(state: WorkerMediaStatus['state'], wasLive: boolean): WorkerPhase {
  switch (state) {
    case 'not_requested':
      return 'idle';
    case 'producing_output':
      return 'live';
    case 'unknown':
    case 'idle':
    case 'starting':
      return 'starting';
    case 'waiting_source':
      return wasLive ? 'reconnecting' : 'starting';
    case 'retrying':
    case 'stopping':
      return 'reconnecting';
    case 'stale':
    case 'failed':
    case 'closed':
      return 'error';
  }
}

/** Latest worker report per worker, in process memory. An API restart makes status unknown
 * until the worker reports again (within one report interval). */
export class WorkerObservations {
  private readonly workers = new Map<string, Worker>();
  constructor(
    private readonly media: MediaStore,
    private readonly now: () => number = Date.now,
    private readonly monotonic: () => number = () => performance.now(),
  ) {}

  register({ workerId, runId, outputId }: WorkerSessionRequest): WorkerSessionResponse {
    const worker = this.workers.get(workerId);
    if (worker?.retiredRuns.has(runId)) throw new WorkerObservationError('worker_session_retired');
    if (worker && outputId !== undefined) worker.outputId = outputId;
    const serverTime = new Date(this.now()).toISOString();
    if (worker?.current.runId === runId) return { sessionId: worker.current.sessionId, serverTime };
    const current: Session = { runId, sessionId: randomUUID() };
    if (worker) {
      // A restarted worker process replaces the old one; the old run can never report again.
      worker.retiredRuns.add(worker.current.runId);
      worker.retiredSessions.add(worker.current.sessionId);
      worker.current = current;
    } else {
      this.workers.set(workerId, {
        current,
        retiredRuns: new Set(),
        retiredSessions: new Set(),
        ...(outputId === undefined ? {} : { outputId }),
      });
    }
    return { sessionId: current.sessionId, serverTime };
  }

  /**
   * Fills a start selection that leaves out workerId or outputId from the configured
   * worker. The output is the one that worker registered, else the configured one.
   */
  selectWorker(
    requested: { workerId?: string | undefined; outputId?: string | undefined },
    configured: { workerId: string; outputId: string },
  ): { workerId: string; outputId: string } {
    const workerId = requested.workerId ?? configured.workerId;
    const outputId =
      requested.outputId ??
      this.workers.get(workerId)?.outputId ??
      (configured.workerId === workerId ? configured.outputId : undefined);
    if (outputId === undefined) throw new MediaStateError('output_unknown');
    return { workerId, outputId };
  }

  report(body: WorkerObservationRequest): WorkerObservationResponse {
    const worker = this.workers.get(body.workerId);
    if (worker?.retiredSessions.has(body.sessionId))
      throw new WorkerObservationError('worker_session_retired');
    if (!worker || worker.current.sessionId !== body.sessionId)
      throw new WorkerObservationError('worker_session_unknown');
    const observation = body.observation;
    const assignment = this.media.workerAssignment(body.workerId);
    if (
      !assignment ||
      assignment.match.id !== observation.gameId ||
      assignment.media.broadcast.generation !== observation.generation
    )
      throw new WorkerObservationError('broadcast_changed');
    const request = canonical(body);
    const previous = worker.current.report;
    const serverTime = new Date(this.now()).toISOString();
    if (previous && body.sequence <= previous.sequence) {
      // An identical retry is idempotent; anything else is a stale or forked reporter.
      if (body.sequence !== previous.sequence || request !== previous.request)
        throw new WorkerObservationError('observation_conflict');
      return { accepted: true, serverTime };
    }
    const sameAttempt = previous?.observation.attempt === observation.attempt;
    if (previous && observation.attempt < previous.observation.attempt)
      throw new WorkerObservationError('observation_conflict');
    const counters: Counters = {
      frame: observation.frame,
      outTimeUs: observation.outTimeUs,
      scoreRevision: observation.scoreRevision,
    };
    if (sameAttempt)
      for (const key of ['frame', 'outTimeUs', 'scoreRevision'] as const) {
        const before = previous.counters[key],
          after = counters[key];
        if (before !== null && after !== null && after < before)
          throw new WorkerObservationError('observation_conflict');
        counters[key] = after ?? before;
      }
    const sameGeneration =
      previous?.observation.gameId === observation.gameId &&
      previous.observation.generation === observation.generation;
    worker.current.report = {
      sequence: body.sequence,
      request,
      observation: structuredClone(observation),
      counters,
      receivedAt: this.monotonic(),
      observedAt: this.now(),
      wasLive:
        observation.state === 'producing_output' || (sameGeneration && previous.wasLive === true),
    };
    return { accepted: true, serverTime };
  }

  status(gameId: string): WorkerMediaStatusResponse {
    const { broadcast } = this.media.get(gameId);
    const now = this.now();
    const serverTime = new Date(now).toISOString();
    const workerId = broadcast.selection?.workerId ?? null;
    const base = {
      gameId,
      generation: broadcast.generation,
      workerId,
      output: null,
      observation: null,
      observedAt: null,
      expiresAt: null,
    };
    if (broadcast.desired !== 'running')
      return { status: { ...base, phase: 'idle', state: 'not_requested' }, serverTime };
    const report = workerId ? this.workers.get(workerId)?.current.report : undefined;
    if (
      !report ||
      report.observation.gameId !== gameId ||
      report.observation.generation !== broadcast.generation
    )
      return { status: { ...base, phase: 'starting', state: 'unknown' }, serverTime };
    const remaining = WORKER_OBSERVATION_TTL_MS - (this.monotonic() - report.receivedAt);
    const { output, ...observation } = structuredClone(report.observation);
    const state = remaining <= 0 ? 'stale' : observation.state;
    return {
      status: {
        ...base,
        phase: phaseOf(state, report.wasLive),
        output: output ?? null,
        state,
        observation,
        observedAt: new Date(report.observedAt).toISOString(),
        // Translate remaining freshness into the current wall clock for remote clients.
        expiresAt: new Date(now + Math.max(0, remaining)).toISOString(),
      },
      serverTime,
    };
  }
}
