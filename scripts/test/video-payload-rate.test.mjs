import assert from 'node:assert/strict';
import test from 'node:test';
import * as payload from '../video-payload-rate.mjs';
const streams = [
  { index: 0, codec_type: 'audio', time_base: '1/48000' },
  { index: 1, codec_type: 'video', time_base: '1/90000' },
];
function packets(count = 150, offset = 0) {
  return Array.from({ length: count }, (_, i) => ({
    stream_index: 1,
    pts: offset + i * 3000,
    duration: 3000,
    size: '1000',
  }));
}
const measure = (p = packets(), s = streams) =>
  payload.measureVideoPayloadRate({ streams: s, packets: p });

test('measures actual video packet bytes across complete five-second intervals', () => {
  const result = measure();
  assert.equal(result.videoStreamIndex, 1);
  assert.equal(result.timeBase, '1/90000');
  assert.equal(result.windowSeconds, 5);
  assert.deepEqual(result.windows, [
    {
      startTimeSeconds: 0,
      endTimeSeconds: 5,
      packetCount: 150,
      payloadBytes: 150000,
      megabitsPerSecond: 0.24,
    },
  ]);
  assert.deepEqual(result.measured, {
    durationSeconds: 5,
    packetCount: 150,
    payloadBytes: 150000,
    meanMbps: 0.24,
    minMbps: 0.24,
    maxMbps: 0.24,
  });
  assert.deepEqual(result.leadingExcluded, { packetCount: 0, payloadBytes: 0 });
  assert.deepEqual(result.trailingExcluded, { packetCount: 0, payloadBytes: 0 });
});
test('audio bytes and unrelated packet timing never count toward video payload', () => {
  const p = packets().flatMap((v) => [
    v,
    { stream_index: 0, pts: -48000, duration: 1024, size: '9000000' },
  ]);
  assert.deepEqual(measure(p), measure());
});
test('retains common timeline and excludes incomplete leading and trailing intervals', () => {
  const result = measure(packets(450, 90000));
  assert.deepEqual(
    result.windows.map((w) => [w.startTimeSeconds, w.endTimeSeconds]),
    [
      [5, 10],
      [10, 15],
    ],
  );
  assert.deepEqual(result.leadingExcluded, { packetCount: 120, payloadBytes: 120000 });
  assert.deepEqual(result.trailingExcluded, { packetCount: 30, payloadBytes: 30000 });
  assert.equal(result.measured.packetCount, 300);
  assert.equal(result.coverage.startTimeSeconds, 1);
  assert.equal(result.coverage.endTimeSeconds, 16);
});
test('preserves internal gaps as zero-payload windows', () => {
  const result = measure(packets(450).filter((_, i) => i < 150 || i >= 300));
  assert.deepEqual(
    result.windows.map((w) => w.payloadBytes),
    [150000, 0, 150000],
  );
  assert.equal(result.measured.meanMbps, 0.16);
  assert.equal(result.measured.minMbps, 0);
  assert.equal(result.measured.maxMbps, 0.24);
});
test('attributes a whole packet to its exact rational PTS interval', () => {
  const p = packets(450).map((v, i) => ({ ...v, pts: String(i), duration: '1', size: 1000 }));
  const result = measure(p, [{ index: 1, codec_type: 'video', time_base: '1001/30000' }]);
  assert.deepEqual(
    result.windows.map((w) => w.packetCount),
    [150, 150, 150],
  );
  assert.equal(result.coverage.endTimeSeconds, 15.015);
  assert.equal(
    result.trailingExcluded.packetCount,
    0,
    'Last packet starts in the final measured interval',
  );
});
test('supports negative video PTS with exact signed window boundaries', () => {
  const result = measure(packets(450, -90000));
  assert.deepEqual(
    result.windows.map((w) => [w.startTimeSeconds, w.endTimeSeconds]),
    [
      [0, 5],
      [5, 10],
    ],
  );
  assert.equal(result.leadingExcluded.packetCount, 30);
  assert.equal(result.trailingExcluded.packetCount, 120);
});
test('allows128 windows and refuses129 before allocating unbounded output', () => {
  assert.equal(measure(packets(128 * 150)).windows.length, 128);
  assert.throws(() => measure(packets(129 * 150)), /window/i);
});
for (const [label, value] of [
  ['empty', []],
  ['too short', packets(149)],
  ['missing duration', packets().map(({ duration, ...p }) => p)],
  ['zero size', packets().map((p) => ({ ...p, size: '0' }))],
  ['zero duration', packets().map((p) => ({ ...p, duration: 0 }))],
  ['missing pts', packets().map(({ pts, ...p }) => p)],
  ['nonfinite pts', packets().map((p) => ({ ...p, pts: Infinity }))],
  ['unsafe pts', packets().map((p) => ({ ...p, pts: Number.MAX_SAFE_INTEGER + 1 }))],
  ['fractional size', packets().map((p) => ({ ...p, size: 1.5 }))],
  ['duplicate pts', packets().map((p) => ({ ...p, pts: 0 }))],
  ['regressed pts', packets().reverse()],
  ['noncanonical size', packets().map((p) => ({ ...p, size: '01' }))],
  ['unknown stream', [...packets(), { stream_index: 9, pts: 0, duration: 1, size: '1' }]],
  ['overflow byte sum', packets().map((p) => ({ ...p, size: String(Number.MAX_SAFE_INTEGER) }))],
])
  test(`rejects ${label}`, () => assert.throws(() => measure(value)));
for (const time_base of [
  '0/1',
  '1/0',
  '-1/90000',
  '1.0/90000',
  '1/090000',
  'N/A',
  null,
  '9007199254740992/1',
]) {
  test(`rejects invalid timebase ${time_base}`, () =>
    assert.throws(() => measure(packets(), [{ index: 1, codec_type: 'video', time_base }])));
}
for (const s of [
  [],
  streams.filter((s) => s.codec_type === 'audio'),
  [...streams, { index: 2, codec_type: 'video', time_base: '1/90000' }],
  [...streams, streams[0]],
]) {
  test(`rejects invalid or ambiguous streams ${JSON.stringify(s)}`, () =>
    assert.throws(() => measure(packets(), s)));
}
