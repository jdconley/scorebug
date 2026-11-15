// Source marker identity is shared with the 30 fps frame-number barcode. Each
// two-second epoch has its own frequency, so a whole-epoch delay cannot alias.
export function sourceAudioExpression() {
  return "aevalsrc='if(lt(mod(t,2),0.2),0.5*sin(2*PI*(1000+20*floor(t/2))*t),0)':s=48000";
}

const SOURCE_FPS = 30;
const MARKER_FRAMES = 60;

function detectPulses(samples, sampleRate, startTime, firstVideoTime) {
  // A 40 ms quiet interval bridges the sine's zero crossings and AAC ringing.
  const quietSamples = Math.round(sampleRate * 0.04);
  const edgeSamples = Math.round(sampleRate * 0.02);
  const segments = [];
  let start = null;
  let lastActive = -1;
  for (let i = 0; i < samples.length; i++) {
    if (!Number.isFinite(samples[i])) throw new Error('Audio samples must be finite');
    if (Math.abs(samples[i]) >= 0.06) {
      if (start === null) start = i;
      lastActive = i;
    } else if (start !== null && i - lastActive >= quietSamples) {
      segments.push({ start, end: lastActive + 1, openAtEnd: false });
      start = null;
    }
  }
  if (start !== null) segments.push({ start, end: lastActive + 1, openAtEnd: true });

  const pulses = [];
  for (const segment of segments) {
    // Capture edges may cut a pulse at an arbitrary phase; omit only those edges.
    if (segment.start < edgeSamples || segment.end > samples.length - edgeSamples) continue;
    const duration = (segment.end - segment.start) / sampleRate;
    // Acquisition may leave one short first fragment before video starts. Its
    // identity remains unqualified; never omit a later or overlapping segment.
    if (
      segment === segments[0] &&
      duration < 0.15 &&
      startTime + segment.end / sampleRate < firstVideoTime
    )
      continue;
    // EOF can cut a marker before AAC padding completes the 40 ms quiet interval.
    // Leave only that short unfinished tail unqualified; fully covered marker
    // checks below still reject missing expected content earlier in the capture.
    if (segment.openAtEnd && duration < 0.15) continue;
    if (duration < 0.15 || duration > 0.25) throw new Error('Invalid audio marker pulse duration');
    const from = segment.start + Math.round(sampleRate * 0.03);
    const to = segment.end - Math.round(sampleRate * 0.03);
    const crossings = [];
    for (let i = from + 1; i < to; i++) {
      if (samples[i - 1] <= 0 && samples[i] > 0) {
        crossings.push(i - 1 - samples[i - 1] / (samples[i] - samples[i - 1]));
      }
    }
    if (crossings.length < 20) throw new Error('Ambiguous audio marker frequency');
    const frequency = ((crossings.length - 1) * sampleRate) / (crossings.at(-1) - crossings[0]);
    const id = Math.round((frequency - 1000) / 20);
    if (id < 0 || id * MARKER_FRAMES > 65535 || Math.abs(frequency - (1000 + 20 * id)) > 5) {
      throw new Error(`Ambiguous audio marker frequency: ${frequency.toFixed(2)} Hz`);
    }
    if (pulses.length && id !== pulses.at(-1).id + 1) {
      throw new Error(
        `Audio marker sequence missing, duplicated, or regressed: ${pulses.at(-1).id} -> ${id}`,
      );
    }
    pulses.push({ id, frequency, audioTime: startTime + segment.start / sampleRate });
  }
  return pulses;
}

/**
 * Measure audio-onset PTS minus the corresponding source-identity video PTS.
 * videoTimes must be per-frame presentation timestamps from the SAME decoded
 * frames as codes, in seconds. audioStartTime is the first decoded PCM sample's
 * PTS; callers must preserve the common media timeline (no independent reset).
 * This fixture is bounded to the 16-bit, 30 fps source barcode, before wrap.
 */
