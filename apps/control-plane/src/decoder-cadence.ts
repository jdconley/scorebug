import { z } from 'zod';
import {
  DECODED_VIDEO_INVALID_REASONS,
  type DecoderCadenceSnapshot,
  type DecoderCadenceWindow,
} from '@scorebug/protocol';
import { canonical } from './canonical-json.js';
const count = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const age = z.number().nonnegative().max(Number.MAX_SAFE_INTEGER);
const pts = z.number().int().min(Number.MIN_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER);
const window = (duration: 1000 | 2000) =>
  z
    .object({
      sequence: count.min(1),
      durationMs: z.literal(duration),
      ageMs: age,
      firstPTS: pts.nullable(),
      lastPTS: pts.nullable(),
      freshFrames: count,
      duplicateFrames: count,
      reorderedFrames: count,
      valid: z.boolean(),
    })
    .strict()
    .refine((w) => {
      if (
        !Number.isSafeInteger(w.sequence * duration) ||
        !Number.isSafeInteger(w.freshFrames + w.duplicateFrames + w.reorderedFrames)
      )
        return false;
      if (w.freshFrames === 0) return w.firstPTS === null && w.lastPTS === null;
      if (w.firstPTS === null || w.lastPTS === null) return false;
      return w.freshFrames === 1 ? w.firstPTS === w.lastPTS : w.firstPTS < w.lastPTS;
    });
export const decoderCadenceSchema = z
  .object({
    formatVersion: z.literal(1),
    scopeID: z.string().regex(/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/),
    oneSecond: window(1000).nullable(),
    twoSeconds: window(2000).nullable(),
    progress: z.object({ lastFreshPTS: pts, ageMs: age, stalled: z.boolean() }).strict().nullable(),
    invalidReason: z.enum(DECODED_VIDEO_INVALID_REASONS).nullable(),
    ended: z.boolean(),
  })
  .strict()
  .refine((c) => {
    const windows = [c.oneSecond, c.twoSeconds].filter((w) => w !== null);
    if (windows.length && !c.progress) return false;
    if (
      windows.some(
        (w) =>
          w.valid !== (c.invalidReason === null) ||
          (w.lastPTS !== null && c.progress!.lastFreshPTS < w.lastPTS),
      )
    )
      return false;
    if (
      c.progress &&
      c.progress.stalled !== (!c.ended && c.invalidReason === null && c.progress.ageMs >= 1000)
    )
      return false;
    if (c.twoSeconds && !c.oneSecond) return false;
    if (c.oneSecond && c.twoSeconds) {
      if (
        ![c.twoSeconds.sequence * 2, c.twoSeconds.sequence * 2 + 1].includes(c.oneSecond.sequence)
      )
        return false;
      const one = c.oneSecond.sequence * 1000 + c.oneSecond.ageMs,
        two = c.twoSeconds.sequence * 2000 + c.twoSeconds.ageMs;
      if (!Number.isFinite(one) || !Number.isFinite(two) || Math.abs(one - two) > 0.001)
        return false;
    } else if (c.oneSecond && c.oneSecond.sequence !== 1) return false;
    return true;
  });
export type CadenceHistory = {
  snapshot: DecoderCadenceSnapshot;
  lastOnePTS?: number;
  lastTwoPTS?: number;
};
/** Retain anti-replay state across optional omission; callers decide current visibility. */
export function advanceCadence(
  previous: CadenceHistory | undefined,
  next: DecoderCadenceSnapshot | undefined,
): CadenceHistory | undefined {
  if (!next) return previous;
  if (!decoderCadenceSchema.safeParse(next).success) throw new Error('invalid_cadence');
  const before = previous?.snapshot;
  if (before) {
    if (
      before.scopeID !== next.scopeID ||
      (before.ended && !next.ended) ||
      (before.invalidReason !== null && before.invalidReason !== next.invalidReason)
    )
      throw new Error('cadence_scope');
    if (
      before.progress &&
      (!next.progress ||
        next.progress.lastFreshPTS < before.progress.lastFreshPTS ||
        (next.progress.lastFreshPTS === before.progress.lastFreshPTS &&
          next.progress.ageMs < before.progress.ageMs))
    )
      throw new Error('cadence_progress');
  }
  const advance = (
    old: DecoderCadenceWindow | null | undefined,
    after: DecoderCadenceWindow | null,
    lastPTS: number | undefined,
  ) => {
    if (old) {
      if (!after || after.sequence < old.sequence) throw new Error('cadence_sequence');
      if (after.sequence === old.sequence) {
        const { ageMs: oldAge, valid: oldValid, ...oldValue } = old;
        const { ageMs: newAge, valid: newValid, ...newValue } = after;
        if (
          canonical(oldValue) !== canonical(newValue) ||
          newAge < oldAge ||
          (!oldValid && newValid)
        )
          throw new Error('cadence_content');
      } else if (after.firstPTS !== null && lastPTS !== undefined && after.firstPTS <= lastPTS)
        throw new Error('cadence_source');
    }
    return after?.lastPTS ?? lastPTS;
  };
  const one = advance(before?.oneSecond, next.oneSecond, previous?.lastOnePTS);
  const two = advance(before?.twoSeconds, next.twoSeconds, previous?.lastTwoPTS);
  return {
    snapshot: structuredClone(next),
    ...(one !== undefined ? { lastOnePTS: one } : {}),
    ...(two !== undefined ? { lastTwoPTS: two } : {}),
  };
}
