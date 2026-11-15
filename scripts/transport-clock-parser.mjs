import assert from 'node:assert/strict';

export const PTS_MODULUS = 2 ** 33;
export const MAX_TS_BYTES = 32 * 1024 * 1024;
export const MAX_FRAMES = 300;
export const moduloPTS = (pts) => ((pts % PTS_MODULUS) + PTS_MODULUS) % PTS_MODULUS;

export function psiCRC(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte << 24;
    for (let bit = 0; bit < 8; bit++)
      crc = ((crc << 1) ^ (crc & 0x80000000 ? 0x04c11db7 : 0)) >>> 0;
  }
  return crc;
}

function timestamp(bytes, prefix) {
  assert.equal(bytes.length, 5, 'Truncated PES timestamp');
  assert.equal(bytes[0] >> 4, prefix, 'Invalid PES timestamp prefix');
  assert.ok(bytes[0] & 1 && bytes[2] & 1 && bytes[4] & 1, 'Invalid PES timestamp marker');
  return (
    (bytes[0] & 14) * 2 ** 29 +
    bytes[1] * 2 ** 22 +
    (bytes[2] >> 1) * 2 ** 15 +
    bytes[3] * 128 +
    (bytes[4] >> 1)
  );
}

// Deliberately finite fixture parser, not a general MPEG-TS demuxer. PSI and PES
// headers must fit their first packet; unsupported layouts fail explicitly.
export function parseTransport(bytes) {
  assert.ok(bytes.length > 0 && bytes.length <= MAX_TS_BYTES, 'TS byte bound');
  assert.equal(bytes.length % 188, 0, 'Truncated TS packet');
  const patOffsets = [],
    video = [];
  let pmtPID, videoPID;
  for (let offset = 0; offset < bytes.length; offset += 188) {
    const packet = bytes.subarray(offset, offset + 188);
    assert.equal(packet[0], 0x47, 'Invalid TS sync');
    assert.equal(packet[1] & 0x80, 0, 'TS transport error');
    assert.equal(packet[3] & 0xc0, 0, 'Scrambled TS unsupported');
    const pid = ((packet[1] & 31) << 8) | packet[2];
    const start = Boolean(packet[1] & 0x40);
    const control = (packet[3] >> 4) & 3;
    assert.notEqual(control, 0, 'Invalid adaptation control');
    let at = 4,
      randomAccess = false;
    if (control & 2) {
      const length = packet[at++];
      const end = at + length;
      assert.ok(
        end <= 188 && (control === 2 ? end === 188 : end < 188),
        'Invalid adaptation length',
      );
      if (length) {
        const flags = packet[at++];
        randomAccess = Boolean(flags & 0x40);
        for (const mask of [0x10, 0x08]) {
          if (!(flags & mask)) continue;
          assert.ok(at + 6 <= end, 'Truncated adaptation fields');
          assert.equal(packet[at + 4] & 0x7e, 0x7e, 'Invalid PCR reserved bits');
          assert.ok((((packet[at + 4] & 1) << 8) | packet[at + 5]) < 300, 'Invalid PCR extension');
          at += 6;
        }
        if (flags & 0x04) at++;
        if (flags & 0x02) {
          assert.ok(at < end, 'Truncated adaptation private data');
          at += 1 + packet[at];
        }
        if (flags & 0x01) {
          assert.ok(at < end, 'Truncated adaptation extension');
          at += 1 + packet[at];
        }
        assert.ok(at <= end, 'Truncated adaptation fields');
      }
      at = end;
    }
    if (!(control & 1) || !start) continue;
    const payload = packet.subarray(at);
    if (pid === 0 || pid === pmtPID) {
      assert.ok(payload.length > 1 + payload[0], 'Invalid PSI pointer');
      const section = payload.subarray(1 + payload[0]);
      assert.ok(section.length >= 3, 'Truncated PSI header');
      const length = ((section[1] & 15) << 8) | section[2];
      assert.ok(length >= 9 && 3 + length <= section.length, 'Unsupported split or malformed PSI');
      const table = section.subarray(0, 3 + length);
      assert.equal(psiCRC(table), 0, 'Invalid PSI CRC');
      assert.ok(table[5] & 1, 'Non-current PSI');
      if (pid === 0) {
        assert.equal(table[0], 0, 'Invalid PAT table');
        assert.equal((table.length - 12) % 4, 0, 'Invalid PAT programs');
        const programs = [];
        for (let i = 8; i < table.length - 4; i += 4)
          if (table.readUInt16BE(i)) programs.push(table.readUInt16BE(i + 2) & 0x1fff);
        assert.equal(programs.length, 1, 'Expected one PAT program');
        if (pmtPID !== undefined) assert.equal(programs[0], pmtPID, 'PMT PID changed');
        pmtPID = programs[0];
        patOffsets.push(offset);
      } else {
        assert.equal(table[0], 2, 'Invalid PMT table');
        assert.ok(table.length >= 16, 'Truncated PMT');
        let i = 12 + (table.readUInt16BE(10) & 0x0fff);
        assert.ok(i <= table.length - 4, 'Invalid PMT program descriptors');
        const videos = [];
        while (i < table.length - 4) {
          assert.ok(i + 5 <= table.length - 4, 'Truncated PMT stream');
          if (table[i] === 0x1b) videos.push(table.readUInt16BE(i + 1) & 0x1fff);
          i += 5 + (table.readUInt16BE(i + 3) & 0x0fff);
          assert.ok(i <= table.length - 4, 'Invalid PMT descriptors');
        }
        assert.equal(videos.length, 1, 'Expected one H264 stream');
        if (videoPID !== undefined) assert.equal(videos[0], videoPID, 'Video PID changed');
        videoPID = videos[0];
      }
    } else if (pid === videoPID) {
      assert.ok(payload.length >= 14, 'Truncated PES header');
      assert.equal(payload.readUIntBE(0, 3), 1, 'Invalid PES start');
      assert.ok(payload[3] >= 0xe0 && payload[3] <= 0xef, 'Invalid video PES stream id');
      assert.equal(payload[6] & 0xc0, 0x80, 'Invalid PES reserved bits');
      assert.equal(payload[6] & 0x30, 0, 'Scrambled PES unsupported');
      const flags = payload[7] >> 6;
      assert.ok(flags === 2 || flags === 3, 'Missing or invalid PES PTS flags');
      assert.ok(
        payload[8] >= (flags === 3 ? 10 : 5) && 9 + payload[8] <= payload.length,
        'Invalid or split PES header length',
      );
      const length = payload.readUInt16BE(4);
      assert.ok(length === 0 || length >= 3 + payload[8], 'Invalid PES packet length');
      const pts = timestamp(payload.subarray(9, 14), flags);
      if (flags === 3) timestamp(payload.subarray(14, 19), 1);
      assert.ok(video.length < MAX_FRAMES, 'Video PES frame bound');
      video.push({ pts, packetOffset: offset, randomAccess });
    }
  }
  assert.ok(video.length > 0 && videoPID !== undefined, 'No video PES');
  return { videoPID, pmtPID, patOffsets, video };
}
