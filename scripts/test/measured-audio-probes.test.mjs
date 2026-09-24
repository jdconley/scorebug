import test from 'node:test';
import assert from 'node:assert/strict';
import { measuredAudioProbeFrames } from '../natural-audio-qualification.mjs';
const input = () => ({
  phases: [
    { firstFrame: 0, lastFrame: 299 },
    { firstFrame: 300, lastFrame: 599 },
    { firstFrame: 600, lastFrame: 899 },
  ],
  codes: Array.from({ length: 840 }, (_, i) => i + 60),
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
