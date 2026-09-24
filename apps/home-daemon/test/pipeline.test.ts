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
it('selects real VideoToolbox without silent software fallback and applies the output canvas', () => {
  const args = buildFfmpegArgs({
    ...baseSpec,
    nvenc: false,
    encoder: 'videotoolbox',
    profile: { width: 1280, height: 720, fps: 30, bitrateKbps: 3000 },
  });
  expect(args).toContain('h264_videotoolbox');
  expect(args[args.indexOf('-allow_sw') + 1]).toBe('0');
  expect(args[args.indexOf('-b:v') + 1]).toBe('3000k');
  expect(args[args.indexOf('-fps_mode') + 1]).toBe('passthrough');
  expect(args[args.indexOf('-enc_time_base:v') + 1]).toBe('-1');
  expect(args).not.toContain('-fpsmax');
  expect(args[args.indexOf('-vf') + 1]).toContain('select=');
  expect(args).not.toContain('-r');
  expect(args[args.indexOf('-vf') + 1]).toContain('scale=1280:720');
  expect(args[args.indexOf('-vf') + 1]).toContain('expansion=none');
});
it('lets explicit software selection override the legacy NVENC flag', () => {
  expect(buildFfmpegArgs({ ...baseSpec, nvenc: true, encoder: 'software' })).toContain('libx264');
});

describe.each(['software', 'videotoolbox', 'nvenc'] as const)('%s source timestamps', (encoder) => {
  it.each([false, true])('preserves the common A/V timeline with profile=%s', (withProfile) => {
    const args = buildFfmpegArgs({
      ...baseSpec,
      nvenc: false,
      encoder,
      ...(withProfile ? { profile: { width: 1280, height: 720, fps: 30, bitrateKbps: 3000 } } : {}),
    });
    const inputIndex = args.indexOf('-i');
    const shiftIndex = args.indexOf('-avoid_negative_ts');
    const filter = args[args.indexOf('-vf') + 1]!;

    expect(args.filter((arg) => arg === '-copyts')).toHaveLength(1);
    expect(args.indexOf('-copyts')).toBeLessThan(inputIndex);
    expect(args[args.indexOf('-fps_mode') + 1]).toBe('passthrough');
    expect(args[args.indexOf('-enc_time_base:v') + 1]).toBe('-1');
    expect(args.filter((arg) => arg === '-avoid_negative_ts')).toHaveLength(1);
    expect(shiftIndex).toBeGreaterThan(inputIndex + 1);
    expect(args[shiftIndex + 1]).toBe('make_zero');
    expect(shiftIndex).toBeLessThan(args.indexOf('-f'));
    expect(args.slice(-3)).toEqual(['-f', 'flv', baseSpec.publishUrl]);
    expect(args).not.toContain('-start_at_zero');
    expect(args).not.toContain('-r');
    expect(args).not.toContain('-fpsmax');
    expect(filter).not.toContain('setpts');

    if (withProfile) {
      expect(args[args.indexOf('-reinit_filter:v:0') + 1]).toBe('0');
      expect(filter).toContain(':(ow-iw)/2:(oh-ih)/2:eval=frame,drawtext=');
      expect(args.indexOf('-reinit_filter:v:0')).toBeLessThan(inputIndex);
      expect(filter).toContain(
        "nullsink;[live]select='isnan(prev_selected_t)+gt(floor((t-start_t+1.5*TB)*30),floor((prev_selected_t-start_t+1.5*TB)*30))',scale=1280:720",
      );
      expect(filter.indexOf('[decoded]settb=1/90000')).toBeGreaterThan(-1);
      expect(filter.indexOf('[decoded]settb=1/90000')).toBeLessThan(filter.indexOf('select='));
    } else {
      expect(args).not.toContain('-reinit_filter:v:0');
      expect(filter).not.toContain('select=');
    }
  });
});

