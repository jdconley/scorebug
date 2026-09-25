import assert from 'node:assert/strict';

export const SRT_PACKET_DIAGNOSTIC_LIMITS = Object.freeze({
  maxEvents: 131072,
  maxBytes: 32 * 1024 * 1024,
  maxDatagramBytes: 2048,
  maxControlRanges: 32,
});
const ENVELOPE_RESERVE = 4096;
const dispositions = new Set([
  'queued',
  'injectedDrop',
  'overflowDrop',
  'oversizeDrop',
  'forwarded',
  'closeDiscard',
]);
const directions = new Set(['forward', 'reverse']);
const add = (a, b) => Math.min(Number.MAX_SAFE_INTEGER, a + b);
const sequence = (word) => word <= 0x7fffffff;

// Only interpret a complete timestamp locally present in this TS packet.
// MPEG-2 PES timestamps use 33 bits, so JavaScript bitwise assembly would truncate.
function pesTime(data, offset, prefix) {
  if (
    data[offset] >>> 4 !== prefix ||
    !(data[offset] & 1) ||
    !(data[offset + 2] & 1) ||
    !(data[offset + 4] & 1)
  )
    return null;
  return (
    ((data[offset] >>> 1) & 7) * 2 ** 30 +
    data[offset + 1] * 2 ** 22 +
    (data[offset + 2] >>> 1) * 2 ** 15 +
    data[offset + 3] * 128 +
    (data[offset + 4] >>> 1)
  );
}
function pesHeader(data, start, end) {
  if (end - start < 3 || data[start] !== 0 || data[start + 1] !== 0 || data[start + 2] !== 1)
    return undefined;
  if (end - start < 6) return { status: 'incomplete' };
  const streamID = data[start + 3],
    result = { streamID, status: 'headerOnly' };
  // These stream IDs do not carry the MPEG-2 optional PES header.
  if ([0xbc, 0xbe, 0xbf, 0xf0, 0xf1, 0xff, 0xf2, 0xf8].includes(streamID)) return result;
  if (end - start < 9) return { streamID, status: 'incomplete' };
  const headerLength = data[start + 8],
    packetLength = data.readUInt16BE(start + 4);
  if ((data[start + 6] & 0xc0) !== 0x80 || (packetLength !== 0 && packetLength < 3 + headerLength))
    return { streamID, status: 'malformed' };
  if (start + 9 + headerLength > end) return { streamID, status: 'incomplete' };
  const flags = data[start + 7] >>> 6;
  if (flags === 1 || (flags === 2 && headerLength < 5) || (flags === 3 && headerLength < 10))
    return { streamID, status: 'malformed' };
  if (flags === 0) return result;
  const pts = pesTime(data, start + 9, flags === 3 ? 3 : 2);
  const dts = flags === 3 ? pesTime(data, start + 14, 1) : undefined;
  if (pts === null || dts === null) return { streamID, status: 'malformed' };
  return { streamID, status: 'parsed', pts, ...(dts === undefined ? {} : { dts }) };
}
function transportStream(data) {
  if (data.length === 16) return { status: 'empty' };
  if ((data.length - 16) % 188 !== 0) return { status: 'unaligned' };
  const packets = [];
  for (let start = 16; start < data.length; start += 188) {
    const end = start + 188,
      control = (data[start + 3] >>> 4) & 3;
    if (data[start] !== 0x47 || control === 0) return { status: 'malformed' };
    const packet = {
      pid: ((data[start + 1] & 31) << 8) | data[start + 2],
      continuityCounter: data[start + 3] & 15,
      payloadUnitStart: Boolean(data[start + 1] & 0x40),
      transportError: Boolean(data[start + 1] & 0x80),
      scrambling: data[start + 3] >>> 6,
      adaptationControl: control,
      discontinuity: false,
      randomAccess: false,
    };
    let payload = start + 4;
    if (control & 2) {
      const length = data[start + 4],
        adaptationEnd = start + 5 + length;
      if (
        adaptationEnd > end ||
        (control === 2 && length !== 183) ||
        (control === 3 && length > 182)
      )
        return { status: 'malformed' };
      if (length > 0) {
        const flags = data[start + 5];
        packet.discontinuity = Boolean(flags & 0x80);
        packet.randomAccess = Boolean(flags & 0x40);
        let cursor = start + 6;
        for (const [flag, bytes] of [
          [0x10, 6],
          [0x08, 6],
          [0x04, 1],
        ])
          if (flags & flag) cursor += bytes;
        if (cursor > adaptationEnd) return { status: 'malformed' };
        // Skip private/extension contents; validate lengths without retaining bytes.
        for (const flag of [0x02, 0x01]) {
          if (!(flags & flag)) continue;
          if (cursor >= adaptationEnd) return { status: 'malformed' };
          cursor += 1 + data[cursor];
          if (cursor > adaptationEnd) return { status: 'malformed' };
        }
      }
      payload = adaptationEnd;
    }
    if (
      control & 1 &&
      packet.payloadUnitStart &&
      !packet.transportError &&
      packet.scrambling === 0
    ) {
      const pes = pesHeader(data, payload, end);
      if (pes) packet.pes = pes;
    }
    packets.push(packet);
  }
  return { status: 'parsed', packets };
}

