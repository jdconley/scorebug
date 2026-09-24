import assert from 'node:assert/strict';
import { estimateAudioAlignment } from './audio-alignment.mjs';

/** Three source-identity-anchored waveform samples; not all-audio fidelity or latency. */
export function qualifyNaturalAudio({
  sourceSamples,
  targetSamples,
  codes,
  videoTimes,
  audioStartTime,
  sourceAudioStartTime,
}) {
  const rate = 8000,
    window = rate,
    radius = 1200,
    guard = 32;
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
  const indices = [30, Math.floor((30 + last) / 2), last];
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
  for (let i = 1; i < probes.length; i++) {
    assert(
      probes[i].sourceStartSeconds - probes[i - 1].sourceStartSeconds >= 1,
      'Audio windows must be separated',
    );
    assert(
      probes[i].targetVideoSeconds - probes[i - 1].targetVideoSeconds >= 1,
      'Target windows must be separated',
    );
  }
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
