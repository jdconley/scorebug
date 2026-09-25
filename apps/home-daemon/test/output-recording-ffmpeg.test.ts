import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { expect, it } from 'vitest';
import { startPipeline } from '../src/pipeline.js';

// Explicit media qualification; no system FFmpeg dependency in the unit suite.
const ffmpeg = process.env.SCOREBUG_RECORDING_FFMPEG;
const ffprobe = process.env.SCOREBUG_RECORDING_FFPROBE;
const fontPath = process.env.SCOREBUG_RECORDING_FONT;
const execute = promisify(execFile);
const qualified = it.skipIf(!ffmpeg || !ffprobe || !fontPath);

qualified(
  'real final-overlay MP4 and tee retain A/V offsets, escape names, and fail on either output error',
  async () => {
    const directory = await mkdtemp(join(tmpdir(), 'scorebug-recording-proof-'));
    const run = (binary: string, args: string[]) =>
      execute(binary, args, { timeout: 15000, maxBuffer: 2 * 1024 * 1024 });
    const records: unknown[] = [];
    const record = (...args: unknown[]) => records.push(args);
    const log = { info: record, error: record, warn: record, debug: record };
    try {
      const source = join(directory, 'source.mkv');
      const scoreFile = join(directory, 'score.txt');
      await writeFile(scoreFile, 'HOME 12 - 7 AWAY');
      await run(ffmpeg!, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=c=black:size=320x180:rate=30:duration=3',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=1000:sample_rate=48000:duration=3.6',
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-vf',
        'setpts=PTS+0.6/TB',
        '-fps_mode',
        'passthrough',
        '-c:v',
        'ffv1',
        '-c:a',
        'pcm_s16le',
        source,
      ]);
      const spec = {
        gameId: 'recording-proof',
        pullUrl: source,
        scoreFile,
        fontPath: fontPath!,
        nvenc: false,
        ffmpegPath: ffmpeg!,
        profile: { width: 320, height: 180, fps: 30, bitrateKbps: 350 },
      };
      const inspect = async (path: string) =>
        JSON.parse(
          (
            await run(ffprobe!, [
              '-v',
              'error',
              '-show_streams',
              '-show_packets',
              '-of',
              'json',
              path,
            ])
          ).stdout,
        );
      for (const dual of [false, true]) {
        const recordingPath = join(directory, `final video's | archive\\${dual}.mp4`);
        const publishUrl = join(directory, `sink video's | archive\\${dual}.flv`);
        const pipeline = startPipeline(
          { ...spec, recordingPath, ...(dual ? { publishUrl } : {}) },
          log,
        );
        expect(await pipeline.waitExit()).toEqual({ code: 0, signal: null });
        const bytes = await readFile(recordingPath);
        expect(bytes.includes(Buffer.from('moof'))).toBe(true);
        // Model an interruption before the last fragment/trailer was written.
        const partialPath = join(directory, `partial-${dual}.mp4`);
        const lastFragment = bytes.lastIndexOf(Buffer.from('moof')) - 4;
        expect(lastFragment).toBeGreaterThan(bytes.indexOf(Buffer.from('moof')));
        await writeFile(partialPath, bytes.subarray(0, lastFragment));
        const partial = await inspect(partialPath);
        expect(
          partial.packets.filter((packet: any) => packet.codec_type === 'video').length,
        ).toBeGreaterThan(0);
        await run(ffmpeg!, ['-v', 'error', '-i', partialPath, '-f', 'null', '-']);
        const probe = await inspect(recordingPath);
        expect(probe.streams.map((stream: any) => stream.codec_name)).toEqual(['h264', 'aac']);
        const video = probe.packets.filter((packet: any) => packet.codec_type === 'video');
        const audio = probe.packets.filter((packet: any) => packet.codec_type === 'audio');
        expect(video).toHaveLength(90);
        expect(Number(video[0].pts_time) - Number(audio[0].pts_time)).toBeCloseTo(0.6, 1);
        if (dual) {
          const sink = await inspect(publishUrl);
          const sinkVideo = sink.packets.filter((packet: any) => packet.codec_type === 'video');
          expect(sinkVideo).toHaveLength(video.length);
          expect(
            Number(sinkVideo[0].pts_time) -
              Number(sink.packets.find((packet: any) => packet.codec_type === 'audio').pts_time),
          ).toBeCloseTo(0.6, 1);
        }
        await run(ffmpeg!, ['-v', 'error', '-i', recordingPath, '-f', 'null', '-']);
        const pixels = await execute(
          ffmpeg!,
          [
            '-v',
            'error',
            '-i',
            recordingPath,
            '-vf',
            'crop=320:32:0:148',
            '-frames:v',
            '1',
            '-pix_fmt',
            'gray',
            '-f',
            'rawvideo',
            '-',
          ],
          { encoding: 'buffer', timeout: 15000 },
        );
        // The input is black: bright pixels here prove the final score overlay is encoded.
        expect([...pixels.stdout].filter((value) => value > 200).length).toBeGreaterThan(100);
      }
      for (const failedOutput of ['recording', 'publish']) {
        const validPath = join(directory, `${failedOutput}.mp4`);
        const invalidPath = join(directory, 'missing-directory', 'STREAM_SECRET');
        const pipeline = startPipeline(
          {
            ...spec,
            recordingPath: failedOutput === 'recording' ? invalidPath : validPath,
            publishUrl: failedOutput === 'publish' ? invalidPath : join(directory, 'other.flv'),
          },
          log,
        );
        expect((await pipeline.waitExit()).code).not.toBe(0);
      }
      expect(JSON.stringify(records)).not.toContain('STREAM_SECRET');
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
  30000,
);
