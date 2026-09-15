import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import {
  compareRelayClock,
  videoPayloadHashes,
  qualifyRelayOrigin,
} from '../relay-clock-comparison.mjs';
import { psiCRC, PTS_MODULUS, moduloPTS } from '../transport-clock-parser.mjs';

const digest = (code) => createHash('sha256').update(`picture ${code}`).digest('hex');
const records = (count = 4, initialPTS = 9000) =>
  Array.from({ length: count }, (_, code) => ({
    code,
    wirePTS: moduloPTS(initialPTS + code * 3000),
    decoderPTS: initialPTS + code * 3000,
    payloadHash: digest(code),
  }));
const shifted = (before, delta) =>
  before.map((frame) => ({
    ...frame,
    wirePTS: moduloPTS(frame.wirePTS + delta),
    decoderPTS: frame.decoderPTS + delta,
  }));

test('reports timestamp preservation for every retained picture', () => {
  const before = records();
  assert.deepEqual(compareRelayClock({ before, after: structuredClone(before) }), {
    matchedFrames: 4,
    firstCode: 0,
    lastCode: 3,
    acquisitionFrames: 0,
    offsetTicks: 0,
    timestampsPreserved: true,
  });
});
for (const delta of [-9000, 10919, -(PTS_MODULUS / 2), PTS_MODULUS / 2 - 1]) {
  test(`reports signed constant shift ${delta} without rewriting evidence`, () => {
    const before = records(4, PTS_MODULUS - 4000);
    const after = shifted(before, delta).slice(2);
    const input = { before, after };
    const untouched = structuredClone(input);
    assert.deepEqual(compareRelayClock(input), {
      matchedFrames: 2,
      firstCode: 2,
      lastCode: 3,
      acquisitionFrames: 2,
      offsetTicks: delta,
      timestampsPreserved: false,
    });
    assert.deepEqual(input, untouched);
  });
}
test('accepts negative decoder epoch only when it represents the raw wire timestamp', () => {
  const before = records(2, -3000);
  assert.equal(compareRelayClock({ before, after: before }).timestampsPreserved, true);
});
test('accepts the full 300-frame bound', () => {
  const before = records(300);
  assert.equal(compareRelayClock({ before, after: before }).matchedFrames, 300);
});

