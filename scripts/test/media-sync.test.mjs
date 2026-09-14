import { test } from 'node:test';
import assert from 'node:assert/strict';
import { analyzeMediaSync, assertMediaSync, sourceAudioExpression } from '../media-sync.mjs';

function fixture({
  offset = 0,
  drift = 0,
  drop = [],
  frequencyError = 0,
  start = 0,
  duration = 12,
} = {}) {
  const sampleRate = 48000;
  const audioSamples = new Float32Array(duration * sampleRate);
  for (let i = 0; i < audioSamples.length; i++) {
    const sourceTime = (start + i / sampleRate - offset) / (1 + drift);
    const id = Math.floor(sourceTime / 2);
    if (sourceTime >= 0 && sourceTime % 2 < 0.2 && !drop.includes(id)) {
      audioSamples[i] =
        0.5 * Math.sin(2 * Math.PI * (1000 + 20 * id + frequencyError) * sourceTime);
    }
  }
  const codes = Array.from({ length: duration * 30 }, (_, i) => Math.round(start * 30) + i);
  const videoTimes = Array.from(
    { length: codes.length },
    (_, i) => Math.round((start + i / 30) * 1000) / 1000,
  );
  return { codes, videoTimes, audioSamples, sampleRate, audioStartTime: start };
}

test('source marker uses an identity-bearing pulse frequency', () => {
  assert.match(sourceAudioExpression(), /1000\+20\*floor\(t\/2\)/);
  assert.match(sourceAudioExpression(), /48000/);
});

test('synchronized markers tolerate video-frame and sample quantization', () => {
  const result = analyzeMediaSync(fixture());
  assert.ok(result.pulseCount >= 5);
  assert.ok(result.maxAbsOffset < 0.02);
  assert.ok(Math.abs(result.medianOffset) < 0.02);
  assert.doesNotThrow(() => assertMediaSync(result));
});

for (const offset of [-0.25, 0.25, 2, -2]) {
  test(`identity matching detects ${offset}s offset without periodic aliasing`, () => {
    const result = analyzeMediaSync(fixture({ offset, duration: 16 }));
    assert.ok(Math.abs(result.medianOffset - offset) < 0.02, JSON.stringify(result));
    assert.throws(() => assertMediaSync(result), /100 ms/);
  });
}

test('measures drift between the first and last matched source markers', () => {
  const result = analyzeMediaSync(fixture({ drift: 0.002 }));
  assert.ok(result.drift > 0.014 && result.drift < 0.018);
});

test('allows partial edge pulses and uses absolute media timestamps', () => {
  const result = analyzeMediaSync(fixture({ start: 2.1, duration: 10 }));
  assert.equal(result.pulseCount, 4);
  assert.ok(result.maxAbsOffset < 0.02);
});

test('rejects missing interior audio marker instead of selecting surviving pulses', () => {
  assert.throws(() => analyzeMediaSync(fixture({ drop: [3] })), /missing|sequence/i);
});

test('rejects off-grid pulse frequency', () => {
  assert.throws(() => analyzeMediaSync(fixture({ frequencyError: 9 })), /frequency|ambiguous/i);
});

test('rejects too few markers', () => {
  assert.throws(() => analyzeMediaSync(fixture({ duration: 5 })), /three|3/);
});

test('rejects a pulse without a nearby video identity bracket', () => {
  const input = fixture();
  const keep = input.codes.map((code) => code < 174 || code > 186);
  input.codes = input.codes.filter((_, i) => keep[i]);
  input.videoTimes = input.videoTimes.filter((_, i) => keep[i]);
  assert.throws(() => analyzeMediaSync(input), /gap|nearby|bracket/i);
});

for (const mutation of [
  (f) => {
    f.videoTimes[3] = NaN;
  },
  (f) => {
    f.videoTimes[3] = f.videoTimes[2];
  },
  (f) => {
    f.videoTimes.pop();
  },
  (f) => {
    f.codes[3] = f.codes[2];
  },
  (f) => {
    f.codes[3] = -1;
  },
  (f) => {
    f.audioSamples[100] = NaN;
  },
]) {
  test(`rejects broken measurement input: ${mutation.toString()}`, () => {
    const input = fixture();
    mutation(input);
    assert.throws(
      () => analyzeMediaSync(input),
      /Invalid|monotonic|length|finite|duplicate|regressed/i,
    );
  });
}

test('stale timestamps shifted from matching frame data fail qualification', () => {
  const input = fixture();
  input.videoTimes = input.videoTimes.map((time) => time + 2);
  assert.throws(() => assertMediaSync(analyzeMediaSync(input)), /100 ms/);
});

test('interpolates source marker PTS between neighboring decoded frames', () => {
  const input = fixture();
  const keep = input.codes.map((code) => code % 60 !== 0);
  input.codes = input.codes.filter((_, i) => keep[i]);
  input.videoTimes = input.videoTimes.filter((_, i) => keep[i]);
  assert.ok(analyzeMediaSync(input).maxAbsOffset < 0.02);
});

test('retains unique marker identity near the end of a ten-minute source', () => {
  const result = analyzeMediaSync(fixture({ start: 590, duration: 10 }));
  assert.equal(result.pulses[0].id, 296);
  assert.ok(result.maxAbsOffset < 0.02);
});

test('rejects malformed qualification metrics', () => {
  for (const metrics of [null, { maxAbsOffset: 0 }, { maxAbsOffset: -1, matchedPulseCount: 3 }]) {
    assert.throws(() => assertMediaSync(metrics), /Invalid/);
  }
});

for (const id of [1, 9]) {
  test(`rejects missing fully covered edge marker ${id}`, () => {
    assert.throws(
      () => analyzeMediaSync(fixture({ duration: 20, drop: [id] })),
      /missing.*marker|marker.*missing/i,
    );
  });
}

test('rejects transient PTS corruption between otherwise synchronized markers', () => {
  const input = fixture();
  for (let i = 270; i < 285; i++) input.videoTimes[i] += 0.433;
  // Recover gradually before the next pulse without regressing presentation PTS.
  for (let i = 285; i < 300; i++) input.videoTimes[i] += (0.433 * (300 - i)) / 15;
  assert.throws(() => analyzeMediaSync(input), /cadence|source.*timestamp/i);
});
