import { describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';

const base = {
  CONTROL_PLANE_WS: 'ws://localhost:18787/home/ws',
  HOME_TOKEN: 'test-only-home-token',
  RTMP_TARGET: 'rtmp://localhost:11935/live',
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
});
