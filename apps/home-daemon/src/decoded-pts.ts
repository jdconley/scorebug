export type DecodedPtsInvalidReason =
  'framing' | 'numeric' | 'ordinal' | 'oversized' | 'incomplete' | 'callback';

/** Parses FFmpeg's per-frame `metadata=mode=print` records from the decoded side branch
 * (PTS at a fixed 1/90000 timebase). The scorebug overlay stamps its frames from these.
 * Retains one <=1024-byte ASCII line and one numeric header, never raw diagnostics. */
export class DecodedPtsParser {
  private line = '';
  private header: { ordinal: number; pts: number } | undefined;
  private ordinal = -1;
  private invalid = false;
  private ended = false;
  constructor(
    private readonly accept: (pts: number) => void,
    private readonly reject: (reason: DecodedPtsInvalidReason) => void,
  ) {}
  private fail(reason: DecodedPtsInvalidReason) {
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
