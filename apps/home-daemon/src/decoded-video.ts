import type { DecodedVideoInvalidReason, DecodedVideoSnapshot } from '@scorebug/protocol';
export type {
  DecodedVideoInvalidReason,
  DecodedVideoSnapshot,
  DecodedVideoWindow,
} from '@scorebug/protocol';

// Decoded PTS cadence at fixed 1/90000, not image-content uniqueness or viewer delivery.
/** Retains one <=1024-byte ASCII line and one numeric header, never raw diagnostics. */
export class DecodedVideoParser {
  private line = '';
  private header: { ordinal: number; pts: number } | undefined;
  private ordinal = -1;
  private invalid = false;
  private ended = false;
  constructor(
    private readonly accept: (pts: number) => void,
    private readonly reject: (reason: DecodedVideoInvalidReason) => void,
  ) {}
  private fail(reason: DecodedVideoInvalidReason) {
    if (this.invalid) return;
    this.invalid = true;
    this.line = '';
    this.header = undefined;
    try {
      this.reject(reason);
    } catch {
      /* Observer exceptions never escape the pipe drain. */
    }
  }
  push(chunk: Buffer) {
    if (this.invalid || this.ended) return;
    for (const byte of chunk) {
      if (this.invalid) return;
      if (byte === 10) {
        const line = this.line;
        this.line = '';
        this.consume(line);
      } else if (byte < 32 || byte > 126) {
        this.fail('framing');
      } else if (this.line.length >= 1024) {
        this.fail('oversized');
      } else {
        this.line += String.fromCharCode(byte);
      }
    }
  }
  private consume(line: string) {
    if (this.header) {
      if (line !== 'scorebug.source=1') {
        this.fail('framing');
        return;
      }
      const header = this.header;
      this.header = undefined;
      this.ordinal = header.ordinal;
      try {
        this.accept(header.pts);
      } catch {
        this.fail('callback');
      }
      return;
    }
    const match = /^frame:(\d+)\s+pts:\s*(-?\d+)\s+pts_time:(\S+)$/.exec(line);
    if (!match) {
      this.fail('framing');
      return;
    }
    const ordinal = Number(match[1]),
      pts = Number(match[2]),
      time = Number(match[3]);
    if (
      !Number.isSafeInteger(ordinal) ||
      !Number.isSafeInteger(pts) ||
      !Number.isFinite(time) ||
      !/^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(match[3]!)
    ) {
      this.fail('numeric');
      return;
    }
    if (this.ordinal === Number.MAX_SAFE_INTEGER || ordinal !== this.ordinal + 1) {
      this.fail('ordinal');
      return;
    }
    this.header = { ordinal, pts };
  }
  end() {
    if (this.ended) return;
    this.ended = true;
    if (this.line.length || this.header) this.fail('incomplete');
  }
}

type Counts = {
  firstPTS: number | null;
  lastPTS: number | null;
  freshFrames: number;
  duplicateFrames: number;
  reorderedFrames: number;
};
const empty = (): Counts => ({
  firstPTS: null,
  lastPTS: null,
  freshFrames: 0,
  duplicateFrames: 0,
  reorderedFrames: 0,
});
const durationMs = 5000;

