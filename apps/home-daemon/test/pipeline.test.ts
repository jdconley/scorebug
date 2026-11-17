import { describe, expect, it } from 'vitest';
import { buildFfmpegArgs } from '../src/pipeline.js';

const baseSpec = {
  gameId: 'g1',
  pullUrl: 'rtmps://live.cloudflare.com:443/live/PLAYKEY',
  publishUrl: 'rtmps://a.rtmps.youtube.com/live2/STREAMKEY',
  scoreFile: '/tmp/scorebug/score.txt',
};

describe('buildFfmpegArgs', () => {
  it('encodes with software x264', () => {
    const args = buildFfmpegArgs(baseSpec);
    expect(args.slice(args.indexOf('-c:v'), args.indexOf('-c:v') + 6)).toEqual([
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-tune',
      'zerolatency',
    ]);
  });

  it('outputs flv to the publishUrl', () => {
    const args = buildFfmpegArgs(baseSpec);
    const lastTwo = args.slice(-2);
    expect(lastTwo[0]).toBe('flv');
    expect(lastTwo[1]).toBe(baseSpec.publishUrl);
    expect(args).toContain(baseSpec.pullUrl);
  });

  it('composites the worker scorebug feed (stdin, Matroska) over the live video', () => {
    const args = buildFfmpegArgs(baseSpec);
    const inputs = args.flatMap((arg, index) => (arg === '-i' ? [args[index + 1]] : []));
    expect(inputs).toEqual([baseSpec.pullUrl, 'pipe:0']);
    expect(args[args.lastIndexOf('-i') - 1]).toBe('matroska');
    const filter = args[args.indexOf('-filter_complex') + 1] ?? '';
    expect(filter.startsWith('[0:v:0]metadata=mode=delete')).toBe(true);
    expect(filter).toContain(
      '[1:v:0]split=3[scorebug_bar_packed][scorebug_setCard_packed][scorebug_lowerThird_packed];',
    );
    // 1080p default canvas: each style's box is cropped from the packed feed...
    expect(filter).toContain(
      '[scorebug_bar_packed]crop=520:244:0:0,format=yuva420p[scorebug_bar];',
    );
    expect(filter).toContain('[scorebug_setCard_packed]crop=648:252:520:0,');
    expect(filter).toContain('[scorebug_lowerThird_packed]crop=1448:172:0:252,');
    // ...and blended at its own place in the frame, in sequence.
    expect(filter).toContain(
      '[base][scorebug_bar]overlay=x=32:y=24:eof_action=pass:format=auto[scorebug_bar_done];',
    );
    expect(filter).toContain('[scorebug_bar_done][scorebug_setCard]overlay=x=1240:y=24:');
    expect(filter).toContain(
      '[scorebug_setCard_done][scorebug_lowerThird]overlay=x=236:y=854:eof_action=pass:format=auto[video]',
    );
    expect(filter).not.toContain('drawtext');
    expect(args.slice(args.indexOf('-map'), args.indexOf('-map') + 4)).toEqual([
      '-map',
      '[video]',
      '-map',
      '0:a:0',
    ]);
  });
});

