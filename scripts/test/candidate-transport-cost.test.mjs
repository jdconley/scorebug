import assert from 'node:assert/strict';
import test from 'node:test';
import { replayCandidateTransportCost } from '../candidate-transport-cost.mjs';

const time = (value, timescale = 90000) => ({
  value: String(value),
  timescale,
  epoch: '0',
  flags: 1,
});
const video = (ticks = 0, byteCount = 6, isSync = true) => ({
  media: 'video',
  sourcePTS: time(ticks),
  decodePTS: null,
  byteCount,
  isSync,
  parameterSetBytes: isSync ? 34 : 0,
});
const audio = (ticks = 0, byteCount = 4) => ({
  media: 'audio',
  sourcePTS: time(ticks),
  decodePTS: null,
  byteCount,
  isSync: true,
  parameterSetBytes: 0,
});
const clone = (value) => structuredClone(value);

test('counts actual startup tables and separately rounded audio/video writes', () => {
  const result = replayCandidateTransportCost([audio(), video()]);
  assert.equal(result.transportBytes, 752);
  assert.equal(result.transportMessageCount, 3);
  assert.equal(result.videoInputBytes, 6);
  assert.equal(result.audioInputBytes, 4);
  assert.equal(result.videoInputCount, 1);
  assert.equal(result.audioInputCount, 1);
  assert.equal(result.programWrites, 1);
  assert.equal(result.pcrCount, 0);
  assert.deepEqual(
    result.writes.map((w) => w.byteCount),
    [376, 188, 188],
  );
});

test('replays known production mux boundary fixtures with repeated tables', () => {
  for (const [bytes, expected] of [
    [6, 2632],
    [163, 4512],
    [1270, 15792],
  ]) {
    const inputs = [0, 45000, 189000, 270000, 360000].flatMap((ticks, i) => [
      audio(ticks, bytes),
      video(ticks, bytes, i % 2 === 0),
    ]);
    const result = replayCandidateTransportCost(inputs);
    assert.equal(result.transportBytes, expected);
    assert.equal(result.transportMessageCount, bytes === 1270 ? 22 : 12);
    assert.equal(result.programWrites, 2);
    assert.equal(result.pcrCount, 4);
  }
});

test('PCR reduces first-packet payload from 183 to 176 bytes', () => {
  const result = replayCandidateTransportCost([
    video(),
    audio(),
    video(1799, 163, false),
    video(1800, 163, false),
  ]);
  assert.deepEqual(
    result.writes.filter((w) => w.media === 'video').map((w) => w.byteCount),
    [188, 188, 376],
  );
  assert.equal(result.pcrCount, 1);
});

test('program rotation is strictly greater than two seconds and clock floors rationals', () => {
  const inputs = [
    video(),
    audio(),
    video(180000, 6, false),
    video(180001, 6, false),
    video(360001, 6, false),
    video(360002, 6, false),
  ];
  const result = replayCandidateTransportCost(inputs);
  assert.equal(result.programWrites, 3);
  assert.deepEqual(
    result.writes.filter((w) => w.media === 'program').map((w) => w.inputIndex),
    [null, 3, 5],
  );
  const tiny = [
    video(),
    audio(),
    { ...video(), sourcePTS: time(19999999, 1000000000) },
    { ...video(), sourcePTS: time(20000000, 1000000000) },
  ];
  assert.equal(replayCandidateTransportCost(tiny).pcrCount, 1);
});

test('supports exact large absolute clocks and rationally equal track origins', () => {
  const base = 8000000000000000000n;
  const inputs = [video(), audio(), video(1800, 163, false)];
  inputs[0].sourcePTS = time(base, 1000000000);
  inputs[1].sourcePTS = time(base / 1000n, 1000000);
  inputs[2].sourcePTS = time(base + 20000000n, 1000000000);
  const result = replayCandidateTransportCost(inputs);
  assert.equal(result.transportBytes, 1128);
  assert.equal(result.pcrCount, 1);
});

test('uses DTS for PCR/program clock and adds the second five-byte PES timestamp', () => {
  const without = [video(9000, 125), audio(9000)];
  const withDTS = clone(without);
  withDTS[0].decodePTS = time(0);
  assert.equal(replayCandidateTransportCost(without).transportBytes, 752);
  assert.equal(replayCandidateTransportCost(withDTS).transportBytes, 940);
});

test('counts complete keyframe parameter sets and ADTS headers at packet boundaries', () => {
  const result = replayCandidateTransportCost([audio(0, 163), video(0, 130)]);
  assert.deepEqual(
    result.writes.map((w) => w.byteCount),
    [376, 376, 376],
  );
});