for (const [name, mutate, expected] of [
  [
    'empty source',
    (x) => {
      x.before = [];
    },
    /before.*bound/,
  ],
  [
    'empty receiver',
    (x) => {
      x.after = [];
    },
    /after.*bound/,
  ],
  [
    'source bound',
    (x) => {
      x.before = records(301);
    },
    /before.*bound/,
  ],
  [
    'receiver bound',
    (x) => {
      x.after = records(301);
    },
    /after.*bound/,
  ],
  ['source starts late', (x) => x.before.shift(), /before.*consecutive/],
  ['source gap', (x) => x.before.splice(1, 1), /before.*consecutive/],
  [
    'source duplicate',
    (x) => {
      x.before[1] = x.before[0];
    },
    /before.*consecutive/,
  ],
  [
    'unknown receiver frame',
    (x) => {
      x.after[3].code = 8;
    },
    /after.*(unknown|suffix|consecutive)/,
  ],
  ['receiver gap', (x) => x.after.splice(1, 1), /after.*(suffix|consecutive)/],
  [
    'receiver repeated frame',
    (x) => {
      x.after[1] = x.after[0];
    },
    /after.*(suffix|consecutive)/,
  ],
  ['receiver missing tail', (x) => x.after.pop(), /after.*(final|suffix)/],
  [
    'receiver reordered',
    (x) => {
      [x.after[1], x.after[2]] = [x.after[2], x.after[1]];
    },
    /after.*(suffix|consecutive)/,
  ],
  [
    'invalid code',
    (x) => {
      x.after[0].code = 65536;
    },
    /code/,
  ],
  [
    'fractional code',
    (x) => {
      x.after[0].code = 0.5;
    },
    /code/,
  ],
  [
    'missing digest',
    (x) => {
      delete x.before[0].payloadHash;
    },
    /payloadHash/,
  ],
  [
    'short digest',
    (x) => {
      x.after[0].payloadHash = 'abcd';
    },
    /payloadHash/,
  ],
  [
    'nonhex digest',
    (x) => {
      x.after[0].payloadHash = 'z'.repeat(64);
    },
    /payloadHash/,
  ],
  [
    'different picture',
    (x) => {
      x.after[0].payloadHash = digest(99);
    },
    /payload.*(changed|mismatch)/i,
  ],
  [
    'inconsistent timestamp shift',
    (x) => {
      x.after[1].wirePTS++;
      x.after[1].decoderPTS++;
    },
    /shift/,
  ],
  [
    'negative wire timestamp',
    (x) => {
      x.before[0].wirePTS = -1;
    },
    /wirePTS/,
  ],
  [
    'overflow wire timestamp',
    (x) => {
      x.after[0].wirePTS = PTS_MODULUS;
    },
    /wirePTS/,
  ],
  [
    'fractional wire timestamp',
    (x) => {
      x.after[0].wirePTS += 0.5;
    },
    /wirePTS/,
  ],
  [
    'missing source decoder evidence',
    (x) => {
      delete x.before[0].decoderPTS;
    },
    /decoderPTS/,
  ],
  [
    'missing receiver decoder evidence',
    (x) => {
      delete x.after[0].decoderPTS;
    },
    /decoderPTS/,
  ],
  [
    'unsafe decoder timestamp',
    (x) => {
      x.after[0].decoderPTS = 2 ** 53;
    },
    /decoderPTS/,
  ],
  [
    'decoder contradicts raw packet',
    (x) => {
      x.after[0].decoderPTS++;
    },
    /decoderPTS/,
  ],
]) {
  test(`rejects ${name}`, () => {
    const before = records();
    const input = { before, after: structuredClone(before) };
    mutate(input);
    assert.throws(() => compareRelayClock(input), expected);
  });
}

function psi(hex) {
  const table = Buffer.from(hex, 'hex');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(psiCRC(table));
  return Buffer.concat([Buffer.from([0]), table, crc]);
}
function packet(pid, payload, start = true, counter = 0) {
  assert.ok(payload.length <= 184);
  const out = Buffer.alloc(188, 0xff);
  const adaptation = 184 - payload.length;
  out.set([0x47, (start ? 0x40 : 0) | (pid >> 8), pid & 255, (adaptation ? 0x30 : 0x10) | counter]);
  if (adaptation) {
    out[4] = adaptation - 1;
    if (adaptation > 1) out[5] = 0;
  }
  payload.copy(out, 4 + adaptation);
  return out;
}
const annex = (...units) =>
  Buffer.concat(units.map((unit) => Buffer.concat([Buffer.from([0, 0, 0, 1]), Buffer.from(unit)])));
