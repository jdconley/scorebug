import assert from 'node:assert/strict';
import { measuredUplinkProfiles } from './native-measured-uplink.mjs';
import { createReadStream, constants } from 'node:fs';
import { copyFile, lstat, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, isAbsolute } from 'node:path';
import { fixtureFrameID } from './video-observation-qualification.mjs';
import { verifyContinuousFixtureMedia } from './continuous-fixture-media.mjs';

export function nativeFileFixtureOptions({ environment, streaming, holdSeconds }) {
  const path = environment.SCOREBUG_TEST_FILE_INPUT;
  assert.equal(
    environment.SCOREBUG_TEST_FILE_CAPTURE,
    undefined,
    'App file flag is derived only from a validated host input',
  );
  if (path === undefined) return null;
  assert(typeof path === 'string' && isAbsolute(path), 'Absolute local file input required');
  assert.equal(streaming, true, 'File input requires native streaming');
  assert(
    Number.isSafeInteger(holdSeconds) && holdSeconds >= 12 && holdSeconds <= 600,
    'Invalid file hold',
  );
  for (const key of [
    'SCOREBUG_TEST_DIRECT_RTMP_RECORDER',
    'SCOREBUG_TEST_RELAY_PUBLICATION',
    'SCOREBUG_TEST_WORKER_PROCESSING',
  ])
    assert.equal(environment[key], '1', `File input requires ${key}`);
  for (const key of [
    'SCOREBUG_TEST_MOTION_FIXTURE',
    'SCOREBUG_FIXTURE_FAIL_AFTER',
    'SCOREBUG_TEST_NATIVE_QUALITY',
    'SCOREBUG_TEST_NATIVE_CONFIRMATION',
    'SCOREBUG_TEST_PROFILE_TRANSITIONS',
    'SCOREBUG_TEST_ADAPTIVE_PROFILES',
    'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
    'SCOREBUG_TEST_UPLINK_PROXY_PORT',
    'SCOREBUG_TEST_DECODER_STALL',
    'SCOREBUG_TEST_CADENCE_REPORTS',
    'SCOREBUG_TEST_DEADLINE_RESETS',
    'SCOREBUG_TEST_PUBLISH_PACING',
  ])
    assert.equal(environment[key], undefined, `File baseline conflicts with ${key}`);
  assert(
    environment.SCOREBUG_TEST_DECODER_THREADING === undefined ||
      (environment.SCOREBUG_TEST_UPLINK_PROFILE === 'loss0p2-delay30' &&
        environment.SCOREBUG_TEST_DECODER_THREADING === 'slice'),
    'Explicit slice decoding requires the impaired measured file route',
  );
  assert.equal(
    environment.SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS,
    environment.SCOREBUG_TEST_UPLINK_PROFILE === 'loss0p2-delay30' ? '400' : undefined,
    'Delayed measured link requires explicit400ms SRT peer recovery budget',
  );
  const measured = environment.SCOREBUG_TEST_MEASURED_TRIAL !== undefined;
  if (measured) {
    for (const [key, value] of Object.entries({
      SCOREBUG_TEST_MEASURED_TRIAL: '1',
      SCOREBUG_TEST_CANDIDATE_HEADROOM: '1',
      SCOREBUG_TEST_CANDIDATE_PROFILE: '360p30',
      SCOREBUG_TEST_LIVE_PROFILE: '240p30',
      SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1500',
      SCOREBUG_TEST_STREAM_HOLD_SECONDS: String(holdSeconds),
    }))
      assert.equal(environment[key], value, `Measured file route requires ${key}=${value}`);
    const probe = environment.SCOREBUG_TEST_BANDWIDTH_PROBE;
    const recovery = environment.SCOREBUG_TEST_MEASURED_RECOVERY;
    if (environment.SCOREBUG_TEST_UPLINK_PROFILE !== undefined)
      assert(
        measuredUplinkProfiles.includes(environment.SCOREBUG_TEST_UPLINK_PROFILE) &&
          probe === 'staged' &&
          recovery === undefined &&
          holdSeconds >= 90,
        'Measured file uplink requires staged probe without another fault mode',
      );
    assert(
      (probe === 'staged' && (recovery === undefined || recovery === 'decoder-stall')) ||
        (probe === 'repeated' && recovery === 'repeated' && holdSeconds === 180),
      'Measured file route requires a complete staged or repeated recovery selection',
    );
  } else {
    assert.equal(
      environment.SCOREBUG_TEST_UPLINK_PROFILE,
      undefined,
      'File uplink requires complete measured route',
    );
    for (const key of [
      'SCOREBUG_TEST_CANDIDATE_PROFILE',
      'SCOREBUG_TEST_CANDIDATE_HEADROOM',
      'SCOREBUG_TEST_MEASURED_RECOVERY',
      'SCOREBUG_TEST_BANDWIDTH_PROBE',
      'SCOREBUG_TEST_DELIVERY_DEADLINE_MS',
    ])
      assert.equal(environment[key], undefined, `Fixed file route conflicts with ${key}`);
  }
  if (environment.SCOREBUG_TEST_LIVE_PROFILE !== undefined)
    assert(
      ['240p30', '360p30', '540p30'].includes(environment.SCOREBUG_TEST_LIVE_PROFILE) &&
        holdSeconds >= 90,
      'Reduced file profile requires an explicit supported profile and at least ninety seconds',
    );
  return { path, minimumDurationSeconds: holdSeconds + 90, sourceOriginSeconds: 123.25 };
}