export function analyzeMediaSync({
  codes,
  videoTimes,
  audioSamples,
  sampleRate = 48000,
  audioStartTime = 0,
}) {
  if (!codes?.length || codes.length !== videoTimes?.length)
    throw new Error('Invalid video marker/timestamp length');
  if (
    !(audioSamples instanceof Float32Array) ||
    !audioSamples.length ||
    !Number.isFinite(sampleRate) ||
    sampleRate < 16000 ||
    !Number.isFinite(audioStartTime)
  ) {
    throw new Error('Invalid audio samples, sample rate, or start timestamp');
  }
  for (let i = 0; i < codes.length; i++) {
    if (
      !Number.isInteger(codes[i]) ||
      codes[i] < 0 ||
      codes[i] > 65535 ||
      !Number.isFinite(videoTimes[i])
    ) {
      throw new Error('Invalid video marker code or non-finite presentation timestamp');
    }
    if (i && (codes[i] <= codes[i - 1] || videoTimes[i] <= videoTimes[i - 1])) {
      throw new Error(
        'Video markers and timestamps must be strictly monotonic; duplicate/regressed frame',
      );
    }
    if (
      i &&
      Math.abs(videoTimes[i] - videoTimes[i - 1] - (codes[i] - codes[i - 1]) / SOURCE_FPS) > 0.002
    ) {
      throw new Error('Video presentation timestamp cadence does not match source frame identity');
    }
  }
  const pulses = detectPulses(audioSamples, sampleRate, audioStartTime, videoTimes[0]);
  if (pulses.length < 3) throw new Error('At least three complete audio markers required');
  function markerVideoTime(frame) {
    let low = 0;
    let high = codes.length - 1;
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      if (codes[middle] < frame) low = middle + 1;
      else high = middle;
    }
    if (codes[low] === frame) return videoTimes[low];
    const gap = codes[low] - codes[low - 1];
    const ptsGap = videoTimes[low] - videoTimes[low - 1];
    if (gap > 6 || ptsGap > 0.25)
      throw new Error('No nearby video bracket: marker frame gap too large');
    return videoTimes[low - 1] + ((frame - codes[low - 1]) / gap) * ptsGap;
  }
  const matched = [];
  for (const pulse of pulses) {
    const frame = pulse.id * MARKER_FRAMES;
    // Only a leading or trailing audio marker may fall outside video coverage.
    if (frame < codes[0] || frame > codes.at(-1)) continue;
    const videoTime = markerVideoTime(frame);
    matched.push({
      ...pulse,
      sourceTime: frame / SOURCE_FPS,
      videoTime,
      offset: pulse.audioTime - videoTime,
    });
  }
  if (matched.length < 3) throw new Error('At least three matched audio/video markers required');
  const offsets = matched.map((pulse) => pulse.offset);
  const ordered = [...offsets].sort((a, b) => a - b);
  const middle = Math.floor(ordered.length / 2);
  const medianOffset =
    ordered.length % 2 ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2;
  // Surviving pulses alone cannot prove coverage: a missing first/last complete
  // pulse would otherwise look like an ordinary capture edge. Project every
  // covered video marker onto the audio timeline using the measured offset.
  const presentIds = new Set(pulses.map((pulse) => pulse.id));
  const audioEndTime = audioStartTime + audioSamples.length / sampleRate;
  let expectedPulseCount = 0;
  const firstId = Math.ceil(codes[0] / MARKER_FRAMES);
  const lastId = Math.floor((codes.at(-1) - 6) / MARKER_FRAMES);
  for (let id = firstId; id <= lastId; id++) {
    const onset = markerVideoTime(id * MARKER_FRAMES) + medianOffset;
    if (onset < audioStartTime + 0.02 || onset + 0.2 > audioEndTime - 0.02) continue;
    expectedPulseCount++;
    if (!presentIds.has(id)) throw new Error(`Missing fully covered audio marker ${id}`);
  }
  const drift = offsets.at(-1) - offsets[0];
  return {
    pulseCount: pulses.length,
    matchedPulseCount: matched.length,
    expectedPulseCount,
    maxAbsOffset: Math.max(...offsets.map(Math.abs)),
    medianOffset,
    drift,
    driftPpm: (drift / (matched.at(-1).sourceTime - matched[0].sourceTime)) * 1e6,
    offsets,
    pulses: matched,
  };
}

