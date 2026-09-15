import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  analyzeMediaSync,
  assertMediaSync,
  assertMediaCoverage,
  sourceAudioExpression,
} from '../media-sync.mjs';

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

function writePulse(input, start, length, frequency = 1000) {
  for (let i = 0; i < length; i++) {
    input.audioSamples[start + i] =
      0.5 * Math.sin((2 * Math.PI * frequency * i) / input.sampleRate);
  }
  input.audioSamples[start] = 0.5;
  input.audioSamples[start + length - 1] = 0.5;
}

function initialPulseFixture({ start = 1213, length = 2781, frequency = 1066 } = {}) {
  const input = fixture({ duration: 14 });
  input.audioSamples.fill(0, 0, 2 * input.sampleRate);
  writePulse(input, start, length, frequency);
  input.codes = input.codes.slice(33);
  input.videoTimes = input.videoTimes.slice(33).map((time) => time - 0.016);
  return input;
}

test('omits the measured short acquisition prefix without qualifying its frequency', () => {
  const input = initialPulseFixture();
  const result = analyzeMediaSync(input);
  assert.equal(result.pulseCount, 6);
  assert.equal(result.matchedPulseCount, 6);
  assert.equal(result.expectedPulseCount, 6);
  assert.deepEqual(
    result.pulses.map((pulse) => pulse.id),
    [1, 2, 3, 4, 5, 6],
  );
  assert.doesNotThrow(() => assertMediaSync(result));
  const coverage = { ...input, audioSampleCount: input.audioSamples.length };
  assert.throws(() => assertMediaCoverage(coverage), /coverage.*start.*100 ms/i);
  assert.doesNotThrow(() => assertMediaCoverage({ ...coverage, maxAudioLeadSeconds: 2.1 }));
});

test('acquisition prefix exclusion uses absolute audio timestamps', () => {
  const input = initialPulseFixture();
  input.audioStartTime = 93.5;
  input.videoTimes = input.videoTimes.map((time) => time + 93.5);
  assert.equal(analyzeMediaSync(input).matchedPulseCount, 6);
  // Moving only audio makes the same fragment occur inside video coverage.
  input.audioStartTime += 2;
  assert.throws(() => analyzeMediaSync(input), /Invalid audio marker pulse duration/);
});

for (const [label, endSample, accepted] of [
  ['one sample before video begins', 52031, true],
  ['exactly where video begins', 52032, false],
  ['one sample after video begins', 52033, false],
]) {
  test(`short acquisition prefix ending ${label}`, () => {
    const input = initialPulseFixture({ start: endSample - 2781 });
    // Set the boundary directly to avoid subtracting rounded frame timestamps.
    const adjustment = 52032 / input.sampleRate - input.videoTimes[0];
    input.videoTimes = input.videoTimes.map((time) => time + adjustment);
    if (accepted) assert.doesNotThrow(() => assertMediaSync(analyzeMediaSync(input)));
    else assert.throws(() => analyzeMediaSync(input), /Invalid audio marker pulse duration/);
  });
}

test('rejects a short first pulse wholly within video coverage', () => {
  assert.throws(
    () => analyzeMediaSync(initialPulseFixture({ start: 57600 })),
    /Invalid audio marker pulse duration/,
  );
});

test('rejects a second short prefix even if the first raw segment was edge-skipped', () => {
  const input = initialPulseFixture({ start: 0, length: 1000 });
  writePulse(input, 9600, 2781, 1066);
  assert.throws(() => analyzeMediaSync(input), /Invalid audio marker pulse duration/);
});

for (const length of [7200, 9600]) {
  test(`counts a ${length / 48} ms complete acquisition prefix`, () => {
    const result = analyzeMediaSync(initialPulseFixture({ length, frequency: 1000 }));
    assert.equal(result.pulseCount, 7);
    assert.equal(result.matchedPulseCount, 6);
    assert.doesNotThrow(() => assertMediaSync(result));
  });
}

test('omits a first prefix one sample shorter than 150 ms', () => {
  assert.equal(analyzeMediaSync(initialPulseFixture({ length: 7199 })).pulseCount, 6);
});

test('still rejects a long acquisition prefix', () => {
  assert.throws(
    () => analyzeMediaSync(initialPulseFixture({ length: 14400 })),
    /Invalid audio marker pulse duration/,
  );
});

test('still validates a complete acquisition prefix frequency', () => {
  assert.throws(
    () => analyzeMediaSync(initialPulseFixture({ length: 9600, frequency: 1009 })),
    /Ambiguous audio marker frequency/,
  );
});

test('an exempt acquisition prefix cannot hide the first fully covered missing marker', () => {
  const input = initialPulseFixture();
  input.audioSamples.fill(0, 2 * input.sampleRate, 2.2 * input.sampleRate);
  assert.throws(() => analyzeMediaSync(input), /Missing fully covered audio marker 1/);
});

