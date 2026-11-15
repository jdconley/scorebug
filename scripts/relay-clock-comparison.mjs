import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { MAX_FRAMES, PTS_MODULUS, moduloPTS, parseTransport } from './transport-clock-parser.mjs';

// Identity at reader attachment, not frame receipt or a current-path lookup.
export function qualifyRelayReader({ path, publisherId, readerQuery, connection }) {
  const uuid = (value) =>
    typeof value === 'string' &&
    value.length === 36 &&
    /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value);
  assert.ok(
    typeof path === 'string' && path.length > 0 && path.length <= 128,
    'Invalid reader path',
  );
  assert.ok(uuid(publisherId), 'Invalid publisher identity');
  assert.ok(uuid(connection?.id), 'Invalid reader identity');
  assert.notEqual(connection.id, publisherId, 'Publisher cannot identify the reader');
  assert.ok(
    typeof readerQuery === 'string' &&
      readerQuery.length === 41 &&
      readerQuery.startsWith('sbr1=') &&
      uuid(readerQuery.slice(5)),
    'Invalid reader query marker',
  );
  assert.equal(connection.query, readerQuery, 'Reader query identity mismatch');
  assert.equal(connection.path, path, 'Reader path mismatch');
  assert.equal(connection.state, 'read', 'Connection is not reading');
  assert.equal(connection.scorebugReaderSource?.type, 'srtConn', 'Missing SRT reader source');
  assert.equal(
    connection.scorebugReaderSource?.id,
    publisherId,
    'Reader publisher identity mismatch',
  );
  return { readerId: connection.id, publisherId, path };
}

// Hash compressed picture bytes, excluding Annex B framing and the framing NALs
// MediaMTX can insert/remove. Length prefixes preserve slice boundaries/order.
function pictureHash(payload) {
  const starts = [];
  for (let i = 0; i + 2 < payload.length; i++) {
    if (payload[i] !== 0 || payload[i + 1] !== 0) continue;
    if (payload[i + 2] === 1) {
      starts.push({ at: i, body: i + 3 });
      i += 2;
    } else if (payload[i + 2] === 0 && payload[i + 3] === 1) {
      starts.push({ at: i, body: i + 4 });
      i += 3;
    }
  }
  assert.ok(starts.length > 0, 'Unsupported Annex B layout: no start code');
  assert.ok(
    payload.subarray(0, starts[0].at).every((byte) => byte === 0),
    'Unsupported Annex B leading bytes',
  );
  const hash = createHash('sha256');
  let vclCount = 0;
  for (let i = 0; i < starts.length; i++) {
    const start = starts[i].body;
    let end = starts[i + 1]?.at ?? payload.length;
    // Annex B trailing_zero_8bits are framing, including zeros adjacent to
    // the next start code. Emulation-prevention bytes within a NAL stay intact.
    while (end > start && payload[end - 1] === 0) end--;
    assert.ok(end - start >= 2, 'Truncated H264 NAL');
    const type = payload[start] & 31;
    assert.equal(payload[start] & 0x80, 0, 'Invalid H264 NAL forbidden bit');
    assert.ok(type >= 1 && type <= 9, 'Unsupported H264 NAL type');
    if (type > 5) continue;
    const length = Buffer.alloc(4);
    length.writeUInt32BE(end - start);
    hash.update(length).update(payload.subarray(start, end));
    vclCount++;
  }
  assert.ok(vclCount > 0, 'Missing VCL picture');
  return hash.digest('hex');
}

// Deliberately shares the finite fixture parser's byte/frame/PSI/header bounds.
// This is one picture per PES, not a general transport or H264 decoder. Final
// completeness of an unbounded PES also requires the independent decoder proof.
export function videoPayloadHashes(bytes) {
  const parsed = parseTransport(bytes);
  const hashes = [];
  let chunks = [],
    previousCounter;
  const finish = () => {
    if (!chunks.length) return;
    const pes = Buffer.concat(chunks);
    const declaredLength = pes.readUInt16BE(4);
    if (declaredLength) {
      assert.ok(pes.length >= 6 + declaredLength, 'Truncated PES payload');
      assert.equal(pes.length, 6 + declaredLength, 'Contradictory PES packet length');
    }
    hashes.push(pictureHash(pes.subarray(9 + pes[8])));
    chunks = [];
  };
  for (let offset = 0; offset < bytes.length; offset += 188) {
    const packet = bytes.subarray(offset, offset + 188);
    const pid = ((packet[1] & 31) << 8) | packet[2];
    if (pid !== parsed.videoPID) continue;
    const control = (packet[3] >> 4) & 3;
    const hasPayload = Boolean(control & 1);
    const counter = packet[3] & 15;
    if (previousCounter !== undefined) {
      assert.equal(
        counter,
        (previousCounter + (hasPayload ? 1 : 0)) % 16,
        'Video packet continuity error',
      );
    }
    previousCounter = counter;
    let at = 4;
    if (control & 2) {
      assert.ok(
        !packet[4] || !(packet[5] & 0x80),
        'Video packet continuity discontinuity unsupported',
      );
      at += 1 + packet[4];
    }
    if (!hasPayload) continue;
    if (packet[1] & 0x40) {
      finish();
      assert.equal(
        offset,
        parsed.video[hashes.length]?.packetOffset,
        'Unsupported video PES layout',
      );
    } else {
      assert.ok(chunks.length > 0, 'Truncated leading video PES');
    }
    chunks.push(packet.subarray(at));
  }
  finish();
  assert.equal(hashes.length, parsed.video.length, 'Video PES hash count mismatch');
  return hashes;
}

