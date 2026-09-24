import assert from 'node:assert/strict';
import { test } from 'node:test';
import { qualifyNaturalAudio } from '../natural-audio-qualification.mjs';

function fixture(delay = 0) {
  let seed = 8135;
  const sourceSamples = Float32Array.from({ length: 12 * 8000 }, () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 2 ** 32 - 0.5;
  });
  // Audio at target PTS 19 corresponds to source t=2; video at PTS20 is frame90.
  const targetSamples = Float32Array.from(
    { length: 9 * 8000 },
    (_, i) => sourceSamples[16000 + i - delay] ?? 0,
  );
  return {
    sourceSamples,
    targetSamples,
    codes: Array.from({ length: 180 }, (_, i) => 90 + i),
    videoTimes: Array.from({ length: 180 }, (_, i) => 20 + i / 30),
    audioStartTime: 19,
    sourceAudioStartTime: 0,
  };
}

for (const delay of [-400, 0, 400]) {
  test(`source identities anchor audio with nonzero target PTS and ${delay} sample delay`, () => {
    const value = qualifyNaturalAudio(fixture(delay));
    assert.equal(value.probes.length, 3);
    assert.ok(value.probes.every((p) => Math.abs(p.audioVideoLagSeconds - delay / 8000) < 0.0001));
    assert.ok(value.probes.every((p) => p.correlation > 0.999));
    assert.ok(value.lagSpreadSeconds < 0.0001);
    assert.equal(value.passed, true);
  });
}

test('source audio origin is accounted for rather than assumed zero', () => {
  const input = fixture(160);
  input.sourceSamples = input.sourceSamples.slice(4000);
  input.sourceAudioStartTime = 0.5;
  const value = qualifyNaturalAudio(input);
  assert.ok(value.probes.every((p) => Math.abs(p.audioVideoLagSeconds - 0.02) < 0.0001));
});

for (const delay of [-1000, 1000, 1200]) {
  test(`rejects excessive lag or boundary at ${delay} samples`, () => {
    assert.throws(() => qualifyNaturalAudio(fixture(delay)));
  });
}

test('rejects unrelated and silent audio', () => {
  for (const transform of [(x) => x.fill(0), (x) => x.reverse()]) {
    const input = fixture();
    transform(input.targetSamples);
    assert.throws(() => qualifyNaturalAudio(input));
  }
});

test('rejects time drift across independently matched windows', () => {
  const input = fixture();
  input.targetSamples = Float32Array.from(
    input.targetSamples,
    (_, i) =>
      input.sourceSamples[16000 + i - (i >= 5.5 * 8000 ? 400 : i >= 3.5 * 8000 ? 200 : 0)] ?? 0,
  );
  assert.throws(
    () => qualifyNaturalAudio(input),
    (error) => {
      const report = JSON.parse(error.message.split('Natural audio alignment rejected: ')[1]);
      assert.ok(
        report.probes.every((p) => p.correlation > 0.999 && Math.abs(p.audioVideoLagSeconds) < 0.1),
      );
      assert.ok(report.lagSpreadSeconds > 0.049);
      return true;
    },
  );
});

const invalid = {
  'nonfinite time': (x) => (x.videoTimes[2] = NaN),
  'nonfinite audio': (x) => (x.sourceSamples[0] = Infinity),
  'duplicate identity': (x) => (x.codes[2] = x.codes[1]),
  'reversed time': (x) => (x.videoTimes[2] = x.videoTimes[1]),
  'missing identity': (x) => x.codes.pop(),
  'negative identity': (x) => (x.codes[0] = -1),
  'no audio support': (x) => (x.targetSamples = x.targetSamples.slice(0, 1000)),
  'short video': (x) => {
    x.codes = x.codes.slice(0, 30);
    x.videoTimes = x.videoTimes.slice(0, 30);
  },
};
for (const [name, change] of Object.entries(invalid)) {
  test(`rejects ${name}`, () => {
    const input = fixture();
    change(input);
    assert.throws(() => qualifyNaturalAudio(input));
  });
}

test('keeps the final search window inside media ending with the video', () => {
  const input = fixture();
  input.targetSamples = input.targetSamples.slice(0, 7 * 8000);
  assert.equal(qualifyNaturalAudio(input).passed, true);
});

test('fractional PCM origins retain independently generated sub-sample A/V offset', () => {
  const input = fixture();
  const wave = (t) =>
    [
      [397.3, 0.3, 0.2],
      [1201.9, 0.7, 0.24],
      [2377.7, 0.4, 0.18],
      [3211.4, 0.9, 0.12],
    ].reduce(
      (sum, [frequency, phase, gain]) => sum + gain * Math.sin(2 * Math.PI * frequency * t + phase),
      0,
    );
  input.sourceAudioStartTime = 0.5000625;
  input.sourceSamples = Float64Array.from({ length: 12 * 8000 }, (_, i) =>
    wave(input.sourceAudioStartTime + i / 8000),
  );
  input.audioStartTime = 19.00004;
  input.videoTimes = input.videoTimes.map((t) => t + 0.00004);
  input.targetSamples = Float64Array.from({ length: 9 * 8000 }, (_, i) =>
    wave(2 + i / 8000 - 0.00337),
  );
  const result = qualifyNaturalAudio(input);
  assert.ok(result.probes.every((p) => Math.abs(p.audioVideoLagSeconds - 0.00337) < 0.00001));
  assert.ok(result.probes.some((p) => Math.abs(p.roundingOffsetSeconds) > 0.00001));
});
