import { randomUUID } from 'node:crypto';
import {
  WORKER_OBSERVATION_TTL_MS,
  type WorkerMediaStatusResponse,
  type WorkerObservation,
  type WorkerObservationRequest,
  type WorkerSessionRequest,
  type WorkerSessionResponse,
} from '@scorebug/protocol';
import { canonical } from './canonical-json.js';
import type { MediaStore } from './media-store.js';

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
type Counters = Pick<WorkerObservation, 'frame' | 'outTimeUs' | 'scoreRevision'>;
type Report = {
  sequence: number;
  request: string;
  observation: WorkerObservation;
  counters: Counters;
  observedAt: number;
  receivedAt: number;
};
type Session = { runId: string; sessionId: string; report?: Report };
type Worker = { current: Session; retiredRuns: Set<string>; retiredSessions: Set<string> };

/** Process-local receipt state. Restart deliberately makes all observations unknown.
 * Retirement tombstones last for this API process lifetime: expiring them would resurrect old runs.
 */
export class WorkerObservations {
  private readonly workers = new Map<string, Worker>();
  constructor(
    private readonly media: MediaStore,
    private readonly now: () => number = Date.now,
    private readonly monotonic: () => number = () => performance.now(),
  ) {}

  register({ workerId, runId }: WorkerSessionRequest): WorkerSessionResponse {
    const worker = this.workers.get(workerId);
    if (worker?.retiredRuns.has(runId)) throw new WorkerObservationError('worker_session_retired');
    if (worker?.current.runId === runId)
      return {
        sessionId: worker.current.sessionId,
        serverTime: new Date(this.now()).toISOString(),
      };
    const current = { runId, sessionId: randomUUID() };
    if (worker) {
      worker.retiredRuns.add(worker.current.runId);
      worker.retiredSessions.add(worker.current.sessionId);
      worker.current = current;
    } else {
      this.workers.set(workerId, { current, retiredRuns: new Set(), retiredSessions: new Set() });
    }
    return { sessionId: current.sessionId, serverTime: new Date(this.now()).toISOString() };
  }

  report(body: WorkerObservationRequest): { accepted: true; serverTime: string } {
    const worker = this.workers.get(body.workerId);
    if (worker?.retiredSessions.has(body.sessionId))
      throw new WorkerObservationError('worker_session_retired');
    if (!worker || worker.current.sessionId !== body.sessionId)
      throw new WorkerObservationError('worker_session_unknown');
    const assignment = this.media.workerAssignment(body.workerId);
    const observation = body.observation;
    if (
      !assignment ||
      assignment.match.id !== observation.gameId ||
      assignment.media.broadcast.generation !== observation.generation
    )
      throw new WorkerObservationError('broadcast_changed');
    const request = canonical(body);
    const previous = worker.current.report;
    if (previous && body.sequence <= previous.sequence) {
      if (body.sequence !== previous.sequence || request !== previous.request)
        throw new WorkerObservationError('observation_conflict');
      return { accepted: true, serverTime: new Date(this.now()).toISOString() };
    }
    if (previous && observation.attempt < previous.observation.attempt)
      throw new WorkerObservationError('observation_conflict');
    const counters: Counters = {
      frame: observation.frame,
      outTimeUs: observation.outTimeUs,
      scoreRevision: observation.scoreRevision,
    };
    if (previous && observation.attempt === previous.observation.attempt) {
      for (const key of ['frame', 'outTimeUs', 'scoreRevision'] as const) {
        const before = previous.counters[key];
        const after = counters[key];
        if (before !== null && after !== null && after < before)
          throw new WorkerObservationError('observation_conflict');
        counters[key] = after ?? before;
      }
    }
    const now = this.now();
    worker.current.report = {
      sequence: body.sequence,
      request,
      observation: { ...observation },
      counters,
      observedAt: now,
      receivedAt: this.monotonic(),
    };
    return { accepted: true, serverTime: new Date(now).toISOString() };
  }

  status(gameId: string): WorkerMediaStatusResponse {
    const { broadcast } = this.media.get(gameId);
    const now = this.now();
    const workerId = broadcast.selection?.workerId ?? null;
    const base = {
      gameId,
      generation: broadcast.generation,
      workerId,
      observation: null,
      observedAt: null,
      expiresAt: null,
    };
    const serverTime = new Date(now).toISOString();
    if (broadcast.desired !== 'running')
      return { status: { ...base, state: 'not_requested' }, serverTime };
    const report = workerId ? this.workers.get(workerId)?.current.report : undefined;
    if (
      !report ||
      report.observation.gameId !== gameId ||
      report.observation.generation !== broadcast.generation
    )
      return { status: { ...base, state: 'unknown' }, serverTime };
    // Wall time describes receipt provenance; only monotonic elapsed time determines freshness.
    const remaining = WORKER_OBSERVATION_TTL_MS - (this.monotonic() - report.receivedAt);
    return {
      status: {
        ...base,
        state: remaining <= 0 ? 'stale' : report.observation.state,
        observation: { ...report.observation },
        observedAt: new Date(report.observedAt).toISOString(),
        // Translate remaining freshness into the current wall clock for remote clients.
        expiresAt: new Date(now + Math.max(0, remaining)).toISOString(),
      },
      serverTime,
    };
  }
}
