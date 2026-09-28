import { expect, it } from 'vitest';
import { probeBackend } from '../src/backend-capabilities.js';
import { loadConfig } from '../src/config.js';

const config = loadConfig({
  CONTROL_PLANE_URL: 'http://127.0.0.1:1',
  HOME_TOKEN: '0123456789abcdef',
  WORKER_ID: 'worker',
  OUTPUT_ID: 'output',
  OUTPUT_MODE: 'record',
  OUTPUT_RECORDING_DIR: '/unused',
  FFMPEG_PATH: '/definitely-missing-scorebug-ffmpeg',
  VIDEO_PROFILE: '240p30',
});
it('missing encoder is unavailable rather than assumed supported from configuration', async () => {
  expect(await probeBackend(config)).toEqual({
    version: 1,
    outputId: 'output',
    outputMode: 'record',
    encoder: 'software',
    outputProfile: '240p30',
    startup: 'failed',
    sustainedPerformance: 'unqualified',
  });
});
it('cancellation cannot advertise an unperformed startup check', async () => {
  expect((await probeBackend(config, { signal: AbortSignal.abort() })).startup).toBe('cancelled');
});

it('invalid configured executable is reported without rejecting worker startup', async () => {
  expect((await probeBackend({ ...config, FFMPEG_PATH: 'bad\0binary' })).startup).toBe('failed');
});
