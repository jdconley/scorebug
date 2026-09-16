import type { Readable } from 'node:stream';
/** Coordinates are exact rational seconds; no optional decoder identity is assumed. */
export type EncoderTime = Readonly<{
  pts: string;
  timeBaseNumerator: number;
  timeBaseDenominator: number;
}>;
export type EncoderTimingFrame = EncoderTime &
  Readonly<{ ordinal: number; submittedAt: number; completedAt: number | null }>;
export type EncoderTimingSnapshot = Readonly<{
  frames: readonly EncoderTimingFrame[];
  submittedFrames: number;
  completedFrames: number;
  pendingFrames: number;
  maximumObservedPendingFrames: number;
  oldestPendingAgeMs: number | null;
  lastObservedAt: number | null;
  invalidReason: string | null;
  ended: boolean;
}>;
export type EncoderTimingInterval = Readonly<{
  submittedFrames: number;
  meanObservedDurationMs: number;
  maximumObservedDurationMs: number;
}>;
type Coordinate = { numerator: bigint; denominator: bigint; key: string };
function coordinate(time: EncoderTime): Coordinate | null {
  if (
    typeof time.pts !== 'string' ||
    time.pts.length > 20 ||
    !/^-?(0|[1-9]\d*)$/.test(time.pts) ||
    !Number.isInteger(time.timeBaseNumerator) ||
    !Number.isInteger(time.timeBaseDenominator) ||
    time.timeBaseNumerator < 1 ||
    time.timeBaseNumerator > 2147483647 ||
    time.timeBaseDenominator < 1 ||
    time.timeBaseDenominator > 2147483647
  )
    return null;
  const pts = BigInt(time.pts);
  // INT64_MIN is FFmpeg's unavailable timestamp sentinel.
  if (pts <= -(1n << 63n) || pts >= 1n << 63n) return null;
  let numerator = pts * BigInt(time.timeBaseNumerator),
    denominator = BigInt(time.timeBaseDenominator);
  let a = numerator < 0n ? -numerator : numerator,
    b = denominator;
  while (b !== 0n) {
    const remainder = a % b;
    a = b;
    b = remainder;
  }
  numerator /= a;
  denominator /= a;
  return { numerator, denominator, key: `${numerator}/${denominator}` };
}
function compare(a: Coordinate, b: Coordinate): bigint {
  return a.numerator * b.denominator - b.numerator * a.denominator;
}

/** Historical reader-observed encoder durations, excluding decode/filter time and viewer delivery. */
export function encoderTimingInterval(
  snapshot: EncoderTimingSnapshot,
  start: EncoderTime,
  end: EncoderTime,
): EncoderTimingInterval | null {
  const a = coordinate(start),
    b = coordinate(end);
  if (snapshot.invalidReason !== null || !a || !b || compare(a, b) >= 0n) return null;
  const left = snapshot.frames.findIndex((frame) => coordinate(frame)?.key === a.key);
  const right = snapshot.frames.findIndex((frame) => coordinate(frame)?.key === b.key);
  if (left < 0 || right <= left) return null;
  const frames = snapshot.frames.slice(left + 1, right + 1);
  if (frames.some((frame) => frame.completedAt === null)) return null;
  const durations = frames.map((frame) => frame.completedAt! - frame.submittedAt);
  return {
    submittedFrames: frames.length,
    meanObservedDurationMs: durations.reduce((sum, value) => sum + value / frames.length, 0),
    maximumObservedDurationMs: Math.max(...durations),
  };
}

