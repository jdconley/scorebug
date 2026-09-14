import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { command } from './media-tools.mjs';
import { decodeFrameCodes, frameCodeReadFilter } from './media-frame-codes.mjs';
import { analyzeMediaSync, assertMediaSync } from './media-sync.mjs';

export function measureFreshCadence(codes, times) {
  assert.ok(codes.length === times.length && codes.length >= 180, 'Insufficient frame samples');
  for (let i = 0; i < times.length; i++) {
    assert.ok(
      Number.isFinite(times[i]) && (!i || times[i] > times[i - 1]),
      'Invalid video timestamp',
    );
    assert.ok(
      Number.isInteger(codes[i]) && (!i || codes[i] >= codes[i - 1]),
      'Invalid source frame ID',
    );
  }
  const unique = new Set(codes).size;
  const duration = times.at(-1) - times[0] + 1 / 30;
  const freshFps = unique / duration;
  const sourceFrameLoss = 1 - unique / (codes.at(-1) - codes[0] + 1);
  let windows = 0;
  let healthy = 0;
  let minimumWindowFps = Infinity;
  let left = 0;
  let right = 0;
  for (let start = times[0]; start + 5 <= times.at(-1) + 1 / 30; start += 1) {
    while (times[left] < start - 1e-6) left++;
    while (right < times.length && times[right] < start + 5 - 1e-6) right++;
    const fps = new Set(codes.slice(left, right)).size / 5;
    minimumWindowFps = Math.min(minimumWindowFps, fps);
    windows++;
    if (fps >= 24) healthy++;
  }
  assert.ok(
    windows > 0 && healthy / windows >= 0.99,
    'Five-second fresh-frame window floor failed',
  );
  for (let i = 1; i < times.length; i++) {
    assert.ok(
      Math.abs(times[i] - times[i - 1] - (codes[i] - codes[i - 1]) / 30) <= 0.002,
      'Video timestamp discontinuity differs from source frame spacing',
    );
  }
  assert.ok(freshFps >= 24, 'Average fresh-frame floor failed');
  assert.ok(sourceFrameLoss < 0.01, 'Source frame loss exceeded 1%');
  return {
    duration,
    decodedFrames: codes.length,
    freshFrames: unique,
    freshFps,
    sourceFrameLoss,
    windows,
    healthyWindowFraction: healthy / windows,
    minimumWindowFps,
  };
}

