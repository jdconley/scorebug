import { FrameRateCap } from './frame-rate-cap.js';
import { randomUUID } from 'node:crypto';
import { DecodedVideoParser } from './decoded-video.js';
export type DecodedFrameRecord = Readonly<{
  pts: number;
  observedAt: number;
  selectedByFrameCap?: boolean;
}>;
export type DecodedFrameHistorySnapshot = Readonly<{
  scopeID: string;
  frames: readonly DecodedFrameRecord[];
  acceptedFrames: number;
  invalidReason: string | null;
  ended: boolean;
}>;
/** Source history only; decoder completion is not encoder or viewer delivery. */
export class DecodedFrameHistory {
  private readonly frameCap?: FrameRateCap;
  private frames: DecodedFrameRecord[] = [];
  private accepted = 0;
  private lastNow: number | undefined;
  private invalidReason: string | null = null;
  private ended = false;
  private readonly parser = new DecodedVideoParser(
    (pts) => this.record(pts),
    (reason) => this.fail(reason),
  );
  constructor(
    private readonly now: () => number = () => performance.now(),
    readonly scopeID: string = randomUUID(),
    capFPS?: number,
  ) {
    if (capFPS !== undefined) this.frameCap = new FrameRateCap(capFPS);
  }
  private fail(reason: string) {
    this.invalidReason ??= reason;
  }
  private record(pts: number) {
    if (this.ended || this.invalidReason !== null) return;
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
    const previous = this.frames.at(-1);
    if (previous && pts <= previous.pts) {
      this.fail('source_order');
      return;
    }
    if (this.accepted >= Number.MAX_SAFE_INTEGER) {
      this.fail('overflow');
      return;
    }
    if (this.frames.length === 512) this.frames.shift();
    this.frames.push({
      pts,
      observedAt: now,
      ...(this.frameCap ? { selectedByFrameCap: this.frameCap.select(pts) } : {}),
    });
    this.accepted++;
  }
  push(chunk: Buffer) {
    if (!this.ended && this.invalidReason === null) this.parser.push(chunk);
  }
  end() {
    if (!this.ended) {
      this.parser.end();
      this.ended = true;
    }
  }
  invalidatePipe() {
    if (!this.ended) this.fail('pipe');
  }
  snapshot(): DecodedFrameHistorySnapshot {
    return {
      scopeID: this.scopeID,
      frames: this.frames.map((frame) => ({ ...frame })),
      acceptedFrames: this.accepted,
      invalidReason: this.invalidReason,
      ended: this.ended,
    };
  }
}
