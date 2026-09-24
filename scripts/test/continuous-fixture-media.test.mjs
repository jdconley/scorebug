import assert from 'node:assert/strict';
import { test } from 'node:test';
import { verifyContinuousFixtureMedia } from '../continuous-fixture-media.mjs';

function fixture(sampleRate = 48000, count = 30) {
  const bytes = Buffer.alloc(count * 16);
  for (let i = 0; i < count; i++)
    for (let bit = 0; bit < 16; bit++) bytes[i * 16 + bit] = i & (1 << bit) ? 235 : 16;
  return {
    expectedFrames: count,
    sampleRate,
    bytes,
    frames: Array.from({ length: count }, (_, i) => [
      { media_type: 'video', best_effort_timestamp_time: String(i / 30) },
      {
        media_type: 'audio',
        best_effort_timestamp_time: String(i / 30),
        nb_samples: sampleRate / 30,
      },
    ]).flat(),
  };
}

test('complete identities and continuous A/V cover the declared interval', () => {
  const result = verifyContinuousFixtureMedia(fixture());
  assert.equal(result.videoFrames, 30);
  assert.equal(result.audioSamples, 48000);
  assert.equal(result.firstSourceFrame, 0);
  assert.equal(result.lastSourceFrame, 29);
});

test('uses the validated 44.1 kHz proxy audio rate for continuity and coverage', () => {
  const result = verifyContinuousFixtureMedia(fixture(44100));
  assert.equal(result.audioSamples, 44100);
  assert.equal(result.coverage.audioEndTime, 1);
});

const faults = {
  'missing tail': (f) => f.frames.splice(-2, 1),
  'duplicate identity': (f) => f.bytes.copy(f.bytes, 16, 0, 16),
  'reordered identity': (f) => f.bytes.copy(f.bytes, 0, 32, 48),
  'nonfinite video time': (f) => (f.frames[0].best_effort_timestamp_time = 'NaN'),
  'repeated video time': (f) => (f.frames[2].best_effort_timestamp_time = '0'),
  'video stall': (f) => (f.frames[20].best_effort_timestamp_time = '0.38'),
  'compressed timeline': (f) =>
    f.frames.forEach(
      (x) => (x.best_effort_timestamp_time = String(Number(x.best_effort_timestamp_time) / 2)),
    ),
  'missing audio startup': (f) =>
    (f.frames = f.frames.filter((x, i) => x.media_type !== 'audio' || i > 10)),
  'internal audio hole with unchanged sample total': (f) =>
    (f.frames[21].best_effort_timestamp_time = '0.36'),
  'internal audio overlap with unchanged sample total': (f) =>
    (f.frames[21].best_effort_timestamp_time = '0.31'),
  'cumulative audio drift that returns before the tail': (f) =>
    f.frames
      .filter((x) => x.media_type === 'audio')
      .forEach((x, i) => {
        x.best_effort_timestamp_time = String(i / 30 + Math.min(i, 29 - i) * 0.001);
      }),
  'invalid audio sample count': (f) => (f.frames[1].nb_samples = -1),
  'missing audio tail': (f) =>
    (f.frames = f.frames.filter((x, i) => x.media_type !== 'audio' || i < 49)),
  'wrong duration declaration': (f) => (f.expectedFrames = 60),
  'missing sample rate': (f) => delete f.sampleRate,
  'zero sample rate': (f) => (f.sampleRate = 0),
};
for (const [name, mutate] of Object.entries(faults)) {
  test(`rejects ${name}`, () => {
    const input = fixture();
    mutate(input);
    assert.throws(() => verifyContinuousFixtureMedia(input));
  });
}

test('thirty-minute timeline retains identities above the signed 16-bit boundary', () => {
  const input = fixture(44100, 54000);
  const result = verifyContinuousFixtureMedia(input);
  assert.equal(result.videoFrames, 54000);
  assert.equal(result.lastSourceFrame, 53999);
  assert.equal(result.audioSamples, 1800 * 44100);
  assert.equal(result.duration, 1800);
  // Erasing bit15 must not turn the second half of the recording into a valid wrap.
  input.bytes[32768 * 16 + 15] = 16;
  assert.throws(() => verifyContinuousFixtureMedia(input), /source frame 32768/);
});

test('rejects an endurance declaration that wraps the 16-bit identity range', () => {
  const input = fixture();
  input.expectedFrames = 65536;
  assert.throws(() => verifyContinuousFixtureMedia(input));
});
