import test from 'node:test';
import assert from 'node:assert/strict';
import { measuredAudioProbeFrames } from '../natural-audio-qualification.mjs';
const input = (phaseCount = 3) => ({
  phases: Array.from({ length: phaseCount }, (_, i) => ({
    firstFrame: i * 300,
    lastFrame: (i + 1) * 300 - 1,
  })),
  codes: Array.from({ length: phaseCount * 300 - 60 }, (_, i) => i + 60),
});
for (const [phaseCount, expected] of [
  [2, [75, 90, 240, 255, 315, 390, 540, 555]],
  [4, [75, 90, 240, 255, 315, 390, 540, 555, 615, 690, 840, 855, 915, 990, 1140, 1155]],
  [
    5,
    [
      75, 90, 240, 255, 315, 390, 540, 555, 615, 690, 840, 855, 915, 990, 1140, 1155, 1215, 1290,
      1440, 1455,
    ],
  ],
])
  test(`${phaseCount}-phase audio probes retain every phase head/tail and source grid anchor`, () => {
    assert.deepEqual(measuredAudioProbeFrames(input(phaseCount)), expected);
  });

for (const [name, change, message] of [
  [
    'reordered phases',
    (x) => ([x.phases[1], x.phases[2]] = [x.phases[2], x.phases[1]]),
    /Ordered phase identities/,
  ],
  ['overlapping transition', (x) => (x.phases[2].firstFrame = 599), /Ordered phase identities/],
  [
    'too-short transition coverage',
    (x) => (x.phases[2].lastFrame = 658),
    /Insufficient phase audio coverage/,
  ],
  [
    'too-short decoded prefix',
    (x) => (x.codes = x.codes.slice(181)),
    /Insufficient phase audio coverage/,
  ],
  ['missing media tail', (x) => x.codes.pop(), /Complete measured media tail/],
  ['phase tail beyond media', (x) => x.phases.at(-1).lastFrame++, /Complete measured media tail/],
  ['duplicate source identity', (x) => (x.codes[1] = x.codes[0]), /Ordered decoded identities/],
  ['noninteger source identity', (x) => (x.codes[1] = 61.5), /Ordered decoded identities/],
  ['negative source identity', (x) => (x.codes[0] = -1), /Ordered decoded identities/],
  [
    'out-of-range source identity',
    (x) => (x.codes[x.codes.length - 1] = 65536),
    /Ordered decoded identities/,
  ],
  ['invalid phase identity', (x) => (x.phases[2].firstFrame = NaN), /Ordered phase identities/],
  ['short decoded range', (x) => (x.codes = x.codes.slice(0, 126)), /Bounded decoded source range/],
  [
    'oversized decoded range',
    (x) => (x.codes = Array.from({ length: 65536 }, (_, i) => i)),
    /Bounded decoded source range/,
  ],
  [
    'insufficient final search support',
    (x) => (x.codes = x.codes.filter((n) => n <= 1155 || n === 1199)),
    /Missing requested measured audio anchor/,
  ],
  [
    'too many anchors',
    (x) => {
      x.phases = Array.from({ length: 4 }, (_, i) => ({
        firstFrame: i * 10000,
        lastFrame: (i + 1) * 10000 - 1,
      }));
      x.codes = Array.from({ length: 40000 }, (_, i) => i);
    },
    /Bounded measured audio anchors/,
  ],
])
  test(`four-phase audio probes reject ${name}`, () => {
    const x = input(4);
    change(x);
    assert.throws(() => measuredAudioProbeFrames(x), message);
  });

for (const frame of [315, 555, 615, 855, 915, 1155, 990, 1140])
  test(`four-phase audio probes reject missing transition, tail or grid anchor ${frame}`, () => {
    const x = input(4);
    x.codes = x.codes.filter((n) => n !== frame);
    assert.throws(() => measuredAudioProbeFrames(x), /Missing requested measured audio anchor/);
  });
test('audio probes cover each actual phase head/tail and five-second source intervals', () => {
  assert.deepEqual(
    measuredAudioProbeFrames(input()),
    [75, 90, 240, 255, 315, 390, 540, 555, 615, 690, 840, 855],
  );
});
for (const [name, change] of Object.entries({
  'no phases': (x) => (x.phases = []),
  'one phase': (x) => (x.phases = x.phases.slice(0, 1)),
  'too many phases': (x) => (x.phases = Array(6).fill(x.phases[0])),
  'overlapping phase': (x) => (x.phases[1].firstFrame = 299),
  'inverted phase': (x) => (x.phases[1].lastFrame = 200),
  'insufficient phase audio': (x) => {
    x.phases[1].lastFrame = 330;
    x.phases[2].firstFrame = 331;
  },
  'missing requested source frame': (x) => (x.codes = x.codes.filter((n) => n !== 315)),
  'unordered decoded identities': (x) => x.codes.reverse(),
  'decoded prefix outside phases': (x) => (x.phases[0].firstFrame = 100),
  'decoded tail outside phases': (x) => (x.phases[2].lastFrame = 898),
}))
  test(`audio phase selection rejects ${name}`, () => {
    const x = input();
    change(x);
    assert.throws(() => measuredAudioProbeFrames(x));
  });