// This 100 ms budget qualifies the local test fixture; it is not a product SLA.
export function assertMediaSync(metrics, { maxAbsOffset = 0.1 } = {}) {
  if (
    !Number.isFinite(maxAbsOffset) ||
    maxAbsOffset < 0 ||
    !Number.isFinite(metrics?.maxAbsOffset) ||
    metrics.maxAbsOffset < 0 ||
    !Number.isInteger(metrics.matchedPulseCount) ||
    metrics.matchedPulseCount < 3
  ) {
    throw new Error('Invalid media synchronization metrics or budget');
  }
  if (metrics.maxAbsOffset > maxAbsOffset) {
    throw new Error(
      `A/V offset ${(metrics.maxAbsOffset * 1000).toFixed(1)} ms exceeds local ${maxAbsOffset * 1000} ms budget`,
    );
  }
  return metrics;
}

/**
 * Require decoded audio and video to cover the same common PTS interval.
 * PCM sample count measures actual decoded coverage; overlapping markers alone
 * cannot detect a missing audio head or tail. The default budget allows bounded
 * AAC padding. Live collectors that join before the next video keyframe may
 * explicitly allow extra leading audio, without allowing missing audio. Keep
 * this check alongside assertMediaSync's marker checks.
 */
export function assertMediaCoverage({
  videoTimes,
  audioStartTime,
  audioSampleCount,
  sampleRate,
  framesPerSecond = SOURCE_FPS,
  toleranceSeconds = 0.1,
  maxAudioLeadSeconds = toleranceSeconds,
}) {
  if (
    !Number.isInteger(videoTimes?.length) ||
    videoTimes.length < 1 ||
    !Number.isFinite(audioStartTime) ||
    !Number.isSafeInteger(audioSampleCount) ||
    audioSampleCount < 1 ||
    !Number.isSafeInteger(sampleRate) ||
    sampleRate < 1 ||
    !Number.isSafeInteger(framesPerSecond) ||
    framesPerSecond < 1 ||
    !Number.isFinite(toleranceSeconds) ||
    toleranceSeconds < 0 ||
    !Number.isFinite(maxAudioLeadSeconds) ||
    maxAudioLeadSeconds < 0
  ) {
    throw new Error('Invalid media coverage timestamps, sample count, rates, or tolerance');
  }
  for (let i = 0; i < videoTimes.length; i++) {
    if (!Number.isFinite(videoTimes[i])) {
      throw new Error('Media coverage video timestamps must be finite');
    }
    if (i && videoTimes[i] <= videoTimes[i - 1]) {
      throw new Error('Media coverage video timestamps must be strictly monotonic');
    }
  }
  const videoStartTime = videoTimes[0];
  const videoEndTime = videoTimes[videoTimes.length - 1] + 1 / framesPerSecond;
  const audioEndTime = audioStartTime + audioSampleCount / sampleRate;
  const startOffset = audioStartTime - videoStartTime;
  const endOffset = audioEndTime - videoEndTime;
  if (![videoEndTime, audioEndTime, startOffset, endOffset].every(Number.isFinite)) {
    throw new Error('Invalid non-finite media coverage endpoints or differences');
  }
  for (const [edge, offset] of [
    ['start', startOffset],
    ['end', endOffset],
  ]) {
    const budget = edge === 'start' && offset < 0 ? maxAudioLeadSeconds : toleranceSeconds;
    if (Math.abs(offset) > budget) {
      throw new Error(
        `Audio/video coverage ${edge} difference ${(offset * 1000).toFixed(1)} ms exceeds ${budget * 1000} ms budget`,
      );
    }
  }
  return {
    videoStartTime,
    videoEndTime,
    audioStartTime,
    audioEndTime,
    startOffset,
    endOffset,
    toleranceSeconds,
    maxAudioLeadSeconds,
  };
}