// SRT header layout and inclusive loss-list coding:
// https://haivision.github.io/srt-rfc/draft-sharabayko-srt.html (3.1, 3.2, Appendix A).
// This is a scalar diagnostic parser, not transport or media qualification.
function packetHeader(data, limits) {
  if (data.length > limits.maxDatagramBytes) return { kind: 'unparsed', reason: 'oversize' };
  if (data.length < 16) return { kind: 'malformed', reason: 'shortSRT' };
  const first = data.readUInt32BE(0),
    information = data.readUInt32BE(4);
  const common = { timestamp: data.readUInt32BE(8), destinationSocketID: data.readUInt32BE(12) };
  if (!(first & 0x80000000)) {
    const encryption = (information >>> 27) & 3;
    return {
      kind: 'data',
      sequence: first,
      messageNumber: information & 0x3ffffff,
      boundary: ['middle', 'last', 'first', 'single'][information >>> 30],
      inOrder: Boolean(information & 0x20000000),
      encryption,
      retransmitted: Boolean(information & 0x04000000),
      ...common,
      transportStream: encryption ? { status: 'encrypted' } : transportStream(data),
    };
  }
  const controlType = (first >>> 16) & 0x7fff,
    subtype = first & 0xffff;
  const result = { kind: 'control', controlType, subtype, ...common };
  // Never inspect handshake, key material, stream-ID extensions, or unknown bodies.
  if (subtype !== 0) return result;
  if (controlType === 2) {
    if (data.length < 20 || data.length % 4 !== 0 || !sequence(data.readUInt32BE(16)))
      return { ...result, malformed: 'ack' };
    return {
      ...result,
      acknowledgmentNumber: information,
      firstUnacknowledgedSequence: data.readUInt32BE(16),
    };
  }
  if (controlType === 6) return { ...result, acknowledgmentNumber: information };
  if (controlType === 7) {
    if (
      data.length !== 24 ||
      !sequence(data.readUInt32BE(16)) ||
      !sequence(data.readUInt32BE(20)) ||
      information > 0x3ffffff
    )
      return { ...result, malformed: 'dropRange' };
    return {
      ...result,
      messageNumber: information,
      dropRange: [data.readUInt32BE(16), data.readUInt32BE(20)],
    };
  }
  if (controlType === 3) {
    if (data.length === 16 || data.length % 4 !== 0) return { ...result, malformed: 'lossRanges' };
    const ranges = [];
    let count = 0;
    for (let offset = 16; offset < data.length; offset += 4) {
      const word = data.readUInt32BE(offset),
        firstSequence = word & 0x7fffffff;
      let lastSequence = firstSequence;
      if (word & 0x80000000) {
        offset += 4;
        if (offset >= data.length || !sequence(data.readUInt32BE(offset)))
          return { ...result, malformed: 'lossRanges' };
        lastSequence = data.readUInt32BE(offset);
      }
      if (count < limits.maxControlRanges) ranges.push([firstSequence, lastSequence]);
      count++;
    }
    return { ...result, lossRanges: ranges, omittedRanges: count - ranges.length };
  }
  return result;
}