function validateFrames(frames, label) {
  assert.ok(
    Array.isArray(frames) && frames.length > 0 && frames.length <= MAX_FRAMES,
    `${label} frame bound`,
  );
  for (let i = 0; i < frames.length; i++) {
    const frame = frames[i];
    assert.ok(
      frame && Number.isInteger(frame.code) && frame.code >= 0 && frame.code <= 65535,
      `${label} invalid fixture code`,
    );
    assert.ok(
      typeof frame.payloadHash === 'string' && /^[a-fA-F0-9]{64}$/.test(frame.payloadHash),
      `${label} invalid payloadHash`,
    );
    assert.ok(
      Number.isInteger(frame.wirePTS) && frame.wirePTS >= 0 && frame.wirePTS < PTS_MODULUS,
      `${label} invalid wirePTS`,
    );
    assert.ok(Number.isSafeInteger(frame.decoderPTS), `${label} invalid decoderPTS`);
    assert.equal(
      moduloPTS(frame.decoderPTS),
      frame.wirePTS,
      `${label} decoderPTS contradicts wirePTS`,
    );
  }
}

// An acquired suffix is explicit evidence, not a missing-frame correction. The
// common signed modulo shift is diagnostic and never changes input timestamps.
export function compareRelayClock({ before, after }) {
  validateFrames(before, 'before');
  validateFrames(after, 'after');
  for (let i = 0; i < before.length; i++)
    assert.equal(before[i].code, i, 'before codes must be consecutive from zero');
  const firstCode = after[0].code;
  assert.ok(firstCode < before.length, 'after contains unknown fixture code');
  assert.equal(
    firstCode + after.length,
    before.length,
    'after must be a complete suffix through final code',
  );
  let offsetTicks;
  for (let i = 0; i < after.length; i++) {
    const frame = after[i];
    assert.equal(
      frame.code,
      firstCode + i,
      'after codes must be consecutive without gaps or repeats',
    );
    const source = before[frame.code];
    assert.equal(frame.payloadHash, source.payloadHash, `Payload mismatch at code ${frame.code}`);
    const shift = moduloPTS(frame.wirePTS - source.wirePTS + PTS_MODULUS / 2) - PTS_MODULUS / 2;
    if (offsetTicks === undefined) offsetTicks = shift;
    assert.equal(shift, offsetTicks, `Inconsistent timestamp shift at code ${frame.code}`);
  }
  return {
    matchedFrames: after.length,
    firstCode,
    lastCode: after.at(-1).code,
    acquisitionFrames: firstCode,
    offsetTicks,
    timestampsPreserved: offsetTicks === 0,
  };
}

// Private API identity and actual ingress origin must explain every acquired
// picture. Return only bounded scalar evidence, never connection query/credentials.
export function qualifyRelayOrigin({ path, source, connection, before, after }) {
  assert.ok(typeof path === 'string' && path.length > 0 && path.length <= 128, 'Invalid path');
  assert.equal(source?.type, 'srtConn', 'Expected SRT publisher source');
  assert.ok(
    typeof source?.id === 'string' &&
      /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(source.id),
    'Invalid publication identity',
  );
  assert.equal(connection?.id, source.id, 'Publication identity mismatch');
  assert.equal(connection?.path, path, 'Publication path mismatch');
  assert.equal(connection?.state, 'publish', 'Connection is not publishing');
  const clock = connection.scorebugTransportClock;
  assert.equal(clock?.convention, 'mpegts-ingress-origin-90k-v1', 'Unknown relay clock');
  assert.ok(
    typeof clock?.originPTS === 'string' && /^(?:0|[1-9][0-9]{0,9})$/.test(clock.originPTS),
    'Invalid relay origin',
  );
  const origin = Number(clock.originPTS);
  assert.ok(origin < PTS_MODULUS, 'Relay origin outside 33-bit wire range');
  const comparison = compareRelayClock({ before, after });
  assert.equal(
    moduloPTS(comparison.offsetTicks + origin),
    0,
    'Relay origin contradicts acquired picture timestamps',
  );
  return {
    publicationId: source.id,
    path,
    convention: clock.convention,
    originPTS: clock.originPTS,
    comparison,
  };
}
