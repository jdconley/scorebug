import { execFile } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { expect, it } from 'vitest';
import { startPipeline } from '../src/pipeline.js';
import { scorebugOverlay, serializeScorebugOverlay } from '../src/scorebug/state.js';

const ffmpeg = process.env.SCOREBUG_FFMPEG_PATH ?? 'ffmpeg';
const ffprobe = process.env.SCOREBUG_FFPROBE_PATH ?? 'ffprobe';
const execute = promisify(execFile);

it(
  'publishes FLV that keeps the source A/V offset and the scorebug, and fails on output errors',
  { timeout: 30_000 },
  async () => {
    const directory = await mkdtemp(join(tmpdir(), 'scorebug-published-output-'));
    const run = (binary: string, args: string[]) =>
      execute(binary, args, { timeout: 15000, maxBuffer: 2 * 1024 * 1024 });
    const records: unknown[] = [];
    const record = (...args: unknown[]) => records.push(args);
    const log = { info: record, error: record, warn: record, debug: record };
    try {
      const source = join(directory, 'source.mkv');
      const scoreFile = join(directory, 'scorebug.json');
      await writeFile(
        scoreFile,
        serializeScorebugOverlay(
          scorebugOverlay({
            teams: {
              home: { name: 'Home', shortName: 'HOME', color: '#1D4ED8' },
              away: { name: 'Away', shortName: 'AWAY', color: '#F97316' },
            },
            score: { home: 12, away: 7, set: 1, homeSets: 0, awaySets: 0 },
          }),
        ),
      );
      // Black video that starts 0.6 s after its audio, like a phone's first GOP.
      await run(ffmpeg, [
        ...['-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:size=320x180:rate=30:duration=3'],
        ...['-f', 'lavfi', '-i', 'sine=frequency=1000:sample_rate=48000:duration=3.6'],
        ...['-map', '0:v:0', '-map', '1:a:0', '-vf', 'setpts=PTS+0.6/TB'],
        ...['-fps_mode', 'passthrough', '-c:v', 'ffv1', '-c:a', 'pcm_s16le', source],
      ]);
      const spec = {
        gameId: 'published-output',
        pullUrl: source,
        scoreFile,
        ffmpegPath: ffmpeg,
        profile: { width: 320, height: 180, fps: 30, bitrateKbps: 350 },
      };
      // The FLV FFmpeg would publish over RTMP, written to a file to inspect.
      const publishUrl = join(directory, 'published.flv');
      const pipeline = startPipeline({ ...spec, publishUrl }, log);
      expect(await pipeline.waitExit()).toEqual({ code: 0, signal: null });
      const probe = JSON.parse(
        (
          await run(ffprobe, [
            ...['-v', 'error', '-show_streams', '-show_packets', '-of', 'json', publishUrl],
          ])
        ).stdout,
      );
      expect(probe.streams.map((stream: any) => stream.codec_name)).toEqual(['h264', 'aac']);
      const video = probe.packets.filter((packet: any) => packet.codec_type === 'video');
      const audio = probe.packets.filter((packet: any) => packet.codec_type === 'audio');
      expect(video).toHaveLength(90);
      expect(Number(video[0].pts_time) - Number(audio[0].pts_time)).toBeCloseTo(0.6, 1);
      await run(ffmpeg, ['-v', 'error', '-xerror', '-i', publishUrl, '-f', 'null', '-']);
      const pixels = await execute(
        ffmpeg,
        [
          ...['-v', 'error', '-i', publishUrl, '-vf', 'crop=320:32:0:8'],
          ...['-frames:v', '1', '-pix_fmt', 'gray', '-f', 'rawvideo', '-'],
        ],
        { encoding: 'buffer', timeout: 15000 },
      );
      // The input is black: bright pixels here prove the score overlay is encoded.
      expect([...pixels.stdout].filter((value) => value > 200).length).toBeGreaterThan(100);

      const failed = startPipeline(
        { ...spec, publishUrl: join(directory, 'missing-directory', 'STREAM_SECRET') },
        log,
      );
      expect((await failed.waitExit()).code).not.toBe(0);
      expect(JSON.stringify(records)).not.toContain('STREAM_SECRET');
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);