test('rejects nonfinite audio even inside an otherwise exempt acquisition prefix', () => {
  const input = initialPulseFixture();
  input.audioSamples[1300] = NaN;
  assert.throws(() => analyzeMediaSync(input), /Audio samples must be finite/);
});

function terminalPulseFixture({ activeSamples, quietSamples }) {
  const input = fixture({ duration: 14 });
  const start = 12 * input.sampleRate;
  input.audioSamples = input.audioSamples.slice(0, start + activeSamples + quietSamples);
  for (let i = 0; i < activeSamples; i++) {
    input.audioSamples[start + i] = 0.5 * Math.sin((2 * Math.PI * 1120 * i) / input.sampleRate);
  }
  // Fix the threshold-crossing boundaries exactly, independently of sine phase.
  input.audioSamples[start] = 0.5;
  input.audioSamples[start + activeSamples - 1] = 0.5;
  input.audioSamples.fill(0, start + activeSamples);
  const frames = Math.floor((input.audioSamples.length / input.sampleRate) * 30);
  input.codes = input.codes.slice(0, frames);
  input.videoTimes = input.videoTimes.slice(0, frames);
  return input;
}

for (const [label, quietSamples] of [
  ['measured 20.479167 ms AAC padding', 983],
  ['one sample below the 40 ms silence boundary', 1919],
]) {
  test(`omits only the cut terminal marker with ${label}`, () => {
    const result = analyzeMediaSync(terminalPulseFixture({ activeSamples: 2175, quietSamples }));
    assert.equal(result.pulseCount, 5);
    assert.equal(result.pulses.at(-1).id, 5);
    assert.doesNotThrow(() => assertMediaSync(result));
  });
}

test('rejects a short final marker closed by exactly 40 ms silence', () => {
  assert.throws(
    () => analyzeMediaSync(terminalPulseFixture({ activeSamples: 2175, quietSamples: 1920 })),
    /Invalid audio marker pulse duration/,
  );
});

test('counts a complete 200 ms final marker with 30 ms quiet at EOF', () => {
  const result = analyzeMediaSync(
    terminalPulseFixture({ activeSamples: 9600, quietSamples: 1440 }),
  );
  assert.equal(result.pulseCount, 6);
  assert.equal(result.pulses.at(-1).id, 6);
  assert.doesNotThrow(() => assertMediaSync(result));
});

test('rejects a long final marker even while its trailing silence is incomplete', () => {
  assert.throws(
    () => analyzeMediaSync(terminalPulseFixture({ activeSamples: 14400, quietSamples: 1440 })),
    /Invalid audio marker pulse duration/,
  );
});

test('rejects a shortened interior marker', () => {
  const input = fixture();
  input.audioSamples.fill(0, 6 * input.sampleRate + 2175, 6.2 * input.sampleRate);
  assert.throws(() => analyzeMediaSync(input), /Invalid audio marker pulse duration/);
});