type Frame = {
  ordinal: number;
  pts: string;
  timeBaseNumerator: number;
  timeBaseDenominator: number;
  submittedAt: number;
  completedAt: number | null;
};
/** Bounded ASCII pipe reader. Invalid diagnostics never throw into process ownership. */
export class EncoderTimingTelemetry {
  private line = '';
  private frames: Frame[] = [];
  private pending = new Map<string, Frame>();
  private submitted = 0;
  private completed = 0;
  private maximumPending = 0;
  private lastPre: Coordinate | undefined;
  private lastNow: number | undefined;
  private lastEventAt: number | null = null;
  private invalidReason: string | null = null;
  private ended = false;
  constructor(private readonly now: () => number = () => performance.now()) {}
  private fail(reason: string) {
    this.invalidReason ??= reason;
    this.line = '';
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
  push(chunk: Buffer) {
    if (this.ended || this.invalidReason !== null) return;
    for (const byte of chunk) {
      if (this.invalidReason !== null) break;
      if (byte === 10) {
        const line = this.line;
        this.line = '';
        this.consume(line);
      } else if (byte < 32 || byte > 126) this.fail('framing');
      else if (this.line.length >= 256) this.fail('oversized');
      else this.line += String.fromCharCode(byte);
    }
  }
  private consume(line: string) {
    const match = /^(pre|post) (0|[1-9]\d*) ([1-9]\d*)\/([1-9]\d*) (-?(?:0|[1-9]\d*))$/.exec(line);
    if (!match) {
      this.fail('framing');
      return;
    }
    const [, stage, rawOrdinal, rawNumerator, rawDenominator, pts] = match;
    const ordinal = Number(rawOrdinal);
    const stamp: EncoderTime = {
      pts: pts!,
      timeBaseNumerator: Number(rawNumerator),
      timeBaseDenominator: Number(rawDenominator),
    };
    const position = coordinate(stamp);
    if (!Number.isSafeInteger(ordinal) || ordinal >= Number.MAX_SAFE_INTEGER || !position) {
      this.fail('numeric');
      return;
    }
    if (ordinal !== (stage === 'pre' ? this.submitted : this.completed)) {
      this.fail('ordinal');
      return;
    }
    const now = this.time();
    if (now === undefined) return;
    this.lastEventAt = now;
    if (stage === 'pre') {
      if (this.lastPre && compare(position, this.lastPre) <= 0n) {
        this.fail('source_order');
        return;
      }
      if (this.frames.length === 256) {
        if (this.frames[0]!.completedAt === null) {
          this.fail('retention');
          return;
        }
        this.frames.shift();
      }
      const frame: Frame = { ...stamp, ordinal, submittedAt: now, completedAt: null };
      this.frames.push(frame);
      this.pending.set(position.key, frame);
      this.lastPre = position;
      this.submitted++;
      this.maximumPending = Math.max(this.maximumPending, this.pending.size);
    } else {
      const frame = this.pending.get(position.key);
      if (!frame) {
        this.fail('unmatched');
        return;
      }
      frame.completedAt = now;
      this.pending.delete(position.key);
      this.completed++;
    }
  }
  invalidatePipe() {
    if (!this.ended) this.fail('pipe');
  }
  end() {
    if (this.ended) return;
    if (this.line.length) this.fail('incomplete');
    this.time();
    this.ended = true;
  }
  snapshot(): EncoderTimingSnapshot {
    const now = this.time();
    const oldest = this.pending.values().next().value as Frame | undefined;
    return {
      frames: this.frames.map((frame) => ({ ...frame })),
      submittedFrames: this.submitted,
      completedFrames: this.completed,
      pendingFrames: this.pending.size,
      maximumObservedPendingFrames: this.maximumPending,
      oldestPendingAgeMs:
        this.invalidReason === null && oldest && now !== undefined
          ? now - oldest.submittedAt
          : null,
      lastObservedAt: this.lastEventAt,
      invalidReason: this.invalidReason,
      ended: this.ended,
    };
  }
}

/** Drain the optional side channel independently of publisher ownership. */
export function observeEncoderTimingPipe(pipe: Readable, timing?: EncoderTimingTelemetry) {
  let eof = false;
  pipe.on('data', (chunk: Buffer) => timing?.push(chunk));
  pipe.once('end', () => {
    eof = true;
    timing?.end();
  });
  pipe.on('error', () => timing?.invalidatePipe());
  pipe.once('close', () => {
    if (!eof) {
      timing?.invalidatePipe();
      timing?.end();
    }
  });
}