const picture = [0x65, 0x88, 0x84, 0x21];
function pes(payload, { finite = false, pts = 0 } = {}) {
  assert.ok(pts < 128);
  const header = Buffer.from([0, 0, 1, 0xe0, 0, 0, 0x80, 0x80, 5, 0x21, 0, 1, 0, pts * 2 + 1]);
  if (finite) header.writeUInt16BE(8 + payload.length, 4);
  return Buffer.concat([header, payload]);
}
function fixture(payloads = [annex(picture)], options) {
  const packets = [
    packet(0, psi('00b00d0001c100000001f000')),
    packet(4096, psi('02b0120001c10000e100f0001be100f000')),
  ];
  let counter = 0;
  for (const payload of payloads) {
    const body = pes(payload, options);
    for (let at = 0; at < body.length; at += 184)
      packets.push(packet(256, body.subarray(at, at + 184), at === 0, counter++ % 16));
  }
  return Buffer.concat(packets);
}
function expectedHash(...units) {
  const hash = createHash('sha256');
  for (const unit of units) {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(unit.length);
    hash.update(length).update(Buffer.from(unit));
  }
  return hash.digest('hex');
}
test('hashes each PES picture in parser order with length-delimited VCL NALs', () => {
  const slice = [0x41, 0x9a, 0x21];
  assert.deepEqual(videoPayloadHashes(fixture([annex(picture, slice), annex(slice)])), [
    expectedHash(picture, slice),
    expectedHash(slice),
  ]);
});
test('ignores timestamp, start-code width, and AUD/SPS/PPS/SEI framing differences', () => {
  const framed = annex([9, 0xf0], [7, 0x42], [8, 0xce], [6, 0x80], picture);
  const short = Buffer.from([0, 0, 1, ...picture]);
  assert.deepEqual(
    videoPayloadHashes(fixture([framed])),
    videoPayloadHashes(fixture([short], { pts: 99, finite: true })),
  );
  assert.deepEqual(videoPayloadHashes(fixture([framed])), [expectedHash(picture)]);
});
test('reassembles split video PES and wraps packet continuity counter', () => {
  const large = [0x65, ...Array(3500).fill(0x88)];
  assert.deepEqual(videoPayloadHashes(fixture([annex(large)], { finite: true })), [
    expectedHash(large),
  ]);
});
test('distinguishes changed compressed picture bytes', () => {
  assert.notDeepEqual(
    videoPayloadHashes(fixture()),
    videoPayloadHashes(fixture([annex([0x65, 0x88, 0x84, 0x22])])),
  );
});

for (const [name, payload, expected] of [
  ['missing VCL', annex([9, 0xf0], [7, 0x42]), /VCL/],
  ['empty picture', Buffer.alloc(0), /VCL|Annex B/],
  ['AVCC layout', Buffer.from([0, 0, 0, 4, ...picture]), /Annex B/],
  ['leading garbage', Buffer.concat([Buffer.from([42]), annex(picture)]), /Annex B/],
  ['forbidden NAL bit', annex([0xe5, 0x88]), /NAL/],
  ['unsupported NAL type', annex([0x74, 0x88]), /NAL/],
  ['header-only VCL', annex([0x65]), /Truncated.*NAL/],
  ['empty trailing NAL', Buffer.concat([annex(picture), Buffer.from([0, 0, 1])]), /Truncated.*NAL/],
]) {
  test(`rejects ${name}`, () =>
    assert.throws(() => videoPayloadHashes(fixture([payload])), expected));
}
for (const [name, mutate, expected] of [
  [
    'malformed TS sync',
    (bytes) => {
      bytes[0] = 0;
    },
    /sync/,
  ],
  [
    'malformed PAT CRC',
    (bytes) => {
      bytes[187] ^= 1;
    },
    /CRC/,
  ],
  [
    'packet loss',
    (bytes) => {
      bytes[3 * 188 + 3] = 0x13;
    },
    /continuity/,
  ],
  [
    'packet duplicate',
    (bytes) => {
      bytes[3 * 188 + 3] = 0x10;
    },
    /continuity/,
  ],
  [
    'PES length longer than bytes',
    (bytes) => {
      bytes.writeUInt16BE(5000, 2 * 188 + 8);
    },
    /Truncated PES/,
  ],
  [
    'PES length shorter than bytes',
    (bytes) => {
      bytes.writeUInt16BE(20, 2 * 188 + 8);
    },
    /PES.*length/,
  ],
]) {
  test(`rejects ${name}`, () => {
    const bytes = fixture([annex([0x65, ...Array(400).fill(0x88)])], { finite: true });
    mutate(bytes);
    assert.throws(() => videoPayloadHashes(bytes), expected);
  });
}
test('retains existing finite TS and frame bounds', () => {
  assert.throws(() => videoPayloadHashes(Buffer.alloc(0)), /byte bound/);
  assert.throws(() => videoPayloadHashes(Buffer.alloc(32 * 1024 * 1024 + 1)), /byte bound/);
  assert.throws(() => videoPayloadHashes(fixture().subarray(0, -1)), /Truncated TS/);
  assert.throws(() => videoPayloadHashes(fixture(Array(301).fill(annex(picture)))), /frame bound/);
});

