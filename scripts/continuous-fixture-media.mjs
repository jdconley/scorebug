import assert from 'node:assert/strict';
import { assertMediaCoverage } from './media-sync.mjs';
import { decodeFixtureBarcodes } from './video-observation-qualification.mjs';

/** All-frame media integrity for a prepared 30 fps fixture, not live latency. */
export function verifyContinuousFixtureMedia({ frames, bytes, expectedFrames, sampleRate }) {
  assert.ok(Number.isSafeInteger(expectedFrames) && expectedFrames > 1 && expectedFrames < 65536);
  assert.ok(
    Number.isSafeInteger(sampleRate) && sampleRate > 0,
    'Validated audio sample rate required',
  );
  assert.ok(Array.isArray(frames));
  const video = frames.filter((frame) => frame.media_type === 'video');
  const audio = frames.filter((frame) => frame.media_type === 'audio');
  const codes = decodeFixtureBarcodes(bytes);
  assert.equal(video.length, expectedFrames, 'Complete decoded video count');
  assert.equal(codes.length, expectedFrames, 'Complete decoded identity count');
  assert.ok(audio.length > 0, 'Audio frames required');
  const times = video.map((frame) => Number(frame.best_effort_timestamp_time));
  let maximumVideoGap = 0;
  for (let i = 0; i < expectedFrames; i++) {
    assert.equal(codes[i], i, `Missing, repeated or reordered source frame ${i}`);
    assert.ok(Number.isFinite(times[i]), 'Finite video time');
    if (i) {
      const gap = times[i] - times[i - 1];
      assert.ok(gap > 0 && gap <= 0.035, 'Video cadence gap');
      maximumVideoGap = Math.max(maximumVideoGap, gap);
    }
  }
  assert.ok(times[0] >= 0 && times[0] <= 0.1, 'Video begins at prepared origin');
  const duration = times.at(-1) - times[0] + 1 / 30;
  assert.ok(Math.abs(duration - expectedFrames / 30) <= 0.035, 'Complete declared video duration');
  const audioStartTime = Number(audio[0].best_effort_timestamp_time);
  let audioSamples = 0,
    previousEnd,
    maximumAudioDiscontinuity = 0,
    maximumAudioTimelineError = 0;
  for (const frame of audio) {
    const time = Number(frame.best_effort_timestamp_time),
      count = Number(frame.nb_samples);
    assert.ok(
      Number.isFinite(time) && Number.isSafeInteger(count) && count > 0,
      'Valid audio frame',
    );
    const timelineError = Math.abs(time - (audioStartTime + audioSamples / sampleRate));
    assert.ok(timelineError <= 0.002, 'Cumulative audio timeline discontinuity');
    maximumAudioTimelineError = Math.max(maximumAudioTimelineError, timelineError);
    if (previousEnd !== undefined) {
      const gap = Math.abs(time - previousEnd);
      // RTMP timestamps have millisecond precision. Preserve internal gap/overlap
      // detection while allowing their rounding of AAC frame boundaries.
      assert.ok(gap <= 0.002, 'Audio frame gap or overlap');
      maximumAudioDiscontinuity = Math.max(maximumAudioDiscontinuity, gap);
    }
    audioSamples += count;
    assert.ok(Number.isSafeInteger(audioSamples), 'Bounded audio sample total');
    previousEnd = time + count / sampleRate;
  }
  const coverage = assertMediaCoverage({
    videoTimes: times,
    audioStartTime,
    audioSampleCount: audioSamples,
    sampleRate,
  });
  assert.ok(Math.abs(previousEnd - coverage.videoEndTime) <= 0.1, 'Actual audio tail coverage');
  return {
    videoFrames: video.length,
    firstSourceFrame: codes[0],
    lastSourceFrame: codes.at(-1),
    duration,
    audioSamples,
    audioFrames: audio.length,
    maximumVideoGap,
    maximumAudioDiscontinuity,
    maximumAudioTimelineError,
    sampleRate,
    coverage,
  };
}
