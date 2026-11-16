import { describe, expect, it } from 'vitest';
import { loadConfig, videoProfiles } from '../src/config.js';

const base = {
  CONTROL_PLANE_URL: 'http://localhost:18787',
  HOME_TOKEN: 'test-only-home-token',
  WORKER_ID: 'mac',
  OUTPUT_ID: 'local-sink',
  OUTPUT_URL: 'rtmp://localhost:11935/live/fixture',
};

describe('media tool configuration', () => {
  it('preserves explicit binary paths', () => {
    const config = loadConfig({
      ...base,
      FFMPEG_PATH: '/opt/media/ffmpeg',
      FFPROBE_PATH: '/opt/media/ffprobe',
    });
    expect(config).toMatchObject({
      FFMPEG_PATH: '/opt/media/ffmpeg',
      FFPROBE_PATH: '/opt/media/ffprobe',
    });
  });
  it('rejects empty explicit binary paths', () => {
    expect(() => loadConfig({ ...base, FFMPEG_PATH: '' })).toThrow();
  });
  it('defaults to portable software and requires explicit native worker identity/output', () => {
    expect(loadConfig(base)).toMatchObject({
      ENCODER: 'software',
      VIDEO_PROFILE: '1080p30',
      WORKER_ID: 'mac',
      OUTPUT_ID: 'local-sink',
    });
    expect(() => loadConfig({ ...base, OUTPUT_URL: 'file:///private/file' })).toThrow();
    expect(() => loadConfig({ ...base, WORKER_ID: '' })).toThrow();
  });
  it('accepts VideoToolbox and preserves the legacy NVENC selection when explicit', () => {
    expect(loadConfig({ ...base, ENCODER: 'videotoolbox' }).ENCODER).toBe('videotoolbox');
    expect(loadConfig({ ...base, NVENC_ENABLED: 'true' }).ENCODER).toBe('nvenc');
  });
});

it('reports every second by default, well inside the five-second status lifetime', () => {
  expect(loadConfig(base).WORKER_REPORT_INTERVAL_MS).toBe(1000);
});

it('preserves explicitly configured report cadence within the supported range', () => {
  expect(loadConfig({ ...base, WORKER_REPORT_INTERVAL_MS: '1000' }).WORKER_REPORT_INTERVAL_MS).toBe(
    1000,
  );
  expect(loadConfig({ ...base, WORKER_REPORT_INTERVAL_MS: '4000' }).WORKER_REPORT_INTERVAL_MS).toBe(
    4000,
  );
  expect(loadConfig({ ...base, WORKER_REPORT_INTERVAL_MS: '100' }).WORKER_REPORT_INTERVAL_MS).toBe(
    100,
  );
  for (const value of ['0', '99', '4001', '250.5', '', 'NaN'])
    expect(() => loadConfig({ ...base, WORKER_REPORT_INTERVAL_MS: value })).toThrow();
});

it('supports an explicit reduced live output independently of the default profile', () => {
  expect(loadConfig({ ...base, VIDEO_PROFILE: '540p30' }).VIDEO_PROFILE).toBe('540p30');
  expect(videoProfiles['540p30']).toEqual({ width: 960, height: 540, fps: 30, bitrateKbps: 1500 });
  expect(loadConfig(base).VIDEO_PROFILE).toBe('1080p30');
});

it('requires an explicit supported input decoder threading mode', () => {
  expect(loadConfig(base).DECODER_THREADING).toBe('automatic');
  expect(loadConfig({ ...base, DECODER_THREADING: 'slice' }).DECODER_THREADING).toBe('slice');
  for (const mode of ['', '1', 'frame', 'Slice'])
    expect(() => loadConfig({ ...base, DECODER_THREADING: mode })).toThrow();
});

it('supports the measured360 publishing candidate without changing the default', () => {
  expect(loadConfig({ ...base, VIDEO_PROFILE: '360p30' }).VIDEO_PROFILE).toBe('360p30');
  expect(videoProfiles['360p30']).toEqual({ width: 640, height: 360, fps: 30, bitrateKbps: 600 });
  expect(loadConfig(base).VIDEO_PROFILE).toBe('1080p30');
});

