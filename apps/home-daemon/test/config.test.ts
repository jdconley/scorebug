import { describe, expect, it } from 'vitest';
import { loadConfig, videoProfiles } from '../src/config.js';

const base = {
  CONTROL_PLANE_URL: 'http://localhost:18787',
  HOME_TOKEN: 'test-only-home-token',
  WORKER_ID: 'mac',
  OUTPUT_ID: 'local-sink',
};

describe('media tool configuration', () => {
  it('preserves explicit binary paths', () => {
    const config = loadConfig({
      ...base,
      FFMPEG_PATH: '/opt/media/ffmpeg',
    });
    expect(config).toMatchObject({ FFMPEG_PATH: '/opt/media/ffmpeg' });
  });
  it('rejects empty explicit binary paths', () => {
    expect(() => loadConfig({ ...base, FFMPEG_PATH: '' })).toThrow();
  });
  it('requires the worker identity and output', () => {
    expect(loadConfig(base)).toMatchObject({
      VIDEO_PROFILE: '1080p30',
      WORKER_ID: 'mac',
      OUTPUT_ID: 'local-sink',
    });
    expect(() => loadConfig({ ...base, WORKER_ID: '' })).toThrow();
    expect(() => loadConfig({ ...base, OUTPUT_ID: '../other' })).toThrow();
    expect(() => loadConfig({ ...base, HOME_TOKEN: 'short' })).toThrow();
  });
});

it('supports an explicit reduced live output independently of the default profile', () => {
  expect(loadConfig({ ...base, VIDEO_PROFILE: '540p30' }).VIDEO_PROFILE).toBe('540p30');
  expect(videoProfiles['540p30']).toEqual({ width: 960, height: 540, fps: 30, bitrateKbps: 1500 });
  expect(loadConfig(base).VIDEO_PROFILE).toBe('1080p30');
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

describe('hosted tuning', () => {
  it('defaults when unset', () => {
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