export async function measureSoak({
  path,
  directory,
  ffmpeg,
  ffprobe,
  seconds,
  initialOverlay,
  finalOverlay,
}) {
  const run = async (binary, args, label) => {
    const result = await command(binary, args, 180_000);
    assert.ok(result.ok, `${label} failed`);
    return result.stdout;
  };
  await run(
    ffmpeg,
    ['-v', 'error', '-xerror', '-i', path, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'],
    'Soak full decode',
  );
  const frames = async (stream, entries) =>
    (
      await run(
        ffprobe,
        [
          '-v',
          'error',
          '-select_streams',
          stream,
          '-show_frames',
          '-show_entries',
          `frame=${entries}:frame_side_data=`,
          '-of',
          'compact=p=0:nk=0',
          path,
        ],
        `${stream} timestamps`,
      )
    )
      .trim()
      .split('\n')
      .filter(Boolean)
      .map((line) =>
        Object.fromEntries(
          line
            .split('|')
            .filter((entry) => entry.includes('='))
            .map((entry) => {
              const [key, value] = entry.split('=');
              return [key, Number(value)];
            }),
        ),
      );
  const videoFrames = await frames('v:0', 'best_effort_timestamp_time');
  const videoTimes = videoFrames.map((frame) => Number(frame.best_effort_timestamp_time));
  const rawCodes = join(directory, 'soak-codes.raw');
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-i',
      path,
      '-an',
      '-vf',
      frameCodeReadFilter,
      '-fps_mode',
      'passthrough',
      '-f',
      'rawvideo',
      rawCodes,
    ],
    'Soak source frame IDs',
  );
  const codes = decodeFrameCodes(await readFile(rawCodes));
  const cadence = measureFreshCadence(codes, videoTimes);
  assert.ok(cadence.duration >= seconds - 0.1, 'Soak recording ended early');

  const audioFrames = await frames('a:0', 'best_effort_timestamp_time,nb_samples');
  assert.ok(audioFrames.length, 'Missing decoded audio');
  const audioStream = JSON.parse(
    await run(
      ffprobe,
      [
        '-v',
        'error',
        '-select_streams',
        'a:0',
        '-show_entries',
        'stream=sample_rate',
        '-of',
        'json',
        path,
      ],
      'Audio sample rate',
    ),
  ).streams[0];
  const sampleRate = Number(audioStream?.sample_rate);
  assert.ok(Number.isInteger(sampleRate) && sampleRate >= 16000, 'Invalid audio sample rate');
  const audioStartTime = Number(audioFrames[0].best_effort_timestamp_time);
  assert.ok(Number.isFinite(audioStartTime), 'Invalid audio start timestamp');
  let sampleCount = 0;
  for (const frame of audioFrames) {
    const timestamp = Number(frame.best_effort_timestamp_time);
    assert.ok(
      Number.isFinite(timestamp) &&
        Math.abs(timestamp - audioStartTime - sampleCount / sampleRate) <= 0.002,
      'Audio timestamp discontinuity exceeds mux timestamp quantization',
    );
    assert.ok(Number.isInteger(frame.nb_samples) && frame.nb_samples > 0, 'Invalid audio frame');
    sampleCount += frame.nb_samples;
  }
  const rawAudio = join(directory, 'soak-audio.f32');
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-i',
      path,
      '-vn',
      '-ac',
      '1',
      '-ar',
      String(sampleRate),
      '-c:a',
      'pcm_f32le',
      '-f',
      'f32le',
      rawAudio,
    ],
    'Soak audio samples',
  );
  const bytes = await readFile(rawAudio);
  assert.equal(
    bytes.byteLength,
    sampleCount * 4,
    'Decoded audio sample count disagrees with timestamps',
  );
  const audioSamples = new Float32Array(bytes.buffer, bytes.byteOffset, sampleCount);
  const sync = analyzeMediaSync({ codes, videoTimes, audioSamples, sampleRate, audioStartTime });
  assertMediaSync(sync);
  assert.ok(
    sync.matchedPulseCount >= Math.floor(seconds / 2) - 2,
    'Insufficient sync-marker coverage',
  );

  const overlay = async (at, label) => {
    const destination = join(directory, `soak-overlay-${label}.raw`);
    await run(
      ffmpeg,
      [
        '-v',
        'error',
        '-y',
        '-ss',
        String(at),
        '-i',
        path,
        '-frames:v',
        '1',
        '-vf',
        'crop=500:80:0:620,format=gray',
        '-f',
        'rawvideo',
        destination,
      ],
      `Soak ${label} overlay`,
    );
    return readFile(destination);
  };
  const distance = (a, b) => {
    assert.equal(a.length, b.length);
    let changed = 0;
    for (let i = 0; i < a.length; i++) if (a[i] > 180 !== b[i] > 180) changed++;
    return changed;
  };
  const beginning = await overlay(1, 'beginning');
  const ending = await overlay(seconds - 2, 'ending');
  assert.ok(distance(initialOverlay, finalOverlay) > 20, 'Reference scores did not differ');
  assert.ok(
    distance(beginning, initialOverlay) < distance(beginning, finalOverlay) / 2,
    'Soak initial score incorrect',
  );
  assert.ok(
    distance(ending, finalOverlay) < distance(ending, initialOverlay) / 2,
    'Soak final score incorrect',
  );
  return { ...cadence, sync, scoreChanged: true };
}
