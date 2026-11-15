import { DECODER_DELIVERY_MAX_ARRIVALS, type DecoderDeliverySnapshot } from './decoder-delivery.js';
import { DECODED_VIDEO_INVALID_REASONS } from './worker-status.js';
export const WORKER_DECODER_DELIVERY_PROTOCOL = 'decoder-delivery-delta-v1';
export type DecoderDeliveryCursor = { scopeID: string; lastOrdinal: number };
/** Times are relative to this scope's monotonic origin, never a remote clock epoch.
 * Tuples are [90 kHz PTS, arrival time in milliseconds]. Ordinals are implicit. */
export type DecoderDeliveryPacket = {
  formatVersion: 1;
  scopeID: string;
  sampledAtMs: number;
  coverageAtMs: number;
  afterOrdinal: number;
  lastOrdinal: number;
  arrivals: [number, number][];
  invalidReason: string | null;
  ended: boolean;
};
const keys = [
  'formatVersion',
  'scopeID',
  'sampledAtMs',
  'coverageAtMs',
  'afterOrdinal',
  'lastOrdinal',
  'arrivals',
  'invalidReason',
  'ended',
];
const time = (v: unknown): v is number =>
  typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= Number.MAX_SAFE_INTEGER;
const count = (v: unknown): v is number => time(v) && Number.isSafeInteger(v);
export function deliveryPacketValid(value: unknown): value is DecoderDeliveryPacket {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const p = value as DecoderDeliveryPacket;
  if (
    Object.keys(p).length !== keys.length ||
    !keys.every((k) => Object.hasOwn(p, k)) ||
    p.formatVersion !== 1 ||
    typeof p.scopeID !== 'string' ||
    !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(p.scopeID) ||
    !time(p.sampledAtMs) ||
    !time(p.coverageAtMs) ||
    p.coverageAtMs > p.sampledAtMs ||
    !count(p.afterOrdinal) ||
    !count(p.lastOrdinal) ||
    p.afterOrdinal > p.lastOrdinal ||
    p.afterOrdinal < Math.max(0, p.lastOrdinal - DECODER_DELIVERY_MAX_ARRIVALS) ||
    !Array.isArray(p.arrivals) ||
    p.arrivals.length !== p.lastOrdinal - p.afterOrdinal ||
    (p.lastOrdinal <= DECODER_DELIVERY_MAX_ARRIVALS && p.coverageAtMs !== 0) ||
    !(
      p.invalidReason === null ||
      (DECODED_VIDEO_INVALID_REASONS as readonly unknown[]).includes(p.invalidReason)
    ) ||
    typeof p.ended !== 'boolean'
  )
    return false;
  let previous = p.coverageAtMs;
  for (const row of p.arrivals) {
    if (
      !Array.isArray(row) ||
      row.length !== 2 ||
      !Number.isSafeInteger(row[0]) ||
      !time(row[1]) ||
      row[1] < previous ||
      row[1] > p.sampledAtMs
    )
      return false;
    previous = row[1];
  }
  return true;
}
const base = (p: DecoderDeliveryPacket) =>
  Math.max(0, p.lastOrdinal - DECODER_DELIVERY_MAX_ARRIVALS);
function full(p: DecoderDeliveryPacket) {
  if (!deliveryPacketValid(p) || p.afterOrdinal !== base(p)) throw new Error('delivery_incomplete');
}
/** A cursor is an optimization only. Missing/retired/wrong-scope cursors get a full tail. */
export function deliveryDelta(
  history: DecoderDeliveryPacket,
  cursor?: DecoderDeliveryCursor,
): DecoderDeliveryPacket {
  full(history);
  const after =
    cursor?.scopeID === history.scopeID &&
    count(cursor.lastOrdinal) &&
    cursor.lastOrdinal >= history.afterOrdinal &&
    cursor.lastOrdinal <= history.lastOrdinal
      ? cursor.lastOrdinal
      : history.afterOrdinal;
  return {
    ...history,
    afterOrdinal: after,
    arrivals: history.arrivals.slice(after - history.afterOrdinal).map((r) => [...r]),
  };
}
/** Validates exact retained overlap and reconstructs a complete bounded tail.
 * Callers must additionally bind scope to the authenticated publication/attempt. */
export function advanceDelivery(
  previous: DecoderDeliveryPacket | undefined,
  next: DecoderDeliveryPacket | undefined,
): DecoderDeliveryPacket | undefined {
  if (!next) return previous;
  if (!deliveryPacketValid(next)) throw new Error('delivery_invalid');
  if (!previous) {
    full(next);
    return { ...next, arrivals: next.arrivals.map((r) => [...r]) };
  }
  full(previous);
  if (
    next.scopeID !== previous.scopeID ||
    next.sampledAtMs < previous.sampledAtMs ||
    next.lastOrdinal < previous.lastOrdinal ||
    next.coverageAtMs < previous.coverageAtMs ||
    (previous.ended &&
      (!next.ended ||
        next.sampledAtMs !== previous.sampledAtMs ||
        next.lastOrdinal !== previous.lastOrdinal)) ||
    (previous.invalidReason !== null && next.invalidReason !== previous.invalidReason)
  )
    throw new Error('delivery_regression');
  const retainedBase = base(next);
  if (retainedBase === previous.afterOrdinal && next.coverageAtMs !== previous.coverageAtMs)
    throw new Error('delivery_coverage');
  if (
    retainedBase > previous.afterOrdinal &&
    retainedBase <= previous.lastOrdinal &&
    next.coverageAtMs !== previous.arrivals[retainedBase - previous.afterOrdinal - 1]![1]
  )
    throw new Error('delivery_coverage');
  if (retainedBase > previous.lastOrdinal && next.coverageAtMs < previous.sampledAtMs)
    throw new Error('delivery_coverage');
  const rows = new Map<number, [number, number]>();
  previous.arrivals.forEach((r, i) => {
    if (previous.afterOrdinal + i + 1 > retainedBase) rows.set(previous.afterOrdinal + i + 1, r);
  });
  next.arrivals.forEach((r, i) => {
    const ordinal = next.afterOrdinal + i + 1,
      old = rows.get(ordinal);
    if (old && (old[0] !== r[0] || old[1] !== r[1])) throw new Error('delivery_overlap');
    if (ordinal > previous.lastOrdinal && r[1] < previous.sampledAtMs)
      throw new Error('delivery_backdated');
    rows.set(ordinal, r);
  });
  const arrivals: [number, number][] = [];
  for (let n = retainedBase; n < next.lastOrdinal; ) {
    const row = rows.get(++n);
    if (!row) throw new Error('delivery_gap');
    arrivals.push([...row]);
  }
  const result = { ...next, afterOrdinal: retainedBase, arrivals };
  full(result);
  return result;
}
export function deliverySnapshot(history: DecoderDeliveryPacket): DecoderDeliverySnapshot {
  full(history);
  return {
    formatVersion: 1,
    scopeID: history.scopeID,
    coverageAgeMs: history.sampledAtMs - history.coverageAtMs,
    lastOrdinal: history.lastOrdinal,
    arrivals: history.arrivals.map(([pts, at], i) => ({
      ordinal: history.afterOrdinal + i + 1,
      pts,
      ageMs: history.sampledAtMs - at,
    })),
    invalidReason: history.invalidReason,
    ended: history.ended,
  };
}
