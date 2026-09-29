// FFmpeg debug_ts formats are version-dependent. This DEBUG/test evidence is
// diagnostic only: it establishes neither health nor cross-stream arrival order.
const maximumPacketsPerLane = 128;
const maximumLineBytes = 4096;
const integer = '(?:0|-?[1-9]\\d{0,18})';
const decimal = '-?(?:0|[1-9]\\d{0,19})(?:\\.\\d{1,20})?(?:e[+-]?\\d{1,3})?';
const demux = new RegExp(
  `^\\[([va])ist#0:([01])/[A-Za-z0-9_]+ @ 0x[0-9a-f]+\\] (?:\\[info\\] )?demuxer -> ist_index:0:([01]) type:(video|audio) pkt_pts:(${integer}) pkt_pts_time:(${decimal}) pkt_dts:(${integer}) pkt_dts_time:(${decimal}) duration:(${integer}) duration_time:(${decimal})(?=\\s|$)`,
);
const mux = new RegExp(
  `^\\[([va])ost#0:([01])/[A-Za-z0-9_]+ @ 0x[0-9a-f]+\\] (?:\\[info\\] )?muxer <- pts:(${integer}) pts_time:(${decimal}) dts:(${integer}) dts_time:(${decimal}) duration:(${integer}) duration_time:(${decimal})(?=\\s|$)`,
);
const increment = (value) => Math.min(Number.MAX_SAFE_INTEGER, value + 1);
const signedTimestamp = (value) => BigInt(value) > -(1n << 63n) && BigInt(value) < 1n << 63n;
/** @typedef {{pts: string, ptsSeconds: string, dts: string, dtsSeconds: string}} Packet */
/** @typedef {Packet & {duration: string, durationSeconds: string}} TimedPacket */
/** @returns {{packetCount: number, first: Packet[], last: TimedPacket[]}} */
const lane = () => ({ packetCount: 0, first: [], last: [] });

export class WorkerPacketTiming {
  #line = '';
  #tailOffsets = { demux: { video: 0, audio: 0 }, mux: { video: 0, audio: 0 } };
  #discarding = false;
  #result = {
    formatVersion: 2,
    diagnosticOnly: true,
    maximumPacketsPerLane,
    ended: false,
    pipeError: false,
    drainTimedOut: false,
    incompleteLine: false,
    malformedRows: 0,
    oversizedLines: 0,
    demux: { video: lane(), audio: lane() },
    mux: { video: lane(), audio: lane() },
  };

  /** @param {Uint8Array} chunk */
  push(chunk) {
    if (this.#result.ended) return;
    // Byte framing avoids UTF-8 replacement or Unicode normalization creating
    // numeric evidence, and bounds even a single untrusted, enormous chunk.
    for (const byte of chunk) {
      if (byte === 10) {
        if (!this.#discarding) this.#accept(this.#line);
        this.#line = '';
        this.#discarding = false;
      } else if (!this.#discarding) {
        if (this.#line.length === maximumLineBytes) {
          this.#result.oversizedLines = increment(this.#result.oversizedLines);
          this.#line = '';
          this.#discarding = true;
        } else {
          this.#line += String.fromCharCode(byte);
        }
      }
    }
  }

  #accept(line) {
    const stage = line.includes(' demuxer -> ')
      ? 'demux'
      : line.includes(' muxer <- ')
        ? 'mux'
        : undefined;
    if (!stage) return;
    const match = line.match(stage === 'demux' ? demux : mux);
    if (!match) {
      this.#result.malformedRows = increment(this.#result.malformedRows);
      return;
    }
    const media = match[1] === 'v' ? 'video' : 'audio';
    const index = media === 'video' ? '0' : '1';
    const [pts, ptsSeconds, dts, dtsSeconds, duration, durationSeconds] = match.slice(
      stage === 'demux' ? 5 : 3,
    );
    if (
      match[2] !== index ||
      (stage === 'demux' && (match[3] !== index || match[4] !== media)) ||
      !signedTimestamp(pts) ||
      !signedTimestamp(dts) ||
      !Number.isFinite(Number(ptsSeconds)) ||
      !Number.isFinite(Number(dtsSeconds)) ||
      !signedTimestamp(duration) ||
      BigInt(duration) < 0n ||
      !Number.isFinite(Number(durationSeconds)) ||
      Number(durationSeconds) < 0
    ) {
      this.#result.malformedRows = increment(this.#result.malformedRows);
      return;
    }
    const target = this.#result[stage][media];
    target.packetCount = increment(target.packetCount);
    if (target.first.length < maximumPacketsPerLane) {
      target.first.push({ pts, ptsSeconds, dts, dtsSeconds });
    }
    const offset = this.#tailOffsets[stage][media];
    target.last[offset] = { pts, ptsSeconds, dts, dtsSeconds, duration, durationSeconds };
    this.#tailOffsets[stage][media] = (offset + 1) % maximumPacketsPerLane;
  }

  end() {
    if (this.#result.ended) return;
    this.#result.ended = true;
    this.#result.incompleteLine = this.#discarding || this.#line.length > 0;
    this.#line = '';
    this.#discarding = false;
  }

  failPipe() {
    this.#result.pipeError = true;
  }

  timeOutDrain() {
    this.#result.drainTimedOut = true;
  }

  snapshot() {
    const result = structuredClone(this.#result);
    for (const stage of /** @type {const} */ (['demux', 'mux']))
      for (const media of /** @type {const} */ (['video', 'audio'])) {
        const target = result[stage][media];
        const offset = this.#tailOffsets[stage][media];
        if (target.last.length === maximumPacketsPerLane)
          target.last = [...target.last.slice(offset), ...target.last.slice(0, offset)];
      }
    return result;
  }
}

/** @typedef {ReturnType<WorkerPacketTiming['snapshot']>} WorkerPacketTimingSnapshot */