it('supports the experimental240 publishing candidate without changing the default', () => {
  expect(loadConfig({ ...base, VIDEO_PROFILE: '240p30' }).VIDEO_PROFILE).toBe('240p30');
  expect(videoProfiles['240p30']).toEqual({ width: 426, height: 240, fps: 30, bitrateKbps: 350 });
  expect(loadConfig(base).VIDEO_PROFILE).toBe('1080p30');
});

it('defaults to RTMP and validates output requirements for each mode', () => {
  expect(loadConfig(base).OUTPUT_MODE).toBe('rtmp');
  // OUTPUT_URL is only the fallback: destinations normally come from the control plane.
  expect(loadConfig({ ...base, OUTPUT_URL: undefined }).OUTPUT_URL).toBeUndefined();
  expect(loadConfig({ ...base, OUTPUT_URL: '' }).OUTPUT_URL).toBeUndefined();
  expect(
    loadConfig({
      ...base,
      OUTPUT_MODE: 'record',
      OUTPUT_URL: undefined,
      OUTPUT_RECORDING_DIR: '/tmp/recordings',
    }),
  ).toMatchObject({ OUTPUT_MODE: 'record', OUTPUT_RECORDING_DIR: '/tmp/recordings' });
  expect(
    loadConfig({
      ...base,
      OUTPUT_MODE: 'rtmp+record',
      OUTPUT_RECORDING_DIR: '/tmp/recordings',
    }).OUTPUT_MODE,
  ).toBe('rtmp+record');
  for (const OUTPUT_MODE of ['record', 'rtmp+record']) {
    for (const OUTPUT_RECORDING_DIR of [undefined, '', '   '])
      expect(() => loadConfig({ ...base, OUTPUT_MODE, OUTPUT_RECORDING_DIR })).toThrow();
  }
  expect(
    loadConfig({
      ...base,
      OUTPUT_MODE: 'rtmp+record',
      OUTPUT_RECORDING_DIR: '/tmp',
      OUTPUT_URL: undefined,
    }).OUTPUT_MODE,
  ).toBe('rtmp+record');
  expect(() => loadConfig({ ...base, OUTPUT_MODE: 'unknown' })).toThrow();
  expect(() =>
    loadConfig({
      ...base,
      OUTPUT_MODE: 'record',
      OUTPUT_RECORDING_DIR: '/tmp',
      OUTPUT_URL: 'file:///tmp/video',
    }),
  ).toThrow();
});

describe('hosted tuning', () => {
  it('defaults to the self-hosted behavior', () => {
    const config = loadConfig(base);
    expect(config).toMatchObject({
      SCORE_DELAY_MS: 0,
      INPUT_PROBE: 'default',
      OUTPUT_TIMEOUT_MS: 10_000,
      RETRY_MAX_ATTEMPTS: 3,
    });
    expect(config.INPUT_READ_TIMEOUT_MS).toBeUndefined();
    expect(config.RETRY_FREE_AFTER_MS).toBeUndefined();
  });
  it('reads the hosted container values', () => {
    expect(
      loadConfig({
        ...base,
        SCORE_DELAY_MS: '1100',
        INPUT_PROBE: 'fast',
        INPUT_READ_TIMEOUT_MS: '4000',
        OUTPUT_TIMEOUT_MS: '15000',
        RETRY_MAX_ATTEMPTS: '6',
        RETRY_FREE_AFTER_MS: '3000',
      }),
    ).toMatchObject({
      SCORE_DELAY_MS: 1100,
      INPUT_PROBE: 'fast',
      INPUT_READ_TIMEOUT_MS: 4000,
      OUTPUT_TIMEOUT_MS: 15000,
      RETRY_MAX_ATTEMPTS: 6,
      RETRY_FREE_AFTER_MS: 3000,
    });
    expect(() => loadConfig({ ...base, SCORE_DELAY_MS: '-1' })).toThrow();
  });
});
