import { randomUUID } from 'node:crypto';
import {
  DECODER_DELIVERY_MAX_ARRIVALS,
  type DecoderDeliverySnapshot,
  type DecoderDeliveryPacket,
} from '@scorebug/protocol';
import { DecodedVideoParser } from './decoded-video.js';
export type { DecoderDeliverySnapshot } from '@scorebug/protocol';
/** Bounded complete arrival log. No absolute worker timestamp leaves the snapshot.
 * Removing an entry advances exclusive coverage; missing history is never a loss. */
export class DecoderDeliveryTelemetry {
  private readonly scopeID = randomUUID();
  private arrivals: { ordinal: number; pts: number; at: number }[] = [];
  private lastOrdinal = 0;
  private lastNow: number | undefined;
  private coverageStart: number | undefined;
  private readonly origin: number;
  private invalidReason: string | null = null;
  private ended = false;
  private readonly parser = new DecodedVideoParser(
    (pts) => this.record(pts),
    (reason) => this.fail(reason),
  );
  constructor(private readonly now: () => number = () => performance.now()) {
    this.coverageStart = this.time();
    this.origin = this.coverageStart ?? 0;
  }
  private fail(reason: string) {
    this.invalidReason ??= reason;
  }
  private time(): number | undefined {
    if (this.ended) return this.lastNow;
    let value: number;
    try {
      value = this.now();
    } catch {
      this.fail('clock');
      return;
    }
    if (
      !Number.isFinite(value) ||
      value < 0 ||
      value > Number.MAX_SAFE_INTEGER ||
      (this.lastNow !== undefined && value < this.lastNow)
    ) {
      this.fail('clock');
      return;
    }
    this.lastNow = value;
    return value;
  }
  private record(pts: number) {
    const at = this.time();
    if (at === undefined || this.invalidReason !== null || this.ended) return;
    if (this.lastOrdinal === Number.MAX_SAFE_INTEGER) {
      this.fail('overflow');
      return;
    }
    if (this.arrivals.length === DECODER_DELIVERY_MAX_ARRIVALS)
      this.coverageStart = this.arrivals.shift()!.at;
    this.arrivals.push({ ordinal: ++this.lastOrdinal, pts, at });
  }
  push(chunk: Buffer) {
    if (!this.ended && this.invalidReason === null) this.parser.push(chunk);
  }
  invalidatePipe() {
    if (!this.ended) this.fail('incomplete');
  }
  end() {
    if (this.ended) return;
    this.parser.end();
    this.time();
    this.ended = true;
  }
  packet(): DecoderDeliveryPacket {
    const now = this.time() ?? this.lastNow ?? this.origin;
    return {
      formatVersion: 1,
      scopeID: this.scopeID,
      sampledAtMs: now - this.origin,
      coverageAtMs: (this.coverageStart ?? this.origin) - this.origin,
      afterOrdinal: Math.max(0, this.lastOrdinal - DECODER_DELIVERY_MAX_ARRIVALS),
      lastOrdinal: this.lastOrdinal,
      arrivals: this.arrivals.map((e) => [e.pts, e.at - this.origin]),
      invalidReason: this.invalidReason,
      ended: this.ended,
    };
  }
  snapshot(): DecoderDeliverySnapshot {
    const now = this.time() ?? this.lastNow ?? 0;
    return {
      formatVersion: 1,
      scopeID: this.scopeID,
      coverageAgeMs: Math.max(0, now - (this.coverageStart ?? now)),
      lastOrdinal: this.lastOrdinal,
      arrivals: this.arrivals.map((e) => ({
        ordinal: e.ordinal,
        pts: e.pts,
        ageMs: Math.max(0, now - e.at),
      })),
      invalidReason: this.invalidReason,
      ended: this.ended,
    };
  }
}
