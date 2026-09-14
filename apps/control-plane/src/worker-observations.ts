import { randomUUID } from 'node:crypto';
import {
  WORKER_OBSERVATION_TTL_MS,
  type DecodedVideoSnapshot,
  type WorkerMediaStatusResponse,
  type WorkerObservation,
  type WorkerObservationRequest,
  type WorkerObservationResponse,
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
  receivedAt: number | undefined;
  decodedVideo?: DecodedVideoSnapshot;
  lastDecodedPTS?: number;
  decodedAge?: { sequence: number; ageMs: number; at: number | undefined };
  decodedUpperAge?: UpperAge;
};
// An undefined age preserves overflow/contradiction evidence until this window is replaced.
type UpperAge = { sequence: number; ageMs: number | undefined; at: number };
type TimingToken = { readonly value: string; readonly issuedAt: number };
type Session = {
  runId: string;
  sessionId: string;
  report?: Report;
  currentToken?: TimingToken;
  previousToken?: TimingToken;
};

function upperAge(ageMs: number, start: number, end: number): number | undefined {
  // Round checked endpoints outward BEFORE subtracting; subtracting a fractional
  // start from a large end can round elapsed down and disguise overflow.
  const age = Math.ceil(ageMs);
  const residence = start === end ? 0 : Math.ceil(end) - Math.floor(start);
  if (
    !Number.isSafeInteger(age) ||
    !Number.isSafeInteger(residence) ||
    age < 0 ||
    end < start ||
    residence < 0 ||
    age > Number.MAX_SAFE_INTEGER - residence
  )
    return undefined;
  return age + residence;
}

type Worker = { current: Session; retiredRuns: Set<string>; retiredSessions: Set<string> };

/** Process-local receipt state. Restart deliberately makes all observations unknown.
 * Retirement tombstones last for this API process lifetime: expiring them would resurrect old runs.
 */
export class WorkerObservations {
  private readonly workers = new Map<string, Worker>();
  private lastMonotonic: number | undefined;
  private timingUnavailable = false;
  constructor(
    private readonly media: MediaStore,
    private readonly now: () => number = Date.now,
    private readonly monotonic: () => number = () => performance.now(),
  ) {}

  /** Once a clock loses monotonic provenance it cannot prove timing again in this process. */
  private sampleMonotonic(): number | undefined {
    if (this.timingUnavailable) return undefined;
    try {
      const sampled = this.monotonic();
      if (
        Number.isFinite(sampled) &&
        sampled >= 0 &&
        sampled <= Number.MAX_SAFE_INTEGER &&
        (this.lastMonotonic === undefined || sampled >= this.lastMonotonic)
      ) {
        this.lastMonotonic = sampled;
        return sampled;
      }
    } catch {
      // Diagnostic clock failure must not reject worker control traffic.
    }
    this.timingUnavailable = true;
    return undefined;
  }

  private timingResponse(session: Session): { timingToken?: string } {
    return !this.timingUnavailable && session.currentToken
      ? { timingToken: session.currentToken.value }
      : {};
  }

  register({ workerId, runId }: WorkerSessionRequest): WorkerSessionResponse {
    const sampled = this.sampleMonotonic();
    const worker = this.workers.get(workerId);
    if (worker?.retiredRuns.has(runId)) throw new WorkerObservationError('worker_session_retired');
    if (worker?.current.runId === runId)
      return {
        sessionId: worker.current.sessionId,
        ...this.timingResponse(worker.current),
        serverTime: new Date(this.now()).toISOString(),
      };
    const current: Session = {
      runId,
      sessionId: randomUUID(),
      ...(sampled !== undefined
        ? { currentToken: { value: randomUUID(), issuedAt: sampled } }
        : {}),
    };
    if (worker) {
      worker.retiredRuns.add(worker.current.runId);
      worker.retiredSessions.add(worker.current.sessionId);
      worker.current = current;
    } else {
      this.workers.set(workerId, { current, retiredRuns: new Set(), retiredSessions: new Set() });
    }
    return {
      sessionId: current.sessionId,
      serverTime: new Date(this.now()).toISOString(),
      ...this.timingResponse(current),
    };
  }

