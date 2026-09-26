import assert from 'node:assert/strict';
import { AUDIO_ALIGNMENT_SUPPORT_SAMPLES, estimateAudioAlignment } from './audio-alignment.mjs';

/** Source-identity-anchored waveform samples; not all-audio fidelity or latency. */
export function qualifyNaturalAudio({
  sourceSamples,
  targetSamples,
  codes,
  videoTimes,
  audioStartTime,
  sourceAudioStartTime,
  additionalSourceFrames = [],
}) {
  const rate = 8000,
    window = rate,
    radius = 1200,
    guard = AUDIO_ALIGNMENT_SUPPORT_SAMPLES;
  for (const samples of [sourceSamples, targetSamples]) {
    assert(
      samples instanceof Float32Array || samples instanceof Float64Array,
      'Typed PCM required',
    );
    assert(samples.every(Number.isFinite), 'Nonfinite audio');
  }
  assert(
    Number.isFinite(audioStartTime) && Number.isFinite(sourceAudioStartTime),
    'Finite audio origins required',
  );
  assert(Array.isArray(codes) && Array.isArray(videoTimes) && codes.length === videoTimes.length);
  assert(
    codes.length >= 127,
    'At least 127 video frames required for separated audio windows and search support',
  );
  for (let i = 0; i < codes.length; i++) {
    assert(
      Number.isSafeInteger(codes[i]) && codes[i] >= 0 && codes[i] < 65536,
      'Invalid source identity',
    );
    assert(Number.isFinite(videoTimes[i]), 'Invalid video time');
    if (i)
      assert(
        codes[i] > codes[i - 1] && videoTimes[i] > videoTimes[i - 1],
        'Ordered identities/times required',
      );
  }
  // Leave 200 ms beyond the last reference window for search/rounding support.
  const last = codes.length - 37;
  const baseline = [30, Math.floor((30 + last) / 2), last];
  for (let i = 1; i < baseline.length; i++) {
    assert(
      (codes[baseline[i]] - codes[baseline[i - 1]]) / 30 >= 1,
      'Audio windows must be separated',
    );
    assert(
      videoTimes[baseline[i]] - videoTimes[baseline[i - 1]] >= 1,
      'Target windows must be separated',
    );
  }
  assert(
    Array.isArray(additionalSourceFrames) && additionalSourceFrames.length <= 256,
    'Bounded additional audio anchors required',
  );
  const extra = additionalSourceFrames.map((frame) => {
    assert(
      Number.isSafeInteger(frame) && frame >= 0 && frame < 65536,
      'Valid additional audio anchor required',
    );
    const index = codes.indexOf(frame);
    assert(index >= 0 && index <= last, 'Missing additional audio anchor coverage');
    return index;
  });
  // Extra event windows may overlap a baseline window. Keep every requested
  // anchor without treating overlapping windows as independent observations.
  const indices = [...new Set([...baseline, ...extra])].sort((a, b) => a - b);
  const probes = indices.map((index) => {
    const sourceTime = codes[index] / 30;
    const referenceStart = Math.round((sourceTime - sourceAudioStartTime) * rate);
    const referenceTime = sourceAudioStartTime + referenceStart / rate;
    const expectedTargetTime = videoTimes[index] + referenceTime - sourceTime;
    const targetCenter = Math.round((expectedTargetTime - audioStartTime) * rate);
    const targetStart = targetCenter - radius - guard;
    assert(
      referenceStart >= 0 && referenceStart + window <= sourceSamples.length,
      'Missing source audio support',
    );
    assert(
      targetStart >= 0 && targetStart + window + 2 * (radius + guard) <= targetSamples.length,
      'Missing target audio support',
    );
    const match = estimateAudioAlignment({
      reference: sourceSamples.slice(referenceStart, referenceStart + window),
      target: targetSamples.slice(targetStart, targetStart + window + 2 * (radius + guard)),
      maxLagSamples: radius,
    });
    const roundingOffsetSeconds = audioStartTime + targetCenter / rate - expectedTargetTime;
    return {
      sourceFrame: codes[index],
      sourceStartSeconds: referenceTime,
      targetVideoSeconds: videoTimes[index],
      roundingOffsetSeconds,
      ...match,
      audioVideoLagSeconds: match.lagSamples / rate + roundingOffsetSeconds,
    };
  });
  const lagSpreadSeconds =
    Math.max(...probes.map((p) => p.audioVideoLagSeconds)) -
    Math.min(...probes.map((p) => p.audioVideoLagSeconds));
  const report = {
    probes,
    lagSpreadSeconds,
    passed:
      probes.every(
        (p) =>
          p.correlation >= 0.98 &&
          !p.ambiguous &&
          !p.atSearchBoundary &&
          Math.abs(p.audioVideoLagSeconds) <= 0.1,
      ) && lagSpreadSeconds <= 0.02,
  };
  assert(report.passed, `Natural audio alignment rejected: ${JSON.stringify(report)}`);
  return report;
}

/** Sample every measured phase at its head/tail, plus a five-second source grid. */
export function measuredAudioProbeFrames({ phases, codes }) {
  assert(
    Array.isArray(phases) && [2, 3, 4, 5].includes(phases.length),
    'Complete measured phases required',
  );
  assert(
    Array.isArray(codes) && codes.length >= 127 && codes.length < 65536,
    'Bounded decoded source range required',
  );
  for (let i = 0; i < codes.length; i++)
    assert(
      Number.isSafeInteger(codes[i]) &&
        codes[i] >= 0 &&
        codes[i] < 65536 &&
        (i === 0 || codes[i] > codes[i - 1]),
      'Ordered decoded identities required',
    );
  const anchors = [];
  for (const [index, phase] of phases.entries()) {
    const { firstFrame, lastFrame } = phase;
    assert(
      Number.isSafeInteger(firstFrame) &&
        Number.isSafeInteger(lastFrame) &&
        firstFrame >= 0 &&
        lastFrame < 65536 &&
        lastFrame >= firstFrame &&
        (index === 0 || firstFrame > phases[index - 1].lastFrame),
      'Ordered phase identities required',
    );
    const firstVisible = index === 0 ? codes[0] : firstFrame;
    assert(
      firstVisible >= firstFrame && lastFrame - firstVisible >= 59,
      'Insufficient phase audio coverage',
    );
    anchors.push(firstVisible + 15, lastFrame - 44);
  }
  assert.equal(phases.at(-1).lastFrame, codes.at(-1), 'Complete measured media tail required');
  for (let frame = codes[0] + 30; frame <= codes.at(-1) - 37; frame += 150) anchors.push(frame);
  const result = [...new Set(anchors)].sort((a, b) => a - b);
  assert(result.length <= 256, 'Bounded measured audio anchors required');
  for (const frame of result) {
    const index = codes.indexOf(frame);
    assert(index >= 0 && index <= codes.length - 37, 'Missing requested measured audio anchor');
  }
  return result;
}
