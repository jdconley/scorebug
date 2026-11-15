// FFmpeg debug_ts is version-dependent. These observations are diagnostic only.
// Retain numeric fields, never raw stderr, URLs, payloads or cross-stream ordering.
const integer = '-?\\d{1,19}';
const decimal = '-?\\d{1,20}(?:\\.\\d{1,20})?(?:e[+-]?\\d{1,3})?';
const demux = new RegExp(
  `^\\[([va])ist#0:([01])/[A-Za-z0-9_]+ @ 0x[0-9a-f]+\\] demuxer -> ist_index:0:([01]) type:(video|audio) pkt_pts:(${integer}) pkt_pts_time:(${decimal}) pkt_dts:(${integer}) pkt_dts_time:(${decimal}) duration:`,
);
const mux = new RegExp(
  `^\\[([va])ost#0:([01])/copy @ 0x[0-9a-f]+\\] muxer <- pts:(${integer}) pts_time:(${decimal}) dts:(${integer}) dts_time:(${decimal}) duration:`,
);
const lane = () => ({ packetCount: 0, first: [] });
const signedTimestamp = (value) => BigInt(value) > -(1n << 63n) && BigInt(value) < 1n << 63n;

export class RecorderPacketTiming {
  #line = '';
  #discarding = false;
  #finished = false;
  #result = {
    formatVersion: 1,
    recognized: false,
    malformedRows: 0,
    oversizedLines: 0,
    unfinishedLine: false,
    demux: { video: lane(), audio: lane() },
    mux: { video: lane(), audio: lane() },
  };

  push(chunk) {
    if (this.#finished) return;
    // Iterate bytes so a non-ASCII stderr fragment cannot create numeric evidence.
    for (const byte of Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)) {
      if (byte === 10) {
        if (!this.#discarding) this.#accept(this.#line);
        this.#line = '';
        this.#discarding = false;
      } else if (!this.#discarding) {
        if (this.#line.length >= 2048) {
          this.#result.oversizedLines++;
          this.#line = '';
          this.#discarding = true;
        } else this.#line += String.fromCharCode(byte);
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
      this.#result.malformedRows++;
      return;
    }
    const media = match[1] === 'v' ? 'video' : 'audio';
    const index = media === 'video' ? '0' : '1';
    const fields = match.slice(stage === 'demux' ? 5 : 3);
    const [pts, ptsSeconds, dts, dtsSeconds] = fields;
    if (
      match[2] !== index ||
      (stage === 'demux' && (match[3] !== index || match[4] !== media)) ||
      !signedTimestamp(pts) ||
      !signedTimestamp(dts) ||
      !Number.isFinite(Number(ptsSeconds)) ||
      !Number.isFinite(Number(dtsSeconds))
    ) {
      this.#result.malformedRows++;
      return;
    }
    const target = this.#result[stage][media];
    target.packetCount++;
    if (target.first.length < 8) target.first.push({ pts, ptsSeconds, dts, dtsSeconds });
  }

  finish() {
    if (!this.#finished) {
      this.#finished = true;
      this.#result.unfinishedLine = this.#discarding || this.#line.length > 0;
      this.#line = '';
      this.#result.recognized =
        this.#result.malformedRows === 0 &&
        this.#result.oversizedLines === 0 &&
        !this.#result.unfinishedLine &&
        ['demux', 'mux'].every((stage) =>
          ['audio', 'video'].every((media) => this.#result[stage][media].packetCount > 0),
        );
    }
    return structuredClone(this.#result);
  }
}
