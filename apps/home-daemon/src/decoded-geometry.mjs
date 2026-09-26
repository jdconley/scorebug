// Diagnostic only: decoded AVFrame geometry is not delivery, health or capacity.
const maximumLineBytes = 4096;
const maximumRuns = 64;
const named = /^\[showinfo@scorebug_geometry @ 0x[0-9a-f]+\] (?:\[info\] )?(.*)$/;
const frame =
  /^n:\s*(\S+)\s+pts:\s*(\S+)\s+pts_time:(\S+)\s+duration:\s*(\S+)\s+duration_time:(\S+)\s+fmt:\S+\s+cl:\S+\s+sar:\S+\s+s:(\S+)\s+i:\S+\s+iskey:\S+\s+type:\S+\s*$/;
const integer = /^(?:0|-?[1-9]\d*)$/;
const decimal = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:e[+-]?\d+)?$/;
/** @typedef {'time_base'|'ordinal'|'number'|'pts_order'|'dimensions'|'frame_row'|'run_limit'|'oversized_line'|'incomplete_line'|'no_frames'|'pipe_error'|'drain_timeout'} InvalidReason */
/** @typedef {{width:number,height:number,firstOrdinal:number,lastOrdinal:number,firstPTS:number,lastPTS:number,frames:number,maximumPTSDelta:number}} GeometryRun */
/** @typedef {{formatVersion:1,diagnosticOnly:true,timeBase:'1/90000',maximumRuns:number,ended:boolean,invalidReason:InvalidReason|null,observedFrames:number,runs:GeometryRun[]}} DecodedGeometrySnapshot */
export class DecodedGeometry {
  #line = '';
  #configured = false;
  /** @type {DecodedGeometrySnapshot} */
  #result = {
    formatVersion: 1,
    diagnosticOnly: true,
    timeBase: '1/90000',
    maximumRuns,
    ended: false,
    invalidReason: null,
    observedFrames: 0,
    runs: [],
  };

  /** @param {InvalidReason} reason */
  #fail(reason) {
    this.#result.invalidReason ??= reason;
    this.#line = '';
  }

  /** @param {Uint8Array} chunk */
  push(chunk) {
    if (this.#result.ended || this.#result.invalidReason) return;
    // Byte framing bounds even one enormous chunk; the guardian still drains
    // stderr after rejection. No raw text is exposed by any snapshot or error.
    for (const byte of chunk) {
      if (byte === 10) {
        this.#accept(this.#line);
        this.#line = '';
        if (this.#result.invalidReason) return;
      } else {
        if (this.#line.length === maximumLineBytes) {
          this.#fail('oversized_line');
          return;
        }
        this.#line += String.fromCharCode(byte);
      }
    }
  }

  /** @param {string} line */
  #accept(line) {
    const body = line.match(named)?.[1];
    if (body === undefined) return;
    if (body.startsWith('config in ')) {
      if (!/^config in time_base: 1\/90000, frame_rate: \d+\/\d+\s*$/.test(body))
        this.#fail('time_base');
      else this.#configured = true;
      return;
    }
    // Color and side-data diagnostics can contain arbitrary private text.
    if (/^(?:\s*$|\s*side data|User Data=|color_|config out )/.test(body)) return;
    if (!/^n(?:[:\s]|$)/.test(body)) return;
    const match = body.match(frame);
    if (!match) {
      this.#fail('frame_row');
      return;
    }
    if (!this.#configured) {
      this.#fail('time_base');
      return;
    }
    const [ordinalText, ptsText, ptsSeconds, duration, durationSeconds, size] = match.slice(1);
    const ordinal = Number(ordinalText),
      pts = Number(ptsText);
    if (
      ![ordinalText, ptsText, duration].every(
        (value) => integer.test(value) && Number.isSafeInteger(Number(value)),
      ) ||
      ![ptsSeconds, durationSeconds].every(
        (value) => decimal.test(value) && Number.isFinite(Number(value)),
      ) ||
      !Number.isSafeInteger(ordinal) ||
      !Number.isSafeInteger(pts)
    ) {
      this.#fail('number');
      return;
    }
    if (ordinal !== this.#result.observedFrames || !Number.isSafeInteger(ordinal + 1)) {
      this.#fail('ordinal');
      return;
    }
    const dimensions = size.match(/^([1-9]\d*)x([1-9]\d*)$/);
    const width = Number(dimensions?.[1]),
      height = Number(dimensions?.[2]);
    if (
      !Number.isSafeInteger(width) ||
      !Number.isSafeInteger(height) ||
      width > 7680 ||
      height > 4320 ||
      width % 2 ||
      height % 2
    ) {
      this.#fail('dimensions');
      return;
    }
    const previous = this.#result.runs.at(-1);
    const delta = previous ? pts - previous.lastPTS : 0;
    if (previous && (delta <= 0 || !Number.isSafeInteger(delta))) {
      this.#fail('pts_order');
      return;
    }
    if (previous?.width === width && previous.height === height) {
      previous.lastOrdinal = ordinal;
      previous.lastPTS = pts;
      previous.frames++;
      previous.maximumPTSDelta = Math.max(previous.maximumPTSDelta, delta);
    } else {
      if (this.#result.runs.length === maximumRuns) {
        this.#fail('run_limit');
        return;
      }
      this.#result.runs.push({
        width,
        height,
        firstOrdinal: ordinal,
        lastOrdinal: ordinal,
        firstPTS: pts,
        lastPTS: pts,
        frames: 1,
        maximumPTSDelta: 0,
      });
    }
    this.#result.observedFrames++;
  }

  end() {
    if (this.#result.ended) return;
    if (this.#line.length) this.#fail('incomplete_line');
    if (!this.#configured) this.#fail('time_base');
    if (!this.#result.observedFrames) this.#fail('no_frames');
    this.#result.ended = true;
  }
  failPipe() {
    this.#fail('pipe_error');
  }
  timeOutDrain() {
    this.#fail('drain_timeout');
  }
  snapshot() {
    return structuredClone(this.#result);
  }
}