it('requests machine-readable output progress with terminal stats disabled', () => {
  const args = buildFfmpegArgs(baseSpec);
  expect(args[args.indexOf('-progress') + 1]).toBe('pipe:1');
  expect(args).toContain('-nostats');
});
it('applies the output canvas and bitrate of the video profile', () => {
  const args = buildFfmpegArgs({
    ...baseSpec,
    profile: { width: 1280, height: 720, fps: 30, bitrateKbps: 3000 },
  });
  expect(args[args.indexOf('-b:v') + 1]).toBe('3000k');
  expect(args[args.indexOf('-fps_mode') + 1]).toBe('passthrough');
  expect(args[args.indexOf('-enc_time_base:v') + 1]).toBe('demux');
  expect(args).not.toContain('-fpsmax');
  expect(args[args.indexOf('-filter_complex') + 1]).toContain('select=');
  expect(args).not.toContain('-r');
  expect(args[args.indexOf('-filter_complex') + 1]).toContain('scale=1280:720');
  expect(args[args.indexOf('-filter_complex') + 1]).toContain('crop=348:164:0:0,');
});
describe('source timestamps', () => {
  it.each([false, true])('preserves the common A/V timeline with profile=%s', (withProfile) => {
    const args = buildFfmpegArgs({
      ...baseSpec,
      ...(withProfile ? { profile: { width: 1280, height: 720, fps: 30, bitrateKbps: 3000 } } : {}),
    });
    const inputIndex = args.indexOf('-i');
    const shiftIndex = args.indexOf('-avoid_negative_ts');
    const filter = args[args.indexOf('-filter_complex') + 1]!;

    expect(args.filter((arg) => arg === '-copyts')).toHaveLength(1);
    expect(args.indexOf('-copyts')).toBeLessThan(inputIndex);
    expect(args[args.indexOf('-fps_mode') + 1]).toBe('passthrough');
    expect(args[args.indexOf('-enc_time_base:v') + 1]).toBe('demux');
    expect(args.filter((arg) => arg === '-avoid_negative_ts')).toHaveLength(1);
    expect(shiftIndex).toBeGreaterThan(inputIndex + 1);
    expect(args[shiftIndex + 1]).toBe('make_zero');
    expect(shiftIndex).toBeLessThan(args.lastIndexOf('-f'));
    expect(args.slice(-3)).toEqual(['-f', 'flv', baseSpec.publishUrl]);
    expect(args).not.toContain('-start_at_zero');
    expect(args).not.toContain('-r');
    expect(args).not.toContain('-fpsmax');
    expect(filter).not.toContain('setpts');

    if (withProfile) {
      expect(args[args.indexOf('-reinit_filter:v:0') + 1]).toBe('0');
      expect(filter).toContain(':(ow-iw)/2:(oh-ih)/2:eval=frame[base];');
      expect(args.indexOf('-reinit_filter:v:0')).toBeLessThan(inputIndex);
      expect(filter).toContain(
        "nullsink;[live]settb=1/90000,select='st(0,if(isnan(prev_t),2,min(2,ld(0)+max(0,t-ld(1))*30)))",
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
        profile: { width, height: 720, fps: 30, bitrateKbps: 3000 },
      }),
    ).toThrow('invalid_video_profile');
});

it('observes fixed-timebase decoder ingress before cap and strips an exact fixed marker', () => {
  const args = buildFfmpegArgs({
    ...baseSpec,
    profile: { width: 640, height: 360, fps: 30, bitrateKbps: 1000 },
  });
  const vf = args[args.indexOf('-filter_complex') + 1]!;
  expect(vf).toContain(
    'metadata=mode=delete:key=scorebug.source,split[decoded][live];[decoded]settb=1/90000,',
  );
  expect(vf).toContain(
    "metadata=mode=add:key=scorebug.source:value=1,metadata=mode=print:key=scorebug.source:file='pipe\\:3':direct=1,metadata=mode=delete:key=scorebug.source,nullsink;[live]settb=1/90000,select=",
  );
});

it('rejects pipelines with no output', () => {
  expect(() => buildFfmpegArgs({ ...baseSpec, publishUrl: '' })).toThrow('missing_pipeline_output');
});

it('bounds input probing and read waits for the Stream source, before the input', () => {
  const spec = baseSpec;
  const normal = buildFfmpegArgs(spec);
  expect(buildFfmpegArgs({ ...spec, inputProbe: 'default' })).toEqual(normal);
  expect(normal).not.toContain('-rw_timeout');
  const hosted = buildFfmpegArgs({ ...spec, inputProbe: 'fast', inputReadTimeoutMs: 4000 });
  const input = hosted.indexOf('-i');
  const probe = hosted.indexOf('-probesize');
  expect(hosted.slice(probe, probe + 4)).toEqual([
    '-probesize',
    '2000000',
    '-analyzeduration',
    '2500000',
  ]);
  expect(probe).toBeLessThan(input);
  const timeout = hosted.indexOf('-rw_timeout');
  expect(hosted[timeout + 1]).toBe('4000000');
  expect(timeout).toBeLessThan(input);
  hosted.splice(timeout, 2);
  hosted.splice(probe, 4);
  expect(hosted).toEqual(normal);
  expect(() => buildFfmpegArgs({ ...spec, inputProbe: 'slow' as 'fast' })).toThrow();
  expect(() => buildFfmpegArgs({ ...spec, inputReadTimeoutMs: 10 })).toThrow();
});