/** One active and one latest completed wall-time window per pipeline instance. */
export class DecodedVideoTelemetry {
  private readonly parser: DecodedVideoParser;
  private invalidReason: DecodedVideoInvalidReason | null = null;
  private ended = false;
  private lastNow: number | undefined;
  private origin: number | undefined;
  private index = 0;
  private active = empty();
  private completed: { counts: Counts; sequence: number; end: number } | undefined;
  private highestPTS: number | undefined;
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
    if (this.origin === undefined || this.ended) return;
    const index = Math.floor((now - this.origin) / durationMs);
    if (!Number.isSafeInteger(index + 1)) {
      this.fail('overflow');
      return;
    }
    if (index <= this.index) return;
    this.completed = {
      counts: index === this.index + 1 ? this.active : empty(),
      sequence: index,
      end: this.origin + index * durationMs,
    };
    this.index = index;
    this.active = empty();
  }
  private record(pts: number) {
    const now = this.time();
    if (now === undefined || this.ended) return;
    if (this.origin === undefined) this.origin = now;
    this.advance(now);
    const key =
      this.highestPTS === undefined || pts > this.highestPTS
        ? 'freshFrames'
        : pts === this.highestPTS
          ? 'duplicateFrames'
          : 'reorderedFrames';
    const total =
      this.active.freshFrames + this.active.duplicateFrames + this.active.reorderedFrames;
    if (!Number.isSafeInteger(total) || total >= Number.MAX_SAFE_INTEGER) {
      this.fail('overflow');
      return;
    }
    this.active[key]++;
    if (key === 'freshFrames') {
      this.highestPTS = pts;
      this.active.firstPTS ??= pts;
      this.active.lastPTS = pts;
    }
  }
  push(chunk: Buffer) {
    if (!this.ended) this.parser.push(chunk);
  }
  end() {
    if (this.ended) return;
    this.parser.end();
    const now = this.time();
    if (now !== undefined) this.advance(now);
    this.ended = true;
    this.active = empty();
  }
  snapshot(): DecodedVideoSnapshot {
    const now = this.time();
    if (now !== undefined) this.advance(now);
    return {
      completed: this.completed
        ? {
            ...this.completed.counts,
            sequence: this.completed.sequence,
            durationMs,
            ageMs: Math.max(0, (now ?? this.lastNow ?? this.completed.end) - this.completed.end),
            valid: this.invalidReason === null,
          }
        : null,
      invalidReason: this.invalidReason,
      ended: this.ended,
    };
  }
}

export type DecodedVideoLifetimeSnapshot = Readonly<{
  acceptedFrames: number;
  freshFrames: number;
  duplicateFrames: number;
  reorderedFrames: number;
  /** First/last accepted PTS; highestPTS alone tracks the freshness watermark. */
  firstPTS: number | null;
  lastPTS: number | null;
  highestPTS: number | null;
  timeBase: '1/90000';
  invalidReason: DecodedVideoInvalidReason | null;
  ended: boolean;
}>;

/** Optional diagnostic reader: constant space, no clock or reporting-window dependence. */
export class DecodedVideoLifetime {
  private value: DecodedVideoLifetimeSnapshot = {
    acceptedFrames: 0,
    freshFrames: 0,
    duplicateFrames: 0,
    reorderedFrames: 0,
    firstPTS: null,
    lastPTS: null,
    highestPTS: null,
    timeBase: '1/90000',
    invalidReason: null,
    ended: false,
  };
  private readonly parser = new DecodedVideoParser(
    (pts) => {
      if (this.value.invalidReason !== null) return;
      if (
        !Number.isSafeInteger(this.value.acceptedFrames) ||
        this.value.acceptedFrames >= Number.MAX_SAFE_INTEGER
      ) {
        this.value = { ...this.value, invalidReason: 'overflow' };
        return;
      }
      const key =
        this.value.highestPTS === null || pts > this.value.highestPTS
          ? 'freshFrames'
          : pts === this.value.highestPTS
            ? 'duplicateFrames'
            : 'reorderedFrames';
      this.value = {
        ...this.value,
        acceptedFrames: this.value.acceptedFrames + 1,
        [key]: this.value[key] + 1,
        firstPTS: this.value.firstPTS ?? pts,
        lastPTS: pts,
        highestPTS: key === 'freshFrames' ? pts : this.value.highestPTS,
      };
    },
    (reason) => {
      this.value = { ...this.value, invalidReason: this.value.invalidReason ?? reason };
    },
  );
  push(chunk: Buffer) {
    this.parser.push(chunk);
  }
  end() {
    if (this.value.ended) return;
    this.parser.end();
    this.value = Object.freeze({ ...this.value, ended: true });
  }
  snapshot(): DecodedVideoLifetimeSnapshot {
    return { ...this.value };
  }
}
