import { describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';

const base = {
  CONTROL_PLANE_URL: 'http://localhost:18787',
  HOME_TOKEN: 'test-only-home-token',
  WORKER_ID: 'mac',
  OUTPUT_ID: 'local-sink',
  OUTPUT_URL: 'rtmp://localhost:11935/live/fixture',
};

describe('media tool configuration', () => {
  it('preserves explicit binary and font paths', () => {
    const config = loadConfig({
      ...base,
      FFMPEG_PATH: '/opt/media/ffmpeg',
      FFPROBE_PATH: '/opt/media/ffprobe',
      FONT_PATH: '/opt/media/score font.ttf',
    });
    expect(config).toMatchObject({
      FFMPEG_PATH: '/opt/media/ffmpeg',
      FFPROBE_PATH: '/opt/media/ffprobe',
      FONT_PATH: '/opt/media/score font.ttf',
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

it('defaults optional processing diagnostics to auto and permits explicitly disabling them', () => {
  expect(loadConfig(base).WORKER_PROCESSING).toBe('auto');
  expect(loadConfig({ ...base, WORKER_PROCESSING: 'off' }).WORKER_PROCESSING).toBe('off');
  expect(() => loadConfig({ ...base, WORKER_PROCESSING: 'true' })).toThrow();
});

it('bounds explicit report cadence and preserves the default', () => {
  expect(loadConfig(base).WORKER_REPORT_INTERVAL_MS).toBe(1000);
  expect(loadConfig({ ...base, WORKER_REPORT_INTERVAL_MS: '100' }).WORKER_REPORT_INTERVAL_MS).toBe(
    100,
  );
  for (const value of ['0', '99', '5001', '250.5', '', 'NaN'])
    expect(() => loadConfig({ ...base, WORKER_REPORT_INTERVAL_MS: value })).toThrow();
});
