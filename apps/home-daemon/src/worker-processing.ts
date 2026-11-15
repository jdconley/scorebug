import type { DecodedFrameHistorySnapshot } from './decoded-frame-history.js';
import { encoderTime90k, type EncoderTimingSnapshot } from './encoder-timing.js';
export type WorkerProcessingSnapshot = Readonly<{
  decoded: DecodedFrameHistorySnapshot;
  encoded: EncoderTimingSnapshot;
}>;
export type ObservedDuration = Readonly<{ meanMs: number; maximumMs: number }>;
export type WorkerProcessingInterval = Readonly<{
  sourceStartExclusive: number;
  sourceEndInclusive: number;
  decodedFrames: number;
  submittedFrames: number;
  completedFrames: number;
  pendingFrames: number;
  omittedBeforeEncoderFrames: number;
  /** Exact cap-policy prediction, corroborated by encoder submissions; absent if unknown. */
  intentionalFrameCapOmissions?: number;
  /** Reader-observed after-decode to encoder submission. Not CPU execution cost. */
  filterDuration: ObservedDuration | null;
  /** Reader-observed after-decode to packet completion, excluding decode itself. */
  processingDuration: ObservedDuration | null;
}>;
/** Historical correlation only. Scope/freshness must also be bound to a live worker report. */
export function workerProcessingInterval(
  snapshot: WorkerProcessingSnapshot,
  start: number,
  end: number,
): WorkerProcessingInterval | null {
  const { decoded, encoded } = snapshot;
  if (
    decoded.scopeID !== encoded.scopeID ||
    decoded.invalidReason !== null ||
    encoded.invalidReason !== null ||
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    end <= start
  )
    return null;
  const first = decoded.frames.findIndex((frame) => frame.pts === start),
    last = decoded.frames.findIndex((frame) => frame.pts === end);
  if (first < 0 || last <= first) return null;
  const projected = encoded.frames.map((frame) => ({ frame, pts: encoderTime90k(frame) }));
  if (
    projected.some(
      (entry, i) => entry.pts === null || (i > 0 && entry.pts <= projected[i - 1]!.pts!),
    )
  )
    return null;
  let left = -1;
  for (let index = 0; index < projected.length && projected[index]!.pts! <= start; index++)
    left = index;
  const right = projected.findIndex((entry) => entry.pts! >= end);
  if (left < 0 || right <= left) return null;
  const sources = new Map(decoded.frames.map((frame) => [frame.pts, frame]));
  const bracket = projected.slice(left, right + 1);
  if (bracket.some((entry) => !sources.has(entry.pts!))) return null;
  const selected = bracket.filter((entry) => entry.pts! > start && entry.pts! <= end);
  const decodedFrames = last - first,
    submittedFrames = selected.length;
  if (submittedFrames > decodedFrames) return null;
  const completedFrames = selected.filter((entry) => entry.frame.completedAt !== null).length;
  const summarize = (values: (number | null)[]): ObservedDuration | null => {
    if (
      !values.length ||
      values.some((value) => value === null || !Number.isFinite(value) || value < 0)
    )
      return null;
    const known = values as number[];
    return {
      meanMs: known.reduce((sum, value) => sum + value, 0) / known.length,
      maximumMs: Math.max(...known),
    };
  };
  const intervalSources = decoded.frames.slice(first + 1, last + 1);
  // The predictor runs from pipeline start, including frames no longer retained.
  // Unknown policy or a contradictory actual submission disables attribution.
  // Predicted selected-but-missing frames remain unexpected omissions.
  const capKnown =
    intervalSources.every((frame) => typeof frame.selectedByFrameCap === 'boolean') &&
    bracket.every((entry) => sources.get(entry.pts!)!.selectedByFrameCap === true);
  const intentionalFrameCapOmissions = capKnown
    ? intervalSources.filter((frame) => frame.selectedByFrameCap === false).length
    : undefined;
  return {
    ...(intentionalFrameCapOmissions !== undefined ? { intentionalFrameCapOmissions } : {}),
    sourceStartExclusive: start,
    sourceEndInclusive: end,
    decodedFrames,
    submittedFrames,
    completedFrames,
    pendingFrames: submittedFrames - completedFrames,
    omittedBeforeEncoderFrames: decodedFrames - submittedFrames,
    filterDuration: summarize(
      selected.map((entry) => entry.frame.submittedAt - sources.get(entry.pts!)!.observedAt),
    ),
    processingDuration: summarize(
      selected.map((entry) =>
        entry.frame.completedAt === null
          ? null
          : entry.frame.completedAt - sources.get(entry.pts!)!.observedAt,
      ),
    ),
  };
}