// The API mapping must explain the same complete picture comparison, not endpoints.
const publicationID = 'd6c217a3-27c5-44ea-a55e-3b951c67981f';
const originFixture = (origin = 9000) => {
  const before = records(5, PTS_MODULUS - 4000);
  return {
    path: 'fixture',
    source: { type: 'srtConn', id: publicationID },
    connection: {
      id: publicationID,
      state: 'publish',
      path: 'fixture',
      query: 'not-for-evidence',
      scorebugTransportClock: {
        convention: 'mpegts-ingress-origin-90k-v1',
        originPTS: String(origin),
      },
    },
    before,
    after: shifted(before, -origin).slice(2),
  };
};
for (const origin of [0, 9000, 10919, PTS_MODULUS / 2, PTS_MODULUS - 1]) {
  test(`qualifies actual relay origin ${origin} against every acquired picture`, () => {
    const input = originFixture(origin);
    const saved = structuredClone(input);
    const result = qualifyRelayOrigin(input);
    assert.deepEqual(result, {
      publicationId: publicationID,
      path: 'fixture',
      convention: 'mpegts-ingress-origin-90k-v1',
      originPTS: String(origin),
      comparison: compareRelayClock(input),
    });
    assert.deepEqual(input, saved);
    assert.ok(!JSON.stringify(result).includes('not-for-evidence'));
  });
}
for (const origin of [
  undefined,
  null,
  9000,
  '',
  '-1',
  '01',
  '1.0',
  '1e3',
  '+1',
  ' 1',
  '1 ',
  String(PTS_MODULUS),
  '999999999999999999999',
  {},
  [],
]) {
  test(`rejects malformed or out-of-range relay origin ${JSON.stringify(origin)}`, () => {
    const input = originFixture();
    input.connection.scorebugTransportClock.originPTS = origin;
    assert.throws(() => qualifyRelayOrigin(input));
  });
}
for (const [name, mutate] of [
  [
    'missing source',
    (x) => {
      x.source = undefined;
    },
  ],
  [
    'wrong source protocol',
    (x) => {
      x.source.type = 'rtmpConn';
    },
  ],
  [
    'invalid publication id',
    (x) => {
      x.source.id = 'unknown';
      x.connection.id = 'unknown';
    },
  ],
  [
    'different publication',
    (x) => {
      x.connection.id = 'd1e71c84-e637-4215-b5d2-3840e5a6fe40';
    },
  ],
  [
    'missing connection',
    (x) => {
      x.connection = undefined;
    },
  ],
  [
    'reader connection',
    (x) => {
      x.connection.state = 'read';
    },
  ],
  [
    'idle connection',
    (x) => {
      x.connection.state = 'idle';
    },
  ],
  [
    'different path',
    (x) => {
      x.connection.path = 'other';
    },
  ],
  [
    'empty expected path',
    (x) => {
      x.path = '';
      x.connection.path = '';
    },
  ],
  [
    'missing mapping',
    (x) => {
      delete x.connection.scorebugTransportClock;
    },
  ],
  [
    'null mapping',
    (x) => {
      x.connection.scorebugTransportClock = null;
    },
  ],
  [
    'unknown convention',
    (x) => {
      x.connection.scorebugTransportClock.convention = 'future';
    },
  ],
  [
    'wrong origin',
    (x) => {
      x.connection.scorebugTransportClock.originPTS = '10919';
    },
  ],
  [
    'middle picture mismatch',
    (x) => {
      x.after[1].payloadHash = digest(99);
    },
  ],
  [
    'middle timestamp mismatch',
    (x) => {
      x.after[1].wirePTS += 1;
      x.after[1].decoderPTS += 1;
    },
  ],
]) {
  test(`rejects relay origin evidence with ${name}`, () => {
    const input = originFixture();
    mutate(input);
    assert.throws(() => qualifyRelayOrigin(input));
  });
}
