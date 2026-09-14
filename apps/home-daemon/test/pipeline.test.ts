import { describe, expect, it } from 'vitest';
import { buildFfmpegArgs } from '../src/pipeline.js';

const baseSpec = {
  gameId: 'g1',
  pullUrl: 'srt://ingest.example:8890?streamid=read:game_g1&passphrase=xx&latency=1000000',
  publishUrl: 'rtmps://a.rtmps.youtube.com/live2/STREAMKEY',
  scoreFile: '/tmp/scorebug/score.txt',
};

describe('buildFfmpegArgs', () => {
  it('uses h264_nvenc when nvenc enabled', () => {
    const args = buildFfmpegArgs({ ...baseSpec, nvenc: true });
    expect(args).toContain('h264_nvenc');
    expect(args).not.toContain('libx264');
  });

  it('falls back to libx264 when nvenc disabled', () => {
    const args = buildFfmpegArgs({ ...baseSpec, nvenc: false });
    expect(args).toContain('libx264');
    expect(args).not.toContain('h264_nvenc');
  });

  it('outputs flv to the publishUrl', () => {
    const args = buildFfmpegArgs({ ...baseSpec, nvenc: true });
    const lastTwo = args.slice(-2);
    expect(lastTwo[0]).toBe('flv');
    expect(lastTwo[1]).toBe(baseSpec.publishUrl);
    expect(args).toContain(baseSpec.pullUrl);
  });

  it('wires drawtext with reload=1 against the scoreFile', () => {
    const args = buildFfmpegArgs({ ...baseSpec, nvenc: true });
    const vfIndex = args.indexOf('-vf');
    expect(vfIndex).toBeGreaterThan(-1);
    const filter = args[vfIndex + 1] ?? '';
    expect(filter).toContain(`drawtext=textfile=${baseSpec.scoreFile}`);
    expect(filter).toContain('reload=1');
  });
});

it('requests machine-readable output progress with terminal stats disabled', () => {
  const args = buildFfmpegArgs({ ...baseSpec, nvenc: false });
  expect(args[args.indexOf('-progress') + 1]).toBe('pipe:1');
  expect(args).toContain('-nostats');
});
