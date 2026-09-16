// @ts-check
// Diagnostic categories only: these counts do not establish a root cause or
// qualify delivery. Raw lines (which can contain credentialed URLs) never escape.
const patterns = {
  inputReadError: /Error during demuxing|Error reading (?:header|packet|input)/i,
  outputOpenError: /Error opening output|Could not write header/i,
  connectionRefused: /Connection refused/i,
  connectionTimeout: /Connection timed out|Operation timed out/i,
  ioError: /Input\/output error/i,
  invalidData: /Invalid data found when processing input/i,
  corruptPacket: /Packet corrupt|Continuity check failed/i,
  decodeError: /Error submitting packet to decoder|Error while decoding|corrupt decoded frame/i,
  endOfFile: /End of file/i,
};
/** @param {number} value */
const increment = (value) => Math.min(Number.MAX_SAFE_INTEGER, value + 1);

export class EncoderDiagnostics {
  #pending = '';
  #dropping = false;
  #result = {
    counts: {
      inputReadError: 0,
      outputOpenError: 0,
      connectionRefused: 0,
      connectionTimeout: 0,
      ioError: 0,
      invalidData: 0,
      corruptPacket: 0,
      decodeError: 0,
      endOfFile: 0,
    },
    unmatchedLines: 0,
    oversizedLines: 0,
    incompleteLine: false,
    ended: false,
    pipeError: false,
    drainTimedOut: false,
  };
  /** @param {Uint8Array} chunk */
  push(chunk) {
    if (this.#result.ended) return;
    for (const byte of chunk) {
      if (byte === 10) {
        if (!this.#dropping && this.#pending.length) {
          let matched = false;
          for (const key of /** @type {(keyof typeof patterns)[]} */ (Object.keys(patterns))) {
            if (patterns[key].test(this.#pending)) {
              this.#result.counts[key] = increment(this.#result.counts[key]);
              matched = true;
            }
          }
          if (!matched) this.#result.unmatchedLines = increment(this.#result.unmatchedLines);
        }
        this.#pending = '';
        this.#dropping = false;
      } else if (!this.#dropping) {
        if (this.#pending.length < 4096) this.#pending += String.fromCharCode(byte);
        else {
          this.#pending = '';
          this.#dropping = true;
          this.#result.oversizedLines = increment(this.#result.oversizedLines);
        }
      }
    }
  }
  failPipe() {
    if (!this.#result.ended) this.#result.pipeError = true;
  }
  timeOutDrain() {
    if (!this.#result.ended) this.#result.drainTimedOut = true;
  }
  end() {
    if (this.#result.ended) return;
    this.#result.incompleteLine = this.#pending.length > 0 || this.#dropping;
    this.#result.ended = true;
    this.#pending = '';
  }
  snapshot() {
    return structuredClone(this.#result);
  }
}
/** @typedef {ReturnType<EncoderDiagnostics['snapshot']>} EncoderDiagnosticSnapshot */

/** Keep the error listener installed after EOF/finalization; no raw error escapes.
 * @param {import('node:stream').Readable} pipe
 * @param {EncoderDiagnostics} diagnostics
 */
export function observeEncoderDiagnostics(pipe, diagnostics) {
  pipe.on('data', (chunk) => diagnostics.push(chunk));
  pipe.on('error', () => diagnostics.failPipe());
}
