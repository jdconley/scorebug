import assert from 'node:assert/strict';
import test from 'node:test';
const module = await import('../srt-packet-diagnostics.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
function observer(options) {
  assert.equal(typeof module.SRTPacketDiagnostics, 'function');
  return new module.SRTPacketDiagnostics(options);
}
function dataPacket(
  payload = Buffer.alloc(0),
  { sequence = 0x7fffffff, message = 0x3ffffff, flags = 0xe4000000 } = {},
) {
  const data = Buffer.alloc(16 + payload.length);
  data.writeUInt32BE(sequence, 0);
  data.writeUInt32BE((flags | message) >>> 0, 4);
  data.writeUInt32BE(0xffffffff, 8);
  data.writeUInt32BE(0xfedcba98, 12);
  payload.copy(data, 16);
  return data;
}
function control(type, words = [], extra = 0) {
  const data = Buffer.alloc(16 + words.length * 4);
  data.writeUInt32BE((0x80000000 | (type << 16)) >>> 0, 0);
  data.writeUInt32BE(extra, 4);
  data.writeUInt32BE(17, 8);
  data.writeUInt32BE(23, 12);
  words.forEach((word, i) => data.writeUInt32BE(word, 16 + i * 4));
  return data;
}
function event(data, patch = {}) {
  return { direction: 'forward', disposition: 'queued', ordinal: 1, at: 2.25, data, ...patch };
}
function parse(data, options) {
  const o = observer(options);
  assert.equal(o.observe(event(data)), true);
  return o.snapshot().events[0].packet;
}
function timestamp(value, prefix) {
  const b = Buffer.alloc(5);
  b[0] = (prefix << 4) | (Math.floor(value / 2 ** 30) << 1) | 1;
  b[1] = Math.floor(value / 2 ** 22) & 255;
  b[2] = ((Math.floor(value / 2 ** 15) & 127) << 1) | 1;
  b[3] = Math.floor(value / 2 ** 7) & 255;
  b[4] = ((value & 127) << 1) | 1;
  return b;
}
function tsPacket() {
  const ts = Buffer.alloc(188, 0xff);
  ts[0] = 0x47;
  ts[1] = 0x41;
  ts[2] = 0x00;
  ts[3] = 0x3f;
  ts[4] = 1;
  ts[5] = 0xc0;
  Buffer.from([0, 0, 1, 0xe0, 0, 0, 0x80, 0xc0, 10]).copy(ts, 6);
  timestamp(2 ** 33 - 1, 3).copy(ts, 15);
  timestamp(90000, 1).copy(ts, 20);
  return ts;
}
test('retains only exact scalar SRT data header fields, including unsigned wrap values', () => {
  const p = parse(dataPacket(Buffer.from('MEDIA_SECRET')));
  assert.deepEqual(p, {
    kind: 'data',
    sequence: 0x7fffffff,
    messageNumber: 0x3ffffff,
    boundary: 'single',
    inOrder: true,
    encryption: 0,
    retransmitted: true,
    timestamp: 0xffffffff,
    destinationSocketID: 0xfedcba98,
    transportStream: { status: 'unaligned' },
  });
  const wrapped = parse(dataPacket(Buffer.alloc(0), { sequence: 0, message: 0, flags: 0 }));
  assert.equal(wrapped.sequence, 0);
  assert.equal(wrapped.messageNumber, 0);
  assert.equal(wrapped.boundary, 'middle');
  assert.equal(wrapped.retransmitted, false);
});
for (const [bits, boundary] of [
  [0, 'middle'],
  [1, 'last'],
  [2, 'first'],
  [3, 'single'],
])
  test(`decodes message boundary ${boundary}`, () => {
    assert.equal(parse(dataPacket(Buffer.alloc(0), { flags: bits * 2 ** 30 })).boundary, boundary);
  });
test('ACK retains first unacknowledged sequence and acknowledgment number', () => {
  assert.deepEqual(parse(control(2, [0x7fffffff], 42)), {
    kind: 'control',
    controlType: 2,
    subtype: 0,
    timestamp: 17,
    destinationSocketID: 23,
    acknowledgmentNumber: 42,
    firstUnacknowledgedSequence: 0x7fffffff,
  });
});
test('NAK preserves inclusive ranges without expanding or rejecting sequence wrap', () => {
  assert.deepEqual(parse(control(3, [4, 0xfffffffe, 1, 9])).lossRanges, [
    [4, 4],
    [0x7ffffffe, 1],
    [9, 9],
  ]);
});
test('NAK truncation is explicit and later malformed ranges cannot be hidden by limit', () => {
  const p = parse(control(3, [1, 2, 3]), { maxControlRanges: 2 });
  assert.deepEqual(p.lossRanges, [
    [1, 1],
    [2, 2],
  ]);
  assert.equal(p.omittedRanges, 1);
  const bad = parse(control(3, [1, 2, 0x80000003]), { maxControlRanges: 1 });
  assert.equal(bad.malformed, 'lossRanges');
  assert.equal(bad.lossRanges, undefined);
});
test('DROPREQ retains message and inclusive sequence range', () => {
  const p = parse(control(7, [0x7fffffff, 0], 0x3ffffff));
  assert.equal(p.messageNumber, 0x3ffffff);
  assert.deepEqual(p.dropRange, [0x7fffffff, 0]);
});
for (const [name, data] of [
  ['short', Buffer.alloc(15)],
  ['shortAck', control(2)],
  ['badAck', control(2, [0x80000000])],
  ['shortDrop', control(7, [1])],
  ['badNak', control(3, [0x80000001, 0x80000002])],
])
  test(`malformed ${name} remains diagnostic and does not throw`, () => {
    const p = parse(data);
    assert(p.kind === 'malformed' || p.malformed);
  });
test('handshake, extension and unknown control bodies are never retained', () => {
  const secret = Buffer.from('streamid=#!::r=private,u=user,password=HIDDEN');
  for (const type of [0, 0x7fff, 0x4321]) {
    const header = control(type);
    const p = parse(Buffer.concat([header, secret]));
    assert.deepEqual(Object.keys(p).sort(), [
      'controlType',
      'destinationSocketID',
      'kind',
      'subtype',
      'timestamp',
    ]);
    assert(!JSON.stringify(p).includes('HIDDEN'));
  }
});
test('aligned MPEG-TS exposes PID/CC, adaptation flags and local 33-bit PTS/DTS only', () => {
  const ts = tsPacket(),
    p = parse(dataPacket(ts));
  assert.equal(p.transportStream.status, 'parsed');
  assert.deepEqual(p.transportStream.packets, [
    {
      pid: 256,
      continuityCounter: 15,
      payloadUnitStart: true,
      transportError: false,
      scrambling: 0,
      adaptationControl: 3,
      discontinuity: true,
      randomAccess: true,
      pes: { streamID: 224, status: 'parsed', pts: 2 ** 33 - 1, dts: 90000 },
    },
  ]);
});
test('MPEG-TS continuity wraps and adjacent PID headers stay separate', () => {
  const a = tsPacket(),
    b = tsPacket();
  b[1] = 1;
  b[2] = 1;
  b[3] = 0x10;
  const packets = parse(dataPacket(Buffer.concat([a, b]))).transportStream.packets;
  assert.deepEqual(
    packets.map((p) => [p.pid, p.continuityCounter, p.payloadUnitStart]),
    [
      [256, 15, true],
      [257, 0, false],
    ],
  );
});
test('unaligned or partially invalid TS is not salvaged into a valid packet subset', () => {
  const valid = tsPacket(),
    bad = tsPacket();
  bad[0] = 0;
  assert.deepEqual(parse(dataPacket(Buffer.concat([valid, bad]))).transportStream, {
    status: 'malformed',
  });
  assert.deepEqual(parse(dataPacket(Buffer.concat([valid, Buffer.from([0])]))).transportStream, {
    status: 'unaligned',
  });
  const tooLong = tsPacket();
  tooLong[4] = 184;
  assert.deepEqual(parse(dataPacket(tooLong)).transportStream, { status: 'malformed' });
});
test('malformed PES marker bits and truncated headers never produce PTS/DTS', () => {
  const invalid = tsPacket();
  invalid[15] &= 0xfe;
  const p = parse(dataPacket(invalid)).transportStream.packets[0].pes;
  assert.deepEqual(p, { streamID: 224, status: 'malformed' });
  const partial = tsPacket();
  partial[14] = 184;
  assert.deepEqual(parse(dataPacket(partial)).transportStream.packets[0].pes, {
    streamID: 224,
    status: 'incomplete',
  });
});
for (const encryption of [1, 2, 3])
  test(`encrypted SRT key flag ${encryption} skips TS parsing`, () => {
    const p = parse(dataPacket(tsPacket(), { flags: (encryption << 27) >>> 0 }));
    assert.equal(p.encryption, encryption);
    assert.deepEqual(p.transportStream, { status: 'encrypted' });
  });
test('TS scrambling or transport error keeps header diagnostics without PES interpretation', () => {
  for (const field of ['scrambled', 'error']) {
    const ts = tsPacket();
    if (field === 'scrambled') ts[3] |= 0x80;
    else ts[1] |= 0x80;
    assert.equal(parse(dataPacket(ts)).transportStream.packets[0].pes, undefined);
  }
});
test('direction, original receive ordinal and final queue dispositions remain bound', () => {
  const o = observer(),
    data = dataPacket();
  const dispositions = [
    'queued',
    'injectedDrop',
    'overflowDrop',
    'oversizeDrop',
    'forwarded',
    'closeDiscard',
  ];
  dispositions.forEach((disposition, i) =>
    assert(
      o.observe(
        event(data, {
          direction: i % 2 ? 'reverse' : 'forward',
          disposition,
          ordinal: i + 1,
          at: 10 + i,
        }),
      ),
    ),
  );
  assert.deepEqual(
    o
      .snapshot()
      .events.map(({ direction, disposition, ordinal, at }) => [
        direction,
        disposition,
        ordinal,
        at,
      ]),
    dispositions.map((d, i) => [i % 2 ? 'reverse' : 'forward', d, i + 1, 10 + i]),
  );
  assert.equal(o.observe(event(data, { disposition: 'received' })), false);
  assert.equal(o.snapshot().invalidEvents, 1);
});
test('buffers and snapshots cannot mutate retained observations; close is idempotent', () => {
  const o = observer(),
    source = dataPacket(tsPacket()),
    copy = Buffer.from(source);
  o.observe(event(source));
  assert.deepEqual(source, copy);
  source.fill(0);
  const a = o.snapshot();
  a.events[0].packet.transportStream.packets[0].pid = 7;
  a.limits.maxEvents = 2;
  assert.equal(o.snapshot().events[0].packet.transportStream.packets[0].pid, 256);
  o.close();
  const closed = o.snapshot();
  o.close();
  assert.equal(o.observe(event(copy)), false);
  assert.deepEqual(o.snapshot(), closed);
  assert.equal(closed.closed, true);
  assert.equal(closed.diagnosticOnly, true);
  assert.equal(closed.productionUpgradeAuthorized, false);
});
test('sticky row overflow counts all omitted datagrams and never resumes retention', () => {
  const o = observer({ maxEvents: 1 }),
    data = dataPacket();
  o.observe(event(data));
  assert.equal(o.observe(event(data, { ordinal: 2 })), false);
  o.observe(event(Buffer.alloc(1), { ordinal: 3 }));
  const s = o.snapshot();
  assert.equal(s.events.length, 1);
  assert.equal(s.overflow, true);
  assert.equal(s.observedEvents, 3);
  assert.equal(s.omittedEvents, 2);
  assert.equal(s.omittedDatagramBytes, 17);
});
test('byte ceiling bounds complete export including reserved metadata and omissions', () => {
  const o = observer({ maxBytes: 5000 }),
    data = dataPacket(Buffer.concat(Array.from({ length: 7 }, tsPacket)));
  for (let i = 0; i < 20; i++) o.observe(event(data, { ordinal: i + 1, at: i }));
  o.close();
  const s = o.snapshot();
  assert.equal(s.overflow, true);
  assert(s.omittedEvents > 0);
  assert(Buffer.byteLength(JSON.stringify(s)) <= 5000);
});
test('datagram bound never truncates an oversized packet into apparently valid SRT', () => {
  const p = parse(dataPacket(Buffer.alloc(2048)));
  assert.deepEqual(p, { kind: 'unparsed', reason: 'oversize' });
  assert.equal(
    parse(dataPacket(Buffer.concat(Array.from({ length: 10 }, tsPacket)))).transportStream.packets
      .length,
    10,
  );
});
test('invalid events cannot throw into the queue or retain arbitrary error strings', () => {
  const o = observer();
  for (const value of [
    null,
    {},
    event('secret'),
    event(dataPacket(), { at: NaN }),
    event(dataPacket(), { ordinal: 0 }),
    event(dataPacket(), { direction: 'secret' }),
    {
      get data() {
        throw Error('secret');
      },
    },
  ])
    assert.doesNotThrow(() => assert.equal(o.observe(value), false));
  const s = o.snapshot();
  assert.equal(s.invalidEvents, 7);
  assert.equal(s.events.length, 0);
  assert(!JSON.stringify(s).includes('secret'));
});
test('constructor validates finite bounded limits and rejects unknown option keys', () => {
  for (const options of [
    null,
    [],
    false,
    { maxEvents: 0 },
    { maxEvents: 131073 },
    { maxBytes: 4095 },
    { maxBytes: 33554433 },
    { maxDatagramBytes: 15 },
    { maxDatagramBytes: 2049 },
    { maxControlRanges: 0 },
    { maxControlRanges: 33 },
    { other: 1 },
    { [Symbol('hidden')]: 1 },
  ])
    assert.throws(() => observer(options));
  assert.deepEqual(observer().snapshot().limits, {
    maxEvents: 131072,
    maxBytes: 33554432,
    maxDatagramBytes: 2048,
    maxControlRanges: 32,
  });
});

test('a byte-array subclass cannot smuggle nonnumeric diagnostic byte metadata', () => {
  class UntrustedBytes extends Uint8Array {
    get byteLength() {
      return 'private-token';
    }
  }
  const o = observer();
  assert.equal(o.observe(event(new UntrustedBytes(16))), false);
  const snapshot = o.snapshot();
  assert.equal(snapshot.observedDatagramBytes, 0);
  assert.equal(snapshot.omittedDatagramBytes, 0);
  assert(!JSON.stringify(snapshot).includes('private-token'));
});
test('PES PTS-only zero and complete optional-header markers are handled independently', () => {
  const ts = tsPacket();
  ts[13] = 0x80;
  ts[14] = 5;
  timestamp(0, 2).copy(ts, 15);
  assert.deepEqual(parse(dataPacket(ts)).transportStream.packets[0].pes, {
    streamID: 224,
    status: 'parsed',
    pts: 0,
  });
  for (const mutate of [
    (b) => (b[13] = 0x40),
    (b) => (b[14] = 4),
    (b) => (b[12] = 0),
    (b) => (b[15] = 0x31),
  ]) {
    const invalid = Buffer.from(ts);
    mutate(invalid);
    assert.deepEqual(parse(dataPacket(invalid)).transportStream.packets[0].pes, {
      streamID: 224,
      status: 'malformed',
    });
  }
});
test('TS optional adaptation fields must fit entirely in their declared field', () => {
  for (const flag of [0x10, 0x08, 0x04, 0x02, 0x01]) {
    const ts = tsPacket();
    ts[5] |= flag;
    assert.deepEqual(parse(dataPacket(ts)).transportStream, { status: 'malformed' });
  }
  const adaptationOnly = tsPacket();
  adaptationOnly[3] = 0x20;
  adaptationOnly[4] = 183;
  adaptationOnly[5] = 0;
  const row = parse(dataPacket(adaptationOnly)).transportStream.packets[0];
  assert.equal(row.adaptationControl, 2);
  assert.equal(row.pes, undefined);
});
test('byte views respect offset and length rather than reading adjacent source storage', () => {
  const packet = dataPacket(tsPacket()),
    storage = Buffer.concat([Buffer.alloc(8, 0xaa), packet, Buffer.from('CREDENTIAL')]);
  const view = new Uint8Array(storage.buffer, storage.byteOffset + 8, packet.length);
  const o = observer();
  o.observe(event(view));
  assert.deepEqual(o.snapshot().events[0].packet, parse(packet));
});
