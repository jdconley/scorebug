// Sampled waveform alignment, not an all-audio fidelity or delivery-latency proof.
// Target includes the declared search radius and 32 interpolation guard samples
// on both sides. Positive lag means matching target content occurs later.
export function estimateAudioAlignment({ reference, target, maxLagSamples }) {
  for (const samples of [reference, target]) {
    if (!(samples instanceof Float32Array || samples instanceof Float64Array)) {
      throw new TypeError('Audio samples must be floating-point typed arrays');
    }
    if (!samples.every(Number.isFinite)) throw new Error('Nonfinite audio sample');
  }
  if (reference.length < 128 || reference.length > 48000) {
    throw new RangeError('Reference window must contain 128–48000 samples');
  }
  if (!Number.isInteger(maxLagSamples) || maxLagSamples < 0 || maxLagSamples > 2400) {
    throw new RangeError('Search radius must be an integer from 0 to 2400');
  }
  const guard = 32,
    origin = maxLagSamples + guard,
    n = reference.length;
  if (target.length !== n + 2 * origin) {
    throw new RangeError('Target must include exactly the search and interpolation support');
  }
  const mean = reference.reduce((sum, value) => sum + value, 0) / n;
  const centered = Float64Array.from(reference, (value) => value - mean);
  const referenceEnergy = centered.reduce((sum, value) => sum + value * value, 0);
  if (!Number.isFinite(referenceEnergy) || referenceEnergy / n <= 1e-12)
    throw new Error('Degenerate reference audio');
  const targetMean = target.reduce((sum, value) => sum + value, 0) / target.length;
  const targetCentered = Float64Array.from(target, (value) => value - targetMean);
  const count = n + 2 * maxLagSamples;
  const interpolated = new Float64Array(count);
  const sums = new Float64Array(count + 1),
    energies = new Float64Array(count + 1);
  const kernel = new Float64Array(65);
  const scores = new Float64Array(2 * maxLagSamples * 32 + 1).fill(-Infinity);
  let lagSamples = 0,
    bestCorrelation = -Infinity;
  // Search every integer lag at every fractional phase. Refining only the best
  // integer peak can choose the wrong delay for high-frequency/multitone audio.
  // The bounded input sizes cap work; no padding is synthesized or extrapolated.
  for (let phase = 0; phase < (maxLagSamples === 0 ? 1 : 32); phase++) {
    const fraction = phase / 32;
    if (phase === 0) interpolated.set(targetCentered.subarray(guard, guard + count));
    else {
      let sum = 0;
      for (let k = -guard; k <= guard; k++) {
        const distance = k - fraction;
        const sinc = Math.sin(Math.PI * distance) / (Math.PI * distance);
        const hann = 0.5 - 0.5 * Math.cos((2 * Math.PI * (k + guard)) / 64);
        sum += kernel[k + guard] = sinc * hann;
      }
      for (let k = 0; k < kernel.length; k++) kernel[k] /= sum;
      for (let i = 0; i < count; i++) {
        let value = 0;
        for (let k = 0; k < kernel.length; k++) value += targetCentered[i + k] * kernel[k];
        interpolated[i] = value;
      }
    }
    for (let i = 0; i < count; i++) {
      sums[i + 1] = sums[i] + interpolated[i];
      energies[i + 1] = energies[i] + interpolated[i] ** 2;
    }
    for (let offset = 0; offset <= 2 * maxLagSamples; offset++) {
      const lag = offset - maxLagSamples + fraction;
      if (lag > maxLagSamples) continue;
      const windowSum = sums[offset + n] - sums[offset];
      const energy = energies[offset + n] - energies[offset] - windowSum ** 2 / n;
      if (!Number.isFinite(energy) || energy / n <= 1e-12) continue;
      let dot = 0;
      for (let i = 0; i < n; i++) dot += centered[i] * interpolated[offset + i];
      const score = dot / Math.sqrt(referenceEnergy * energy);
      if (Number.isFinite(score)) scores[offset * 32 + phase] = score;
      if (Number.isFinite(score) && score > bestCorrelation) {
        bestCorrelation = score;
        lagSamples = lag;
      }
    }
  }
  if (!Number.isFinite(bestCorrelation)) throw new Error('Degenerate target audio');
  // A competing local peak at least one sample away makes delay ambiguous
  // when its normalized correlation is within 0.005 of the winning peak.
  // This conservative heuristic does not prove uniqueness beyond the search
  // range, or establish timing for arbitrary repetitive source content.
  const bestIndex = Math.round((lagSamples + maxLagSamples) * 32);
  let competingPeakCorrelation = -Infinity;
  for (let i = 0; i < scores.length; i++) {
    if (Math.abs(i - bestIndex) < 32) continue;
    if (scores[i] >= (scores[i - 1] ?? -Infinity) && scores[i] >= (scores[i + 1] ?? -Infinity)) {
      competingPeakCorrelation = Math.max(competingPeakCorrelation, scores[i]);
    }
  }
  const peakMargin = Number.isFinite(competingPeakCorrelation)
    ? bestCorrelation - competingPeakCorrelation
    : null;
  return {
    lagSamples,
    correlation: Math.max(-1, Math.min(1, bestCorrelation)),
    atSearchBoundary: Math.abs(lagSamples) === maxLagSamples,
    competingPeakCorrelation: Number.isFinite(competingPeakCorrelation)
      ? competingPeakCorrelation
      : null,
    peakMargin,
    ambiguous: peakMargin !== null && peakMargin < 0.005,
    method: 'normalized correlation; 65-tap Hann sinc; exhaustive 1/32-sample grid',
  };
}