/** Nonrecursive source guard for measured option parsers; never fabricates a motion opt-in. */
export function nativeMeasuredFileSource(environment) {
  if (environment.SCOREBUG_TEST_FILE_INPUT === undefined) return false;
  assert.equal(
    environment.SCOREBUG_TEST_MEASURED_TRIAL,
    '1',
    'Complete measured file route required',
  );
  const raw = environment.SCOREBUG_TEST_STREAM_HOLD_SECONDS;
  assert(
    typeof raw === 'string' && /^[1-9][0-9]{1,2}$/.test(raw),
    'Canonical measured file hold required',
  );
  return (
    nativeFileFixtureOptions({ environment, streaming: true, holdSeconds: Number(raw) }) !== null
  );
}

/** Prepared input contract; every frame must preserve the existing rational observation clock. */
export function qualifyNativeFileFixture({ probe, bytes, minimumDurationSeconds }) {
  assert(
    Number.isFinite(minimumDurationSeconds) &&
      minimumDurationSeconds > 0 &&
      minimumDurationSeconds <= 690,
  );
  assert.equal(probe.streams.length, 2, 'Exactly one video and audio stream required');
  const videos = probe.streams.filter((s) => s.codec_type === 'video'),
    audio = probe.streams.filter((s) => s.codec_type === 'audio');
  assert.equal(videos.length, 1);
  assert.equal(audio.length, 1);
  const video = videos[0];
  for (const [key, value] of Object.entries({
    codec_name: 'h264',
    width: 1920,
    height: 1080,
    pix_fmt: 'yuv420p',
    color_transfer: 'bt709',
    color_space: 'bt709',
    color_primaries: 'bt709',
    avg_frame_rate: '30/1',
  }))
    assert.equal(video[key], value, `Prepared video ${key}`);
  assert(
    (video.side_data_list ?? []).every(
      (s) => s.rotation === undefined && s.side_data_type !== 'Display Matrix',
    ),
    'Prepared input must have no display transform',
  );
  assert.equal(audio[0].codec_name, 'pcm_s16le', 'Prepared audio must be PCM16');
  assert.equal(audio[0].sample_rate, '48000');
  assert.equal(audio[0].channels, 1);
  assert.match(video.time_base, /^1\/[1-9][0-9]{0,9}$/);
  const timescale = Number(video.time_base.split('/')[1]);
  assert(timescale <= 2147483647);
  const frames = probe.frames.filter((f) => f.media_type === 'video');
  assert(frames.length >= 2 && frames.length < 65536, 'Bounded prepared frame count required');
  assert(frames.length / 30 >= minimumDurationSeconds, 'Insufficient prepared footage');
  for (const [index, frame] of frames.entries()) {
    assert(Number.isSafeInteger(frame.best_effort_timestamp), 'Exact integer video PTS required');
    assert.equal(
      fixtureFrameID({
        value: String(frame.best_effort_timestamp),
        timescale,
        epoch: '0',
        flags: 1,
      }),
      index,
    );
    assert(
      Math.abs(Number(frame.best_effort_timestamp_time) - (123.25 + index / 30)) <= 0.000002,
      'PTS seconds disagree with rational identity',
    );
  }
  // Prepared PCM must meet the source reader's 2-microsecond contract;
  // the generic output verifier also supports coarser RTMP millisecond timestamps.
  const audioFrames = probe.frames.filter((frame) => frame.media_type === 'audio');
  assert(audioFrames.length > 0, 'Prepared audio frames required');
  const audioOrigin = Number(audioFrames[0].best_effort_timestamp_time);
  let samples = 0;
  for (const frame of audioFrames) {
    assert(
      Number.isSafeInteger(frame.nb_samples) && frame.nb_samples > 0,
      'Valid PCM frame required',
    );
    assert(
      Math.abs(Number(frame.best_effort_timestamp_time) - (audioOrigin + samples / 48000)) <=
        0.000002,
      'Prepared PCM timeline drift',
    );
    samples += frame.nb_samples;
    assert(Number.isSafeInteger(samples));
  }
  const normalized = probe.frames.map((frame) => ({
    ...frame,
    best_effort_timestamp_time: String(Number(frame.best_effort_timestamp_time) - 123.25),
  }));
  const integrity = verifyContinuousFixtureMedia({
    frames: normalized,
    bytes,
    expectedFrames: frames.length,
    sampleRate: 48000,
  });
  return {
    sourceOriginSeconds: 123.25,
    videoFrames: frames.length,
    durationSeconds: frames.length / 30,
    audioStartSeconds: integrity.coverage.audioStartTime,
    integrity,
  };
}

export async function nativeFileFixtureHash(path) {
  assert(typeof path === 'string' && isAbsolute(path), 'Absolute fixture path required');
  const file = await lstat(path);
  assert(
    file.isFile() && !file.isSymbolicLink() && file.size > 0 && file.size <= 4 * 1024 ** 3,
    'Bounded regular fixture file required',
  );
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}
export async function verifyNativeFileFixtureHash(path, sha256) {
  assert(
    typeof sha256 === 'string' && /^[a-f0-9]{64}$/.test(sha256),
    'Expected fixture hash required',
  );
  const actual = await nativeFileFixtureHash(path);
  assert.equal(actual, sha256, 'Fixture bytes changed');
  return actual;
}
export async function stageNativeFileFixture({ source, destination, sha256 }) {
  assert(
    typeof destination === 'string' && isAbsolute(destination),
    'Absolute staging destination required',
  );
  await verifyNativeFileFixtureHash(source, sha256);
  await mkdir(dirname(destination), { recursive: true });
  await copyFile(source, destination, constants.COPYFILE_EXCL);
  await verifyNativeFileFixtureHash(destination, sha256);
  return { sha256 };
}
