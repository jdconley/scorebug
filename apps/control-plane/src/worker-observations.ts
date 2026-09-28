import type { WorkerCapabilities, WorkerCapabilitiesResponse } from '@scorebug/protocol';
import {
  advanceDelivery,
  deliveryDelta,
  WORKER_DECODER_DELIVERY_PROTOCOL,
  type DecoderDeliveryPacket,
  type DecoderDeliveryCursor,
} from '@scorebug/protocol';
import { advanceCadence, type CadenceHistory } from './decoder-cadence.js';
import {
  processingFitsObservation,
  processingProgresses,
  workerProcessingSchema,
} from './worker-processing.js';
import { randomUUID } from 'node:crypto';
import {
  WORKER_OBSERVATION_TTL_MS,
  WORKER_SAMPLE_TIMING_PROTOCOL,
  type WorkerSampleTimingRequest,
  type WorkerSampleTimingResponse,
  WORKER_PROCESSING_PROTOCOL,
  WORKER_DECODER_CADENCE_PROTOCOL,
  type WorkerProcessingReport,
  WORKER_PIPELINE_READ_IDENTITY,
  DECODED_VIDEO_TRANSPORT_CLOCK,
  type DecodedVideoSnapshot,
  type WorkerMediaStatusResponse,
  type WorkerObservation,
  type WorkerObservationRequest,
  type WorkerObservationResponse,
  type WorkerSessionRequest,
  type WorkerSessionResponse,
} from '@scorebug/protocol';
import { PUBLISHING_ATTEMPT_ID_PATTERN } from './publishing-attempt.js';
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
export type WorkerReadScope = {
  workerId: string;
  gameId: string;
  generation: number;
  workerEpoch: string;
  attempt: number;
  pipelineReadId: string;
};
type Report = {
  // Preserve known identity across omission, but only current explicit reports resolve it.
  pipelineReadId?: string;
  activeReadId?: string;
  sequence: number;
  request: string;
  observation: WorkerObservation;
  counters: Counters;
  observedAt: number;
  receivedAt: number | undefined;
  decodedVideo?: DecodedVideoSnapshot;
  processing?: WorkerProcessingReport;
  processingAssignment?: { gameId: string; generation: number };
  lastDecodedPTS?: number;
  decodedAge?: { sequence: number; ageMs: number; at: number | undefined };
  decodedUpperAge?: UpperAge;
  delivery?: DecoderDeliveryPacket;
  deliveryAssignment?: { gameId: string; generation: number };
  deliverySampleAge?: { ageMs: number; at: number };
  cadence?: CadenceHistory;
  cadenceAssignment?: { gameId: string; generation: number };
  cadenceSampleAge?: { ageMs: number; at: number };
};
// An undefined age preserves overflow/contradiction evidence until this window is replaced.
type UpperAge = { sequence: number; ageMs: number | undefined; at: number };
type TimingToken = { readonly value: string; readonly issuedAt: number };
type Session = {
  capabilities?: WorkerCapabilities;
  capabilityHeartbeat?: number | undefined;
  runId: string;
  sessionId: string;
  workerEpoch: string;
  readIds: Set<string>;
  processingScopes: Set<string>;
  cadenceScopes: Set<string>;
  deliveryScopes: Set<string>;
  report?: Report;
  currentToken?: TimingToken;
  previousToken?: TimingToken;
  pendingSampleToken?: TimingToken;
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

  register({ workerId, runId, capabilities }: WorkerSessionRequest): WorkerSessionResponse {
    const sampled = this.sampleMonotonic();
    const worker = this.workers.get(workerId);
    if (worker?.retiredRuns.has(runId)) throw new WorkerObservationError('worker_session_retired');
    if (worker?.current.runId === runId)
      return {
        sessionId: worker.current.sessionId,
        sampleTiming: WORKER_SAMPLE_TIMING_PROTOCOL,
        decodedVideoClock: DECODED_VIDEO_TRANSPORT_CLOCK,
        pipelineReadIdentity: WORKER_PIPELINE_READ_IDENTITY,
        workerProcessing: WORKER_PROCESSING_PROTOCOL,
        decoderCadence: WORKER_DECODER_CADENCE_PROTOCOL,
        decoderDelivery: WORKER_DECODER_DELIVERY_PROTOCOL,
        ...this.timingResponse(worker.current),
        serverTime: new Date(this.now()).toISOString(),
      };
    const current: Session = {
      ...(capabilities
        ? { capabilities: structuredClone(capabilities), capabilityHeartbeat: sampled }
        : {}),
      runId,
      sessionId: randomUUID(),
      workerEpoch: randomUUID(),
      readIds: new Set(),
      processingScopes: new Set(),
      cadenceScopes: new Set(),
      deliveryScopes: new Set(),
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
      sampleTiming: WORKER_SAMPLE_TIMING_PROTOCOL,
      decodedVideoClock: DECODED_VIDEO_TRANSPORT_CLOCK,
      pipelineReadIdentity: WORKER_PIPELINE_READ_IDENTITY,
      workerProcessing: WORKER_PROCESSING_PROTOCOL,
      decoderCadence: WORKER_DECODER_CADENCE_PROTOCOL,
      decoderDelivery: WORKER_DECODER_DELIVERY_PROTOCOL,
      serverTime: new Date(this.now()).toISOString(),
      ...this.timingResponse(current),
    };
  }

  capabilities(workerId: string): WorkerCapabilitiesResponse {
    const now = this.sampleMonotonic(),
      session = this.workers.get(workerId)?.current;
    const capabilities = session?.capabilities;
    const fresh =
      capabilities !== undefined &&
      now !== undefined &&
      session?.capabilityHeartbeat !== undefined &&
      now - session.capabilityHeartbeat < WORKER_OBSERVATION_TTL_MS;
    return {
      workerId,
      state: capabilities ? (fresh ? 'fresh' : 'stale') : 'unknown',
      validForMs: fresh
        ? Math.max(
            0,
            Math.floor(WORKER_OBSERVATION_TTL_MS - (now! - session!.capabilityHeartbeat!)),
          )
        : 0,
      capabilities: capabilities ? structuredClone(capabilities) : null,
      serverTime: new Date(this.now()).toISOString(),
    };
  }

  sampleTiming({ workerId, sessionId }: WorkerSampleTimingRequest): WorkerSampleTimingResponse {
    const worker = this.workers.get(workerId);
    if (worker?.retiredSessions.has(sessionId))
      throw new WorkerObservationError('worker_session_retired');
    if (!worker || worker.current.sessionId !== sessionId)
      throw new WorkerObservationError('worker_session_unknown');
    const issuedAt = this.sampleMonotonic();
    worker.current.capabilityHeartbeat = issuedAt;
    // Independent bounded slot: never redate or evict the legacy token pair.
    delete worker.current.pendingSampleToken;
    if (issuedAt !== undefined)
      worker.current.pendingSampleToken = { value: randomUUID(), issuedAt };
    return {
      serverTime: new Date(this.now()).toISOString(),
      ...(worker.current.pendingSampleToken
        ? { timingToken: worker.current.pendingSampleToken.value }
        : {}),
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
    const pipelineReadId = body.pipelineReadId;
    if (
      pipelineReadId !== undefined &&
      (typeof pipelineReadId !== 'string' ||
        pipelineReadId.length !== 36 ||
        !PUBLISHING_ATTEMPT_ID_PATTERN.test(pipelineReadId))
    )
      throw new WorkerObservationError('observation_conflict');
    const sameReadAttempt = previous?.observation.attempt === observation.attempt;
    if (
      pipelineReadId !== undefined &&
      ((sameReadAttempt &&
        previous.pipelineReadId !== undefined &&
        previous.pipelineReadId !== pipelineReadId) ||
        (worker.current.readIds.has(pipelineReadId) &&
          (!sameReadAttempt || previous.pipelineReadId !== pipelineReadId)))
    )
      throw new WorkerObservationError('observation_conflict');
    const knownReadId = pipelineReadId ?? (sameReadAttempt ? previous.pipelineReadId : undefined);
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
    const beforeProcessing = sameAttempt ? previous?.processing : undefined;
    const beforeProcessingAssignment = sameAttempt ? previous?.processingAssignment : undefined;
    const processing = observation.processing;
    if (
      processing &&
      (!workerProcessingSchema.safeParse(processing).success ||
        !processingFitsObservation(observation) ||
        (beforeProcessingAssignment &&
          (beforeProcessingAssignment.gameId !== observation.gameId ||
            beforeProcessingAssignment.generation !== observation.generation)) ||
        (beforeProcessing && !processingProgresses(beforeProcessing, processing)) ||
        (worker.current.processingScopes.has(processing.scopeID) &&
          beforeProcessing?.scopeID !== processing.scopeID))
    )
      throw new WorkerObservationError('observation_conflict');
    const priorCadence = sameAttempt ? previous?.cadence : undefined;
    const cadenceAssignment = sameAttempt ? previous?.cadenceAssignment : undefined;
    let cadence: CadenceHistory | undefined;
    const nextCadence = observation.decoderCadence;
    try {
      if (
        nextCadence &&
        (!pipelineReadId ||
          observation.decodedVideo?.clock !== DECODED_VIDEO_TRANSPORT_CLOCK ||
          !['starting', 'producing_output'].includes(observation.state) ||
          observation.attempt <= 0 ||
          (cadenceAssignment &&
            (cadenceAssignment.gameId !== observation.gameId ||
              cadenceAssignment.generation !== observation.generation)) ||
          (worker.current.cadenceScopes.has(nextCadence.scopeID) &&
            priorCadence?.snapshot.scopeID !== nextCadence.scopeID) ||
          (observation.decodedVideo?.completed?.lastPTS != null &&
            (nextCadence.progress == null ||
              nextCadence.progress.lastFreshPTS < observation.decodedVideo.completed.lastPTS)))
      )
        throw new Error('cadence_scope');
      cadence = advanceCadence(priorCadence, nextCadence);
    } catch {
      throw new WorkerObservationError('observation_conflict');
    }
    const nextDelivery = observation.decoderDelivery;
    const priorDelivery = sameAttempt ? previous?.delivery : undefined;
    const deliveryAssignment = sameAttempt ? previous?.deliveryAssignment : undefined;
    let delivery: DecoderDeliveryPacket | undefined;
    try {
      if (
        nextDelivery &&
        (!pipelineReadId ||
          observation.decodedVideo?.clock !== DECODED_VIDEO_TRANSPORT_CLOCK ||
          !['starting', 'producing_output'].includes(observation.state) ||
          observation.attempt <= 0 ||
          (deliveryAssignment &&
            (deliveryAssignment.gameId !== observation.gameId ||
              deliveryAssignment.generation !== observation.generation)) ||
          (worker.current.deliveryScopes.has(nextDelivery.scopeID) &&
            priorDelivery?.scopeID !== nextDelivery.scopeID))
      )
        throw new Error('delivery_scope');
      delivery = advanceDelivery(priorDelivery, nextDelivery);
    } catch {
      throw new WorkerObservationError('observation_conflict');
    }
    const beforeVideo = sameAttempt ? previous?.decodedVideo : undefined;
    const afterVideo = observation.decodedVideo;
    let lastDecodedPTS = sameAttempt ? previous?.lastDecodedPTS : undefined;
    if (beforeVideo && afterVideo) {
      if (
        beforeVideo.clock !== afterVideo.clock ||
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
      body.timingToken === session.pendingSampleToken?.value && session.pendingSampleToken
        ? session.pendingSampleToken
        : body.timingToken === session.currentToken?.value
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
    const beforeCadence = priorCadence?.snapshot;
    const beforeCoordinate = beforeCadence?.oneSecond
      ? beforeCadence.oneSecond.sequence * 1000 + beforeCadence.oneSecond.ageMs
      : undefined;
    const nextCoordinate = nextCadence?.oneSecond
      ? nextCadence.oneSecond.sequence * 1000 + nextCadence.oneSecond.ageMs
      : undefined;
    if (
      nextCoordinate !== undefined &&
      (!Number.isFinite(nextCoordinate) ||
        nextCoordinate > Number.MAX_SAFE_INTEGER ||
        (beforeCoordinate !== undefined && nextCoordinate < beforeCoordinate))
    )
      throw new WorkerObservationError('observation_conflict');
    // Cadence has no explicit sampledAt field. Window age/sequence or fresh-PTS
    // progress/age must advance to establish a new sample coordinate. Flags alone
    // cannot make a cached snapshot fresh; retain history across optional omission.
    const sameCadenceSample =
      nextCadence &&
      beforeCadence &&
      (beforeCadence.oneSecond && nextCadence.oneSecond
        ? beforeCoordinate === nextCoordinate
        : beforeCadence.progress && nextCadence.progress
          ? beforeCadence.progress.lastFreshPTS === nextCadence.progress.lastFreshPTS &&
            beforeCadence.progress.ageMs === nextCadence.progress.ageMs
          : !beforeCadence.progress && !nextCadence.progress);
    const cadenceSampleAge =
      nextCadence && receivedAt !== undefined
        ? sameCadenceSample
          ? previous?.cadenceSampleAge
            ? upperAge(previous.cadenceSampleAge.ageMs, previous.cadenceSampleAge.at, receivedAt)
            : undefined
          : token
            ? upperAge(0, token.issuedAt, receivedAt)
            : undefined
        : undefined;
    const sameDeliverySample =
      nextDelivery && priorDelivery?.sampledAtMs === nextDelivery.sampledAtMs;
    // A token obtained after an already reported sample cannot date that sample.
    // Preserve its earlier proof, or leave it unknown across an unproven/omitted report.
    const deliverySampleAge =
      nextDelivery && receivedAt !== undefined
        ? sameDeliverySample
          ? previous?.deliverySampleAge
            ? upperAge(previous.deliverySampleAge.ageMs, previous.deliverySampleAge.at, receivedAt)
            : undefined
          : token
            ? upperAge(0, token.issuedAt, receivedAt)
            : undefined
        : undefined;
    const now = this.now();
    if (nextDelivery) worker.current.deliveryScopes.add(nextDelivery.scopeID);
    if (nextCadence) worker.current.cadenceScopes.add(nextCadence.scopeID);
    if (pipelineReadId !== undefined) worker.current.readIds.add(pipelineReadId);
    if (processing) worker.current.processingScopes.add(processing.scopeID);
    worker.current.report = {
      ...(knownReadId !== undefined ? { pipelineReadId: knownReadId } : {}),
      ...(pipelineReadId !== undefined ? { activeReadId: pipelineReadId } : {}),
      ...(cadence
        ? {
            cadence,
            cadenceAssignment: cadenceAssignment ?? {
              gameId: observation.gameId,
              generation: observation.generation,
            },
          }
        : {}),
      ...(cadenceSampleAge !== undefined && receivedAt !== undefined
        ? { cadenceSampleAge: { ageMs: cadenceSampleAge, at: receivedAt } }
        : {}),
      ...(delivery
        ? {
            delivery,
            deliveryAssignment: deliveryAssignment ?? {
              gameId: observation.gameId,
              generation: observation.generation,
            },
          }
        : {}),
      ...(deliverySampleAge !== undefined && receivedAt !== undefined
        ? { deliverySampleAge: { ageMs: deliverySampleAge, at: receivedAt } }
        : {}),
      sequence: body.sequence,
      request,
      observation: structuredClone(observation),
      counters,
      ...(processing || beforeProcessing
        ? {
            processing: structuredClone(processing ?? beforeProcessing!),
            processingAssignment: beforeProcessingAssignment ?? {
              gameId: observation.gameId,
              generation: observation.generation,
            },
          }
        : {}),
      observedAt: now,
      receivedAt,
      ...(afterVideo || beforeVideo
        ? { decodedVideo: structuredClone(afterVideo ?? beforeVideo!) }
        : {}),
      ...(lastDecodedPTS !== undefined ? { lastDecodedPTS } : {}),
      ...(decodedAge ? { decodedAge } : {}),
      ...(decodedUpperAge ? { decodedUpperAge } : {}),
    };
    // Consume only the exact pending challenge used by a successfully accepted new report.
    if (token && token === session.pendingSampleToken) delete session.pendingSampleToken;
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

  /** Internal correlation for a freshly obtained status; never part of public JSON. */
  readScope(response: WorkerMediaStatusResponse): WorkerReadScope | undefined {
    const status = response.status;
    if (
      !['starting', 'producing_output'].includes(status.state) ||
      !status.workerId ||
      !status.workerEpoch ||
      !status.observation
    )
      return undefined;
    const session = this.workers.get(status.workerId)?.current;
    const report = session?.report;
    if (
      !session ||
      !report?.activeReadId ||
      session.workerEpoch !== status.workerEpoch ||
      report.observation.gameId !== status.gameId ||
      report.observation.generation !== status.generation ||
      report.observation.attempt !== status.observation.attempt
    )
      return undefined;
    return {
      workerId: status.workerId,
      gameId: status.gameId,
      generation: status.generation,
      workerEpoch: session.workerEpoch,
      attempt: report.observation.attempt,
      pipelineReadId: report.activeReadId,
    };
  }

  status(
    gameId: string,
    deliveryRequest?: true | DecoderDeliveryCursor,
  ): WorkerMediaStatusResponse {
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
    const session = workerId ? this.workers.get(workerId)?.current : undefined;
    const report = session?.report;
    if (
      !session ||
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
    delete observation.decoderDelivery;
    let decoderDeliveryAgeUpperBoundMs: number | undefined;
    if (deliveryRequest && report.observation.decoderDelivery && report.delivery) {
      observation.decoderDelivery = deliveryDelta(
        report.delivery,
        deliveryRequest === true ? undefined : deliveryRequest,
      );
      if (sampled !== undefined && report.deliverySampleAge)
        decoderDeliveryAgeUpperBoundMs = upperAge(
          report.deliverySampleAge.ageMs,
          report.deliverySampleAge.at,
          sampled,
        );
    }
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
    const decoderCadenceAgeUpperBoundMs =
      observation.decoderCadence && report.cadenceSampleAge && sampled !== undefined
        ? upperAge(report.cadenceSampleAge.ageMs, report.cadenceSampleAge.at, sampled)
        : undefined;
    return {
      status: {
        ...base,
        ...(decoderCadenceAgeUpperBoundMs !== undefined ? { decoderCadenceAgeUpperBoundMs } : {}),
        ...(decoderDeliveryAgeUpperBoundMs !== undefined ? { decoderDeliveryAgeUpperBoundMs } : {}),
        workerEpoch: session.workerEpoch,
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