it('rejects invalid output profiles before spawning FFmpeg', () => {
  for (const width of [0, 1279, Infinity])
    expect(() =>
      buildFfmpegArgs({
        ...baseSpec,
        nvenc: false,
        profile: { width, height: 720, fps: 30, bitrateKbps: 3000 },
      }),
    ).toThrow('invalid_video_profile');
});

it('observes fixed-timebase decoder ingress before cap and strips an exact fixed marker', () => {
  const args = buildFfmpegArgs({
    ...baseSpec,
    nvenc: false,
    profile: { width: 640, height: 360, fps: 30, bitrateKbps: 1000 },
  });
  const vf = args[args.indexOf('-vf') + 1]!;
  expect(vf).toContain(
    'metadata=mode=delete:key=scorebug.source,split[decoded][live];[decoded]settb=1/90000,',
  );
  expect(vf).toContain(
    "metadata=mode=add:key=scorebug.source:value=1,metadata=mode=print:key=scorebug.source:file='pipe\\:3':direct=1,metadata=mode=delete:key=scorebug.source,nullsink;[live]select=",
  );
});

it('adds encoder timing statistics only when explicitly enabled', () => {
  const normal = buildFfmpegArgs({ ...baseSpec, nvenc: false });
  expect(normal).not.toContain('-stats_enc_pre:v:0');
  expect(normal).not.toContain('-stats_enc_post:v:0');
  const measured = buildFfmpegArgs({ ...baseSpec, nvenc: false }, { encoderTiming: true });
  expect(measured[measured.indexOf('-stats_enc_pre:v:0') + 1]).toBe('pipe:4');
  expect(measured[measured.indexOf('-stats_enc_post:v:0') + 1]).toBe('pipe:4');
  expect(measured[measured.indexOf('-stats_enc_pre_fmt:v:0') + 1]).toBe('pre {n} {tb} {pts}');
  expect(measured[measured.indexOf('-stats_enc_post_fmt:v:0') + 1]).toBe('post {n} {tb} {pts}');
  expect(measured.slice(-3)).toEqual(normal.slice(-3));
});

it('enables uncompressed INFO diagnostics only when explicitly requested', () => {
  const spec = { ...baseSpec, nvenc: false };
  const normal = buildFfmpegArgs(spec);
  const detailed = buildFfmpegArgs(spec, { decoderDiagnostics: true });
  expect(normal[normal.indexOf('-loglevel') + 1]).toBe('warning');
  expect(detailed[detailed.indexOf('-loglevel') + 1]).toBe('repeat+level+info');
  const stripped = [...detailed];
  stripped[stripped.indexOf('-loglevel') + 1] = 'warning';
  expect(stripped).toEqual(normal);
});

it('applies slice threading to input video only without altering output encoder options', () => {
  const spec = { ...baseSpec, nvenc: false };
  const normal = buildFfmpegArgs(spec);
  expect(buildFfmpegArgs({ ...spec, decoderThreading: 'automatic' })).toEqual(normal);
  const slice = buildFfmpegArgs({ ...spec, decoderThreading: 'slice' });
  const at = slice.indexOf('-thread_type:v:0');
  expect(at).toBeGreaterThan(-1);
  expect(at).toBeLessThan(slice.indexOf('-i'));
  expect(slice[at + 1]).toBe('slice');
  slice.splice(at, 2);
  expect(slice).toEqual(normal);
  expect(() => buildFfmpegArgs({ ...spec, decoderThreading: 'invalid' as 'slice' })).toThrow();
});

it('enables numeric packet timing only with the explicit diagnostic option', () => {
  const spec = { ...baseSpec, nvenc: false };
  for (const options of [{}, { decoderDiagnostics: true }])
    expect(buildFfmpegArgs(spec, options)).not.toContain('-debug_ts');
  const args = buildFfmpegArgs(spec, { packetTiming: true } as any);
  expect(args.filter((arg) => arg === '-debug_ts')).toHaveLength(1);
  expect(args[args.indexOf('-loglevel') + 1]).toBe('repeat+level+info');
  expect(args).toContain('-copyts');
  expect(args[args.indexOf('-avoid_negative_ts') + 1]).toBe('make_zero');
});