test('a late unfinished blip cannot hide a missing fully covered final marker', () => {
  const input = fixture({ drop: [5] });
  const start = input.audioSamples.length - 2175 - 983;
  for (let i = 0; i < 2175; i++) {
    input.audioSamples[start + i] = 0.5 * Math.sin((2 * Math.PI * 1120 * i) / input.sampleRate);
  }
  input.audioSamples[start] = 0.5;
  input.audioSamples[start + 2174] = 0.5;
  assert.throws(() => analyzeMediaSync(input), /Missing fully covered audio marker 5/);
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

function coverageFixture({ start = 0, duration = 14 } = {}) {
  return {
    videoTimes: Array.from({ length: duration * 30 }, (_, i) => start + i / 30),
    audioStartTime: start,
    audioSampleCount: duration * 48000,
    sampleRate: 48000,
  };
}

for (const start of [0, 93.5, -2.5]) {
  test(`coverage uses decoded endpoints on the common ${start}s PTS timeline`, () => {
    const result = assertMediaCoverage(coverageFixture({ start }));
    assert.equal(result.videoStartTime, start);
    assert.equal(result.videoEndTime, start + 14);
    assert.equal(result.audioStartTime, start);
    assert.equal(result.audioEndTime, start + 14);
    assert.equal(result.startOffset, 0);
    assert.equal(result.endOffset, 0);
    assert.equal(result.toleranceSeconds, 0.1);
    assert.equal(result.maxAudioLeadSeconds, 0.1);
  });
}

test('coverage allows bounded AAC leading and trailing padding', () => {
  const input = coverageFixture();
  input.audioStartTime -= 1024 / 48000;
  input.audioSampleCount += 2048;
  const result = assertMediaCoverage(input);
  assert.ok(Math.abs(result.startOffset + 1024 / 48000) < 1e-12);
  assert.ok(Math.abs(result.endOffset - 1024 / 48000) < 1e-12);
});

test('coverage rejects seven seconds of audio against fourteen seconds of video even when markers pass', () => {
  const input = fixture({ duration: 14 });
  input.audioSamples = input.audioSamples.slice(0, 7 * input.sampleRate);
  assert.doesNotThrow(() => assertMediaSync(analyzeMediaSync(input)));
  assert.throws(
    () => assertMediaCoverage({ ...input, audioSampleCount: input.audioSamples.length }),
    /coverage.*end/i,
  );
});

for (const edge of ['start', 'end']) {
  test(`coverage rejects 250 ms of missing ${edge} audio`, () => {
    const input = coverageFixture();
    input.audioSampleCount -= 0.25 * input.sampleRate;
    if (edge === 'start') input.audioStartTime += 0.25;
    assert.throws(() => assertMediaCoverage(input), new RegExp(`coverage.*${edge}`, 'i'));
  });
}

test('coverage honors the supplied frame rate and tolerance', () => {
  const input = {
    videoTimes: [10, 10.25],
    audioStartTime: 10,
    audioSampleCount: 24000,
    sampleRate: 48000,
    framesPerSecond: 4,
    toleranceSeconds: 0,
  };
  assert.equal(assertMediaCoverage(input).videoEndTime, 10.5);
  input.audioSampleCount += 2400;
  assert.throws(() => assertMediaCoverage(input), /coverage.*end/i);
  assert.doesNotThrow(() => assertMediaCoverage({ ...input, toleranceSeconds: 0.06 }));
});

for (const [field, invalidValues] of Object.entries({
  videoTimes: [[], [NaN], [Infinity], [-Infinity], [0, 0], [1, 0], [0, NaN], null],
  audioStartTime: [NaN, Infinity, -Infinity, undefined],
  audioSampleCount: [NaN, Infinity, -Infinity, 0, -1, 1.5, undefined],
  sampleRate: [NaN, Infinity, -Infinity, 0, -1, 48000.5, undefined],
  framesPerSecond: [NaN, Infinity, -Infinity, 0, -1, 30.5],
  toleranceSeconds: [NaN, Infinity, -Infinity, -0.1],
  maxAudioLeadSeconds: [NaN, Infinity, -Infinity, -0.1],
})) {
  test(`coverage rejects invalid ${field}`, () => {
    for (const value of invalidValues) {
      assert.throws(
        () => assertMediaCoverage({ ...coverageFixture(), [field]: value }),
        /Invalid|finite|monotonic/i,
        `${field}: ${String(value)}`,
      );
    }
  });
}

test('collector audio lead allowance accepts extra audio before the first video keyframe', () => {
  const input = coverageFixture({ start: 0.6 });
  input.audioStartTime = 0;
  input.audioSampleCount += 0.6 * input.sampleRate;
  assert.throws(() => assertMediaCoverage(input), /coverage.*start/i);
  const result = assertMediaCoverage({ ...input, maxAudioLeadSeconds: 2.1 });
  assert.equal(result.startOffset, -0.6);
  assert.equal(result.maxAudioLeadSeconds, 2.1);
});

test('collector audio lead allowance rejects audio beyond its explicit budget', () => {
  const input = coverageFixture({ start: 2.2 });
  input.audioStartTime = 0;
  input.audioSampleCount += 2.2 * input.sampleRate;
  assert.throws(
    () => assertMediaCoverage({ ...input, maxAudioLeadSeconds: 2.1 }),
    /coverage.*start.*2100 ms/i,
  );
});

for (const [edge, missingSeconds] of [
  ['start', 0.25],
  ['end', 0.25],
  ['end', 7],
]) {
  test(`collector audio lead allowance still rejects ${missingSeconds}s missing ${edge} audio`, () => {
    const input = coverageFixture();
    input.audioSampleCount -= missingSeconds * input.sampleRate;
    if (edge === 'start') input.audioStartTime += missingSeconds;
    assert.throws(
      () => assertMediaCoverage({ ...input, maxAudioLeadSeconds: 2.1 }),
      new RegExp(`coverage.*${edge}.*100 ms`, 'i'),
    );
  });
}

test('audio lead allowance defaults to the selected coverage tolerance', () => {
  const input = coverageFixture();
  input.audioStartTime -= 0.125;
  input.audioSampleCount += 0.125 * input.sampleRate;
  const result = assertMediaCoverage({ ...input, toleranceSeconds: 0.25 });
  assert.equal(result.maxAudioLeadSeconds, 0.25);
});
