import assert from 'node:assert/strict';
import test from 'node:test';
import { parseTransport, psiCRC, PTS_MODULUS, moduloPTS } from '../transport-clock-parser.mjs';

function psi(hex) {
  const table = Buffer.from(hex, 'hex');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(psiCRC(table));
  return Buffer.concat([Buffer.from([0]), table, crc]);
}
function packet(pid, payload) {
  const out = Buffer.alloc(188, 0xff);
  out.set([0x47, 0x40 | (pid >> 8), pid & 255, 0x10]);
  payload.copy(out, 4);
  return out;
}
function pts(value) {
  return Buffer.from([
    0x21 | ((Math.floor(value / 2 ** 30) & 7) << 1),
    Math.floor(value / 2 ** 22) & 255,
    ((Math.floor(value / 2 ** 15) & 127) << 1) | 1,
    Math.floor(value / 128) & 255,
    ((value & 127) << 1) | 1,
  ]);
}
function fixture(value = PTS_MODULUS - 3) {
  return Buffer.concat([
    packet(0, psi('00b00d0001c100000001f000')),
    packet(4096, psi('02b0120001c10000e100f0001be100f000')),
    packet(256, Buffer.concat([Buffer.from('000001e00000808005', 'hex'), pts(value)])),
  ]);
}
test('MPEG-2 CRC matches its published check value', () => {
  assert.equal(psiCRC(Buffer.from('123456789')), 0x0376e6e7);
});
for (const value of [0, 1, 127, 128, 2 ** 22, 2 ** 30, PTS_MODULUS - 3, PTS_MODULUS - 1]) {
  test(`decodes unsigned 33-bit PTS ${value}`, () => {
    assert.equal(parseTransport(fixture(value)).video[0].pts, value);
  });
}
test('normalizes negative wrap epoch without discarding timestamp bits', () => {
  assert.equal(moduloPTS(-3), PTS_MODULUS - 3);
});
for (const [name, mutate, expected] of [
  ['sync', (b) => (b[0] = 0), /sync/],
  ['transport error indicator', (b) => (b[1] |= 0x80), /transport error/],
  ['scrambling', (b) => (b[3] |= 0x80), /Scrambled TS/],
  ['adaptation control', (b) => (b[3] = 0), /adaptation control/],
  [
    'adaptation length',
    (b) => {
      b[3] = 0x30;
      b[4] = 184;
    },
    /adaptation length/,
  ],
  [
    'truncated adaptation PCR',
    (b) => {
      b[3] = 0x30;
      b[4] = 1;
      b[5] = 0x10;
    },
    /adaptation fields/,
  ],
  [
    'PCR reserved bits',
    (b) => {
      b[3] = 0x30;
      b[4] = 7;
      b[5] = 0x10;
      b[10] = 0;
    },
    /PCR reserved bits/,
  ],
  [
    'PCR extension',
    (b) => {
      b[3] = 0x30;
      b[4] = 7;
      b[5] = 0x10;
      b[10] = 0xff;
      b[11] = 0xff;
    },
    /PCR extension/,
  ],
  ['PSI CRC', (b) => (b[12] ^= 1), /PSI CRC/],
  ['PES start', (b) => (b[380] = 1), /PES start/],
  ['PES stream id', (b) => (b[383] = 0xc0), /video PES stream id/],
  ['PES reserved bits', (b) => (b[386] = 0), /PES reserved bits/],
  ['PES flags', (b) => (b[387] = 0x40), /PES PTS flags/],
  ['PES header length', (b) => (b[388] = 183), /PES header length/],
  ['PES packet length', (b) => (b[385] = 1), /PES packet length/],
  ['PTS prefix', (b) => (b[389] = 0x11), /timestamp prefix/],
  ...[389, 391, 393].map((index) => [
    `PTS marker byte ${index}`,
    (b) => (b[index] &= 0xfe),
    /timestamp marker/,
  ]),
]) {
  test(`rejects malformed ${name}`, () => {
    const bytes = fixture();
    mutate(bytes);
    assert.throws(() => parseTransport(bytes), expected);
  });
}
test('rejects partial TS packet and empty input', () => {
  const bytes = fixture();
  assert.throws(() => parseTransport(bytes.subarray(0, bytes.length - 1)), /Truncated TS/);
  assert.throws(() => parseTransport(Buffer.alloc(0)), /byte bound/);
});