/** Optional queue-side diagnostics. Each enqueue reports only its final queued/drop
 * disposition; later forwarding/closure uses that same receive ordinal. A forwarded
 * row means a queue disposition, not successful socket delivery or remote receipt.
 * No source buffer, payload, caller label, exception text or credential is retained.
 * Limits bound row count, parsing work per datagram, and complete serialized export;
 * maxBytes is not a JavaScript heap-size claim. Overflow retains an explicit prefix.
 */
export class SRTPacketDiagnostics {
  #limits;
  #events = [];
  #eventBytes = 2;
  #closed = false;
  #overflow = false;
  #observedEvents = 0;
  #observedDatagramBytes = 0;
  #omittedEvents = 0;
  #omittedDatagramBytes = 0;
  #invalidEvents = 0;
  constructor(options = {}) {
    assert(
      options !== null && typeof options === 'object' && !Array.isArray(options),
      'Invalid diagnostics options',
    );
    assert(
      Reflect.ownKeys(options).every((key) => Object.hasOwn(SRT_PACKET_DIAGNOSTIC_LIMITS, key)),
      'Unknown diagnostics option',
    );
    this.#limits = { ...SRT_PACKET_DIAGNOSTIC_LIMITS, ...options };
    for (const [key, maximum] of Object.entries(SRT_PACKET_DIAGNOSTIC_LIMITS))
      assert(
        Number.isSafeInteger(this.#limits[key]) &&
          this.#limits[key] > 0 &&
          this.#limits[key] <= maximum,
        'Invalid diagnostics limit',
      );
    assert(
      this.#limits.maxBytes >= ENVELOPE_RESERVE && this.#limits.maxDatagramBytes >= 16,
      'Insufficient diagnostics limit',
    );
  }
  observe(input) {
    if (this.#closed) return false;
    this.#observedEvents = add(this.#observedEvents, 1);
    let bytes = 0;
    try {
      const { data, direction, disposition, ordinal, at } = input;
      if (!(data instanceof Uint8Array)) throw new Error();
      const length = data.byteLength;
      if (!Number.isSafeInteger(length) || length < 0) throw new Error();
      bytes = length;
      this.#observedDatagramBytes = add(this.#observedDatagramBytes, bytes);
      if (
        !directions.has(direction) ||
        !dispositions.has(disposition) ||
        !Number.isSafeInteger(ordinal) ||
        ordinal <= 0 ||
        !Number.isFinite(at) ||
        at < 0 ||
        at > 1e12
      )
        throw new Error();
      if (!this.#overflow) {
        const buffer = Buffer.from(data.buffer, data.byteOffset, bytes);
        const row = {
          direction,
          disposition,
          ordinal,
          at,
          datagramBytes: bytes,
          packet: packetHeader(buffer, this.#limits),
        };
        const size = Buffer.byteLength(JSON.stringify(row)) + (this.#events.length ? 1 : 0);
        if (
          this.#events.length < this.#limits.maxEvents &&
          this.#eventBytes + size <= this.#limits.maxBytes - ENVELOPE_RESERVE
        ) {
          this.#events.push(row);
          this.#eventBytes += size;
          return true;
        }
        this.#overflow = true;
      }
    } catch {
      this.#invalidEvents = add(this.#invalidEvents, 1);
    }
    this.#omittedEvents = add(this.#omittedEvents, 1);
    this.#omittedDatagramBytes = add(this.#omittedDatagramBytes, bytes);
    return false;
  }
  close() {
    this.#closed = true;
  }
  snapshot() {
    return structuredClone({
      format: 'srt-packet-diagnostics-v1',
      diagnosticOnly: true,
      productionUpgradeAuthorized: false,
      closed: this.#closed,
      overflow: this.#overflow,
      invalid: this.#invalidEvents !== 0,
      limits: this.#limits,
      observedEvents: this.#observedEvents,
      observedDatagramBytes: this.#observedDatagramBytes,
      omittedEvents: this.#omittedEvents,
      omittedDatagramBytes: this.#omittedDatagramBytes,
      invalidEvents: this.#invalidEvents,
      events: this.#events,
    });
  }
}
