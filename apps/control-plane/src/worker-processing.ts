import { z } from 'zod';
import {
  DECODED_VIDEO_TRANSPORT_CLOCK,
  type WorkerObservation,
  type DecodedVideoSnapshot,
  type WorkerProcessingReport,
} from '@scorebug/protocol';
import { PUBLISHING_ATTEMPT_ID_PATTERN } from './publishing-attempt.js';
import { canonical } from './canonical-json.js';
const count = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const pts = z.number().int().min(Number.MIN_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER);
const duration = z
  .object({
    meanMs: z.number().nonnegative().max(Number.MAX_SAFE_INTEGER),
    maximumMs: z.number().nonnegative().max(Number.MAX_SAFE_INTEGER),
  })
  .strict()
  .refine((v) => v.meanMs <= v.maximumMs);
export const workerProcessingSchema = z
  .object({
    scopeID: z.string().length(36).regex(PUBLISHING_ATTEMPT_ID_PATTERN),
    encoder: z.enum(['software', 'videotoolbox', 'nvenc']),
    previousSequence: count.min(1),
    sequence: count.min(2),
    firstPTS: pts,
    interval: z
      .object({
        sourceStartExclusive: pts,
        sourceEndInclusive: pts,
        decodedFrames: count,
        submittedFrames: count,
        completedFrames: count,
        pendingFrames: count,
        omittedBeforeEncoderFrames: count,
        filterDuration: duration.nullable(),
        processingDuration: duration.nullable(),
      })
      .strict(),
  })
  .strict()
  .refine((p) => {
    const i = p.interval;
    return (
      p.previousSequence === p.sequence - 1 &&
      i.sourceStartExclusive < p.firstPTS &&
      p.firstPTS <= i.sourceEndInclusive &&
      i.submittedFrames <= i.decodedFrames &&
      i.completedFrames <= i.submittedFrames &&
      i.pendingFrames === i.submittedFrames - i.completedFrames &&
      i.omittedBeforeEncoderFrames === i.decodedFrames - i.submittedFrames &&
      (i.submittedFrames > 0 || (i.filterDuration === null && i.processingDuration === null)) &&
      (i.pendingFrames === 0 || i.processingDuration === null)
    );
  });
export function processingFitsObservation(observation: {
  state: WorkerObservation['state'];
  decodedVideo?: DecodedVideoSnapshot | undefined;
  processing?: WorkerProcessingReport | undefined;
}): boolean {
  const p = observation.processing;
  if (!p) return true;
  const v = observation.decodedVideo,
    w = v?.completed;
  return (
    observation.state === 'producing_output' &&
    v?.clock === DECODED_VIDEO_TRANSPORT_CLOCK &&
    !v.ended &&
    v.invalidReason === null &&
    w !== null &&
    w !== undefined &&
    w.valid &&
    w.freshFrames > 0 &&
    w.duplicateFrames === 0 &&
    w.reorderedFrames === 0 &&
    p.sequence === w.sequence &&
    p.firstPTS === w.firstPTS &&
    p.interval.sourceEndInclusive === w.lastPTS &&
    p.interval.decodedFrames === w.freshFrames
  );
}
/** Only completion can advance inside a fixed source interval; completed results are immutable. */
export function processingProgresses(
  before: WorkerProcessingReport,
  after: WorkerProcessingReport,
): boolean {
  if (
    before.scopeID !== after.scopeID ||
    before.encoder !== after.encoder ||
    after.sequence < before.sequence
  )
    return false;
  if (after.sequence > before.sequence) {
    return after.sequence === before.sequence + 1
      ? after.interval.sourceStartExclusive === before.interval.sourceEndInclusive
      : after.interval.sourceStartExclusive > before.interval.sourceEndInclusive;
  }
  if (before.interval.pendingFrames === 0) return canonical(before) === canonical(after);
  const stable = (p: WorkerProcessingReport) => ({
    ...p,
    interval: { ...p.interval, completedFrames: 0, pendingFrames: 0, processingDuration: null },
  });
  return (
    after.interval.completedFrames >= before.interval.completedFrames &&
    canonical(stable(before)) === canonical(stable(after))
  );
}
