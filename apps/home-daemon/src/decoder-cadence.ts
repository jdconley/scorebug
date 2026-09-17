import { randomUUID } from 'node:crypto';
import type { DecodedVideoInvalidReason } from '@scorebug/protocol';
import { DecodedVideoParser } from './decoded-video.js';

type Counts = {
  firstPTS: number | null;
  lastPTS: number | null;
  freshFrames: number;
  duplicateFrames: number;
  reorderedFrames: number;
};
export type DecoderCadenceWindow = Counts & {
  sequence: number;
  durationMs: 1000 | 2000;
  ageMs: number;
  valid: boolean;
};
export type DecoderCadenceSnapshot = {
  formatVersion: 1;
  scopeID: string;
  oneSecond: DecoderCadenceWindow | null;
  twoSeconds: DecoderCadenceWindow | null;
  /** Decoder-arrival progress only; never source lateness or viewer delivery. */
  progress: { lastFreshPTS: number; ageMs: number; stalled: boolean } | null;
  invalidReason: DecodedVideoInvalidReason | null;
  ended: boolean;
};
const empty = (): Counts => ({
  firstPTS: null,
  lastPTS: null,
  freshFrames: 0,
  duplicateFrames: 0,
  reorderedFrames: 0,
});
type WindowState = {
  durationMs: 1000 | 2000;
  index: number;
  active: Counts;
  completed?: { counts: Counts; sequence: number; end: number };
};

/** Two independent wall-clock counters and a progress watchdog, constant space.
 * A caller samples from its bounded health loop; no input event is needed to
 * close a window or detect a stall. First arrival establishes the clock origin.
 * Increasing PTS distinguishes fresh arrivals, not on-time source delivery.
 * In particular, a delayed burst can have high cadence and is NOT healthy proof.
 */
export class DecoderCadenceTelemetry {
  private readonly scopeID = randomUUID();
  private readonly windows: WindowState[] = [1000, 2000].map((durationMs) => ({
    durationMs: durationMs as 1000 | 2000,
    index: 0,
    active: empty(),
  }));
  private origin: number | undefined;
  private lastNow: number | undefined;
  private lastFreshAt: number | undefined;
  private highestPTS: number | undefined;
  private invalidReason: DecodedVideoInvalidReason | null = null;
  private ended = false;
  private readonly parser: DecodedVideoParser;
  constructor(private readonly now: () => number = () => performance.now()) {
    this.parser = new DecodedVideoParser(
      (pts) => this.record(pts),
      (reason) => this.fail(reason),
    );
  }
  private fail(reason: DecodedVideoInvalidReason) {
    this.invalidReason ??= reason;
  }
  private time(): number | undefined {
    if (this.ended) return this.lastNow;
    let now: number;
    try {
      now = this.now();
    } catch {
      this.fail('clock');
      return;
    }
    if (
      !Number.isFinite(now) ||
      now < 0 ||
      now > Number.MAX_SAFE_INTEGER ||
      (this.lastNow !== undefined && now < this.lastNow)
    ) {
      this.fail('clock');
      return;
    }
    this.lastNow = now;
    return now;
  }
  private advance(now: number) {
    if (this.origin === undefined || this.ended || this.invalidReason !== null) return;
    for (const window of this.windows) {
      const index = Math.floor((now - this.origin) / window.durationMs);
      if (!Number.isSafeInteger(index + 1)) {
        this.fail('overflow');
        return;
      }
      if (index <= window.index) continue;
      window.completed = {
        counts: index === window.index + 1 ? window.active : empty(),
        sequence: index,
        end: this.origin + index * window.durationMs,
      };
      window.index = index;
      window.active = empty();
    }
  }
  private record(pts: number) {
    const now = this.time();
    if (now === undefined || this.ended || this.invalidReason !== null) return;
    this.origin ??= now;
    this.advance(now);
    if (this.invalidReason !== null) return;
    const key =
      this.highestPTS === undefined || pts > this.highestPTS
        ? 'freshFrames'
        : pts === this.highestPTS
          ? 'duplicateFrames'
          : 'reorderedFrames';
    for (const window of this.windows) {
      const counts = window.active;
      const total = counts.freshFrames + counts.duplicateFrames + counts.reorderedFrames;
      if (!Number.isSafeInteger(total + 1)) {
        this.fail('overflow');
        return;
      }
      counts[key]++;
      if (key === 'freshFrames') {
        counts.firstPTS ??= pts;
        counts.lastPTS = pts;
      }
    }
    if (key === 'freshFrames') {
      this.highestPTS = pts;
      this.lastFreshAt = now;
    }
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
    const now = this.time();
    if (now !== undefined) this.advance(now);
    this.ended = true;
    for (const window of this.windows) window.active = empty();
  }
  snapshot(): DecoderCadenceSnapshot {
    const sampled = this.time();
    if (sampled !== undefined) this.advance(sampled);
    const now = sampled ?? this.lastNow ?? 0;
    const window = (state: WindowState): DecoderCadenceWindow | null =>
      state.completed
        ? {
            ...state.completed.counts,
            sequence: state.completed.sequence,
            durationMs: state.durationMs,
            ageMs: Math.max(0, now - state.completed.end),
            valid: this.invalidReason === null,
          }
        : null;
    const progress =
      this.highestPTS !== undefined && this.lastFreshAt !== undefined
        ? {
            lastFreshPTS: this.highestPTS,
            ageMs: Math.max(0, now - this.lastFreshAt),
            stalled: !this.ended && this.invalidReason === null && now - this.lastFreshAt >= 1000,
          }
        : null;
    return {
      formatVersion: 1,
      scopeID: this.scopeID,
      oneSecond: window(this.windows[0]!),
      twoSeconds: window(this.windows[1]!),
      progress,
      invalidReason: this.invalidReason,
      ended: this.ended,
    };
  }
}