  report(body: WorkerObservationRequest): WorkerObservationResponse {
    const receivedAt = this.sampleMonotonic();
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
      return {
        accepted: true,
        serverTime: new Date(this.now()).toISOString(),
        ...this.timingResponse(worker.current),
      };
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
    const sameAttempt = previous?.observation.attempt === observation.attempt;
    const sameAgeScope =
      sameAttempt &&
      previous?.observation.gameId === observation.gameId &&
      previous.observation.generation === observation.generation;
    const beforeVideo = sameAttempt ? previous?.decodedVideo : undefined;
    const afterVideo = observation.decodedVideo;
    let lastDecodedPTS = sameAttempt ? previous?.lastDecodedPTS : undefined;
    if (beforeVideo && afterVideo) {
      if (
        (beforeVideo.ended && !afterVideo.ended) ||
        (beforeVideo.invalidReason !== null &&
          beforeVideo.invalidReason !== afterVideo.invalidReason)
      )
        throw new WorkerObservationError('observation_conflict');
      const before = beforeVideo.completed,
        after = afterVideo.completed;
      if (before) {
        if (!after || after.sequence < before.sequence)
          throw new WorkerObservationError('observation_conflict');
        if (after.sequence === before.sequence) {
          const { ageMs: beforeAge, valid: beforeValid, ...beforeContent } = before;
          const { ageMs: afterAge, valid: afterValid, ...afterContent } = after;
          if (
            canonical(beforeContent) !== canonical(afterContent) ||
            afterAge < beforeAge ||
            (!beforeValid && afterValid)
          )
            throw new WorkerObservationError('observation_conflict');
        } else if (
          after.firstPTS !== null &&
          lastDecodedPTS !== undefined &&
          after.firstPTS <= lastDecodedPTS
        ) {
          throw new WorkerObservationError('observation_conflict');
        }
      }
    }
    if (afterVideo?.completed?.lastPTS !== null && afterVideo?.completed?.lastPTS !== undefined)
      lastDecodedPTS = afterVideo.completed.lastPTS;
    let decodedAge = sameAttempt ? previous?.decodedAge : undefined;
    if (afterVideo?.completed) {
      const window = afterVideo.completed;
      const knownAge =
        decodedAge?.sequence === window.sequence
          ? decodedAge.ageMs +
            (receivedAt !== undefined && decodedAge.at !== undefined
              ? receivedAt - decodedAge.at
              : 0)
          : 0;
      decodedAge = {
        sequence: window.sequence,
        ageMs: Math.min(Number.MAX_SAFE_INTEGER, Math.max(window.ageMs, knownAge)),
        at: receivedAt,
      };
    }
    const session = worker.current;
    const token =
      body.timingToken === session.currentToken?.value
        ? session.currentToken
        : body.timingToken === session.previousToken?.value
          ? session.previousToken
          : undefined;
    let decodedUpperAge = sameAgeScope ? previous?.decodedUpperAge : undefined;
    if (afterVideo?.completed) {
      const window = afterVideo.completed;
      if (decodedUpperAge?.sequence !== window.sequence) decodedUpperAge = undefined;
      if (receivedAt !== undefined) {
        const prior = decodedUpperAge;
        const priorAge = prior ? upperAge(prior.ageMs ?? NaN, prior.at, receivedAt) : undefined;
        // Issuance <= worker snapshot <= receipt. Only a recognized echoed token proves transit.
        const candidate = token ? upperAge(window.ageMs, token.issuedAt, receivedAt) : undefined;
        if (prior || token) {
          const lowerAge = decodedAge?.ageMs ?? window.ageMs;
          // Check each proof before merging: taking the larger bound could hide a
          // contradiction in either the prior evidence or the newly echoed sample.
          const unavailable =
            (prior && (priorAge === undefined || priorAge < lowerAge)) ||
            (token && (candidate === undefined || candidate < lowerAge));
          decodedUpperAge = {
            sequence: window.sequence,
            ageMs: unavailable ? undefined : Math.max(priorAge ?? 0, candidate ?? 0),
            at: receivedAt,
          };
        }
      }
    }
    const now = this.now();
    worker.current.report = {
      sequence: body.sequence,
      request,
      observation: structuredClone(observation),
      counters,
      observedAt: now,
      receivedAt,
      ...(afterVideo || beforeVideo
        ? { decodedVideo: structuredClone(afterVideo ?? beforeVideo!) }
        : {}),
      ...(lastDecodedPTS !== undefined ? { lastDecodedPTS } : {}),
      ...(decodedAge ? { decodedAge } : {}),
      ...(decodedUpperAge ? { decodedUpperAge } : {}),
    };
    // Rotate only after all acceptance checks and age calculations; previous remains immutable.
    if (receivedAt !== undefined && token && token === session.currentToken) {
      session.previousToken = token;
      session.currentToken = { value: randomUUID(), issuedAt: receivedAt };
    }
    return {
      accepted: true,
      serverTime: new Date(now).toISOString(),
      ...this.timingResponse(session),
    };
  }

  status(gameId: string): WorkerMediaStatusResponse {
    const sampled = this.sampleMonotonic();
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
    const remaining =
      sampled !== undefined && report.receivedAt !== undefined
        ? WORKER_OBSERVATION_TTL_MS - (sampled - report.receivedAt)
        : 0;
    const observation = structuredClone(report.observation);
    let decodedVideoAgeUpperBoundMs: number | undefined;
    if (observation.decodedVideo?.completed) {
      const completed = observation.decodedVideo.completed;
      const known = report.decodedAge;
      completed.ageMs = Math.min(
        Number.MAX_SAFE_INTEGER,
        Math.max(
          completed.ageMs,
          known?.sequence === completed.sequence
            ? known.ageMs +
                (sampled !== undefined && known.at !== undefined ? sampled - known.at : 0)
            : completed.ageMs,
        ),
      );
      const upper = report.decodedUpperAge;
      if (sampled !== undefined && upper?.sequence === completed.sequence)
        decodedVideoAgeUpperBoundMs = upperAge(upper.ageMs ?? NaN, upper.at, sampled);
    }
    return {
      status: {
        ...base,
        state: remaining <= 0 ? 'stale' : report.observation.state,
        observation,
        ...(decodedVideoAgeUpperBoundMs !== undefined ? { decodedVideoAgeUpperBoundMs } : {}),
        observedAt: new Date(report.observedAt).toISOString(),
        // Translate remaining freshness into the current wall clock for remote clients.
        expiresAt: new Date(now + Math.max(0, remaining)).toISOString(),
      },
      serverTime,
    };
  }
}
