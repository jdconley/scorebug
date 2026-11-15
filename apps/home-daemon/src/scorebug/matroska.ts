/**
 * Minimal live Matroska writer for one uncompressed RGBA video track.
 *
 * The worker feeds FFmpeg's `overlay` input through this stream because the
 * live graph runs with `-copyts`: the camera's transport PTS can start anywhere
 * in a 26.5 hour range, so a plain rawvideo/image input (timestamps from zero)
 * would never line up with the main video in `overlay`'s frame sync. Matroska
 * is the simplest FFmpeg-demuxable container in which the writer chooses each
 * frame's timestamp. Segment and Cluster use unknown sizes, as in live WebM.
 */

const TIMESTAMP_SCALE_NS = 1_000_000; // 1 ms ticks
const CLUSTER_SPAN_MS = 30_000; // SimpleBlock offsets are signed 16-bit

function vintSize(size: number): Buffer {
  for (let length = 1; length <= 8; length++) {
    // All-ones is reserved for "unknown"; stay one below each length's maximum.
    if (size < 2 ** (7 * length) - 1) {
      const bytes = Buffer.alloc(length);
      let value = size;
      for (let index = length - 1; index >= 0; index--) {
        bytes[index] = value % 256;
        value = Math.floor(value / 256);
      }
      bytes[0]! |= 1 << (8 - length);
      return bytes;
    }
  }
  throw new RangeError('ebml_size');
}

const UNKNOWN_SIZE = Buffer.from([0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);

function id(value: number): Buffer {
  const bytes: number[] = [];
  for (let remaining = value; remaining > 0; remaining = Math.floor(remaining / 256))
    bytes.unshift(remaining % 256);
  return Buffer.from(bytes);
}

function element(elementId: number, payload: Buffer): Buffer {
  return Buffer.concat([id(elementId), vintSize(payload.length), payload]);
}

function uint(elementId: number, value: number): Buffer {
  if (!Number.isSafeInteger(value) || value < 0) throw new RangeError('ebml_uint');
  const bytes: number[] = [];
  for (let remaining = value; remaining > 0; remaining = Math.floor(remaining / 256))
    bytes.unshift(remaining % 256);
  return element(elementId, Buffer.from(bytes.length ? bytes : [0]));
}

function text(elementId: number, value: string): Buffer {
  return element(elementId, Buffer.from(value, 'ascii'));
}

export function matroskaHeader(width: number, height: number): Buffer {
  const ebml = element(
    0x1a45dfa3,
    Buffer.concat([
      uint(0x4286, 1), // EBMLVersion
      uint(0x42f7, 1), // EBMLReadVersion
      uint(0x42f2, 4), // EBMLMaxIDLength
      uint(0x42f3, 8), // EBMLMaxSizeLength
      text(0x4282, 'matroska'),
      uint(0x4287, 4), // DocTypeVersion
      uint(0x4285, 2), // DocTypeReadVersion
    ]),
  );
  const info = element(
    0x1549a966,
    Buffer.concat([
      uint(0x2ad7b1, TIMESTAMP_SCALE_NS),
      text(0x4d80, 'scorebug'),
      text(0x5741, 'scorebug'),
    ]),
  );
  const tracks = element(
    0x1654ae6b,
    element(
      0xae,
      Buffer.concat([
        uint(0xd7, 1), // TrackNumber
        uint(0x73c5, 1), // TrackUID
        uint(0x83, 1), // TrackType: video
        uint(0x9c, 0), // FlagLacing
        text(0x86, 'V_UNCOMPRESSED'),
        element(
          0xe0,
          Buffer.concat([
            uint(0xb0, width),
            uint(0xba, height),
            element(0x2eb524, Buffer.from('RGBA', 'ascii')), // ColourSpace FourCC
          ]),
        ),
      ]),
    ),
  );
  return Buffer.concat([ebml, id(0x18538067), UNKNOWN_SIZE, info, tracks]);
}

/** Stateful framing: one call per frame, timestamps strictly increasing in ms. */
export class MatroskaFramer {
  private cluster: number | undefined;
  private last: number | undefined;

  /** Returns the bytes for one keyframe; `timestampMs` must exceed the previous one. */
  frame(timestampMs: number, rgba: Buffer): Buffer[] {
    if (!Number.isSafeInteger(timestampMs) || timestampMs < 0)
      throw new RangeError('matroska_timestamp');
    if (this.last !== undefined && timestampMs <= this.last)
      throw new RangeError('matroska_timestamp_order');
    this.last = timestampMs;
    const parts: Buffer[] = [];
    if (this.cluster === undefined || timestampMs - this.cluster >= CLUSTER_SPAN_MS) {
      this.cluster = timestampMs;
      parts.push(id(0x1f43b675), UNKNOWN_SIZE, uint(0xe7, timestampMs));
    }
    const header = Buffer.alloc(4);
    header[0] = 0x81; // track 1 as a 1-byte vint
    header.writeInt16BE(timestampMs - this.cluster, 1);
    header[3] = 0x80; // keyframe
    parts.push(id(0xa3), vintSize(header.length + rgba.length), header, rgba);
    return parts;
  }
}