const faults = [
  ['missing audio', (a) => a.splice(0, 1)],
  ['missing video', (a) => a.splice(1, 1)],
  [
    'first non-keyframe',
    (a) => {
      a[1].isSync = false;
      a[1].parameterSetBytes = 0;
    },
  ],
  [
    'missing parameters',
    (a) => {
      a[1].parameterSetBytes = 0;
    },
  ],
  [
    'oversized parameters',
    (a) => {
      a[1].parameterSetBytes = 65601;
    },
  ],
  [
    'fractional size',
    (a) => {
      a[1].byteCount = 6.5;
    },
  ],
  [
    'empty input',
    (a) => {
      a[1].byteCount = 0;
    },
  ],
  [
    'oversized video',
    (a) => {
      a[1].byteCount = 2097152;
    },
  ],
  [
    'oversized audio',
    (a) => {
      a[0].byteCount = 8185;
    },
  ],
  [
    'audio parameters',
    (a) => {
      a[0].parameterSetBytes = 10;
    },
  ],
  [
    'audio DTS',
    (a) => {
      a[0].decodePTS = time(0);
    },
  ],
  [
    'unknown media',
    (a) => {
      a[0].media = 'data';
    },
  ],
  [
    'bad sync type',
    (a) => {
      a[1].isSync = 'true';
    },
  ],
  [
    'epoch',
    (a) => {
      a[0].sourcePTS.epoch = '1';
    },
  ],
  [
    'zero scale',
    (a) => {
      a[0].sourcePTS.timescale = 0;
    },
  ],
  [
    'overflow time',
    (a) => {
      a[0].sourcePTS.value = '9223372036854775808';
    },
  ],
  [
    'negative time',
    (a) => {
      a[0].sourcePTS.value = '-1';
    },
  ],
  [
    'numeric time',
    (a) => {
      a[0].sourcePTS.value = 0;
    },
  ],
  [
    'infinite flags',
    (a) => {
      a[0].sourcePTS.flags = 5;
    },
  ],
  ['duplicate track PTS', (a) => a.push(video())],
  ['changed parameter bytes', (a) => a.push({ ...video(100), parameterSetBytes: 35 })],
  ['non-keyframe parameters', (a) => a.push({ ...video(100, 6, false), parameterSetBytes: 34 })],
  ['combined span overflow', (a) => a.push(audio(382501))],
  [
    'DTS before origin',
    (a) => {
      a[0].sourcePTS = time(100);
      a[1].sourcePTS = time(100);
      a.push({ ...video(200), decodePTS: time(0) });
    },
  ],
];
for (const [label, mutate] of faults)
  test(`rejects ${label}`, () => {
    const inputs = [audio(), video()];
    mutate(inputs);
    assert.throws(() => replayCandidateTransportCost(inputs));
  });

test('bounds arrays, per-track counts, cumulative bytes and startup retention independently', () => {
  assert.throws(() => replayCandidateTransportCost(Array(634).fill(video())));
  assert.throws(() =>
    replayCandidateTransportCost([
      audio(),
      ...Array.from({ length: 122 }, (_, i) => video(i * 3000)),
    ]),
  );
  assert.throws(() =>
    replayCandidateTransportCost([video(), ...Array.from({ length: 513 }, (_, i) => audio(i))]),
  );
  assert.throws(() =>
    replayCandidateTransportCost([
      audio(),
      ...Array.from({ length: 32 }, (_, i) => video(i * 3000, 1048576)),
    ]),
  );
  assert.throws(() =>
    replayCandidateTransportCost([...Array.from({ length: 257 }, (_, i) => audio(i)), video(257)]),
  );
  assert.throws(() =>
    replayCandidateTransportCost([
      ...Array.from({ length: 8 }, (_, i) => video(i * 3000, 1048576)),
      audio(21000),
    ]),
  );
  assert.throws(() => replayCandidateTransportCost([video(), audio(180001)]));
});

test('applies full fixed-format parameter preflight before allocating a startup non-keyframe', () => {
  const inputs = Array.from({ length: 8 }, (_, i) => ({
    ...video(i * 3000, i === 7 ? 1048291 : 1048576, i === 0),
    parameterSetBytes: i === 0 ? 100 : 0,
  }));
  inputs.push(audio(21000));
  assert.throws(() => replayCandidateTransportCost(inputs), /startup/);
});

test('rejects a video too small to contain a four-byte AVCC length and VCL header', () => {
  assert.throws(() => replayCandidateTransportCost([video(0, 4), audio()]));
});
