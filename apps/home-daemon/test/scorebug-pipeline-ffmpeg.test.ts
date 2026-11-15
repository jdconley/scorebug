import { execFile } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { expect, it } from 'vitest';
import { buildFfmpegArgs, startPipeline } from '../src/pipeline.js';
import { MatroskaFramer, matroskaHeader } from '../src/scorebug/matroska.js';
import { overlayRegions } from '../src/scorebug/layout.js';
import { scorebugOverlay, serializeScorebugOverlay } from '../src/scorebug/state.js';

const ffmpeg = process.env.SCOREBUG_FFMPEG_PATH ?? 'ffmpeg';
const ffprobe = process.env.SCOREBUG_FFPROBE_PATH ?? 'ffprobe';
const run = promisify(execFile);
const log = { debug() {}, info() {}, warn() {}, error() {} };

it(
  'burns the scorebug into every frame of a camera-clock (copyts) source without dropping frames',
  { timeout: 60_000 },
  async () => {
    const directory = await mkdtemp(join(tmpdir(), 'scorebug-overlay-pipeline-'));
    try {
      const source = join(directory, 'source.ts');
      // Black video whose transport PTS starts an hour in, like a phone's clock.
      await run(ffmpeg, [
        ...['-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:size=640x360:rate=30:duration=2'],
        ...['-f', 'lavfi', '-i', 'sine=frequency=1000:sample_rate=48000:duration=2'],
        ...['-c:v', 'libx264', '-preset', 'ultrafast', '-g', '30', '-c:a', 'aac'],
        ...['-output_ts_offset', '3600', '-f', 'mpegts', source],
      ]);
      const scoreFile = join(directory, 'scorebug.json');
      await writeFile(
        scoreFile,
        serializeScorebugOverlay(
          scorebugOverlay({
            teams: {
              home: { name: 'Home', shortName: 'HOM', color: '#1D4ED8' },
              away: { name: 'Away', shortName: 'AWY', color: '#F97316' },
            },
            score: { home: 18, away: 15, set: 3, homeSets: 1, awaySets: 1 },
          }),
        ),
      );
      const recordingPath = join(directory, 'final.mp4');
      const pipeline = startPipeline(
        {
          gameId: 'overlay',
          pullUrl: source,
          recordingPath,
          scoreFile,
          nvenc: false,
          encoder: 'software',
          ffmpegPath: ffmpeg,
          profile: { width: 640, height: 360, fps: 30, bitrateKbps: 800 },
        },
        log,
      );
      expect(await pipeline.waitExit()).toEqual({ code: 0, signal: null });
      const frames = JSON.parse(
        (
          await run(ffprobe, [
            ...['-v', 'error', '-select_streams', 'v:0', '-count_frames'],
            ...['-show_entries', 'stream=nb_read_frames', '-of', 'json', recordingPath],
          ])
        ).stdout,
      );
      expect(Number(frames.streams[0].nb_read_frames)).toBe(60);
      // Light score box of the bar style: 1080p (432..528, 76..156) scaled by 1/3.
      const box = await run(
        ffmpeg,
        [
          ...['-v', 'error', '-i', recordingPath, '-vf', 'crop=24:20:148:30,format=gray'],
          ...['-fps_mode', 'passthrough', '-f', 'rawvideo', '-'],
        ],
        { encoding: 'buffer', maxBuffer: 8 * 1024 * 1024 },
      );
      const perFrame = 24 * 20;
      expect(box.stdout.length).toBe(60 * perFrame);
      for (let frame = 0; frame < 60; frame++) {
        const pixels = box.stdout.subarray(frame * perFrame, (frame + 1) * perFrame);
        // Digits are dark, the box is light: most pixels bright on every frame.
        expect([...pixels].filter((value) => value > 200).length).toBeGreaterThan(perFrame / 3);
      }
      const corner = await run(
        ffmpeg,
        [
          ...['-v', 'error', '-i', recordingPath, '-vf', 'crop=40:40:600:320,format=gray'],
          ...['-frames:v', '1', '-f', 'rawvideo', '-'],
        ],
        { encoding: 'buffer' },
      );
      expect(Math.max(...corner.stdout)).toBeLessThan(40);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);

it(
  'blends without a format or colorspace conversion of the main video',
  { timeout: 60_000 },
  async () => {
    // Forcing a BT.709 overlay against an untagged camera made FFmpeg 7.1 insert a
    // full-frame YUV->RGB->YUV scale after the overlay on every frame (2x CPU).
    const directory = await mkdtemp(join(tmpdir(), 'scorebug-overlay-negotiation-'));
    try {
      const size = { width: 640, height: 360 };
      const args = buildFfmpegArgs({
        gameId: 'negotiation',
        pullUrl: 'unused',
        publishUrl: 'unused',
        scoreFile: 'unused',
        nvenc: false,
        profile: { ...size, fps: 30, bitrateKbps: 800 },
      });
      const graph = args[args.indexOf('-filter_complex') + 1]!;
      const overlay = graph.slice(graph.indexOf('[1:v:0]'));
      const layout = overlayRegions(size);
      const framer = new MatroskaFramer();
      const canvas = Buffer.alloc(layout.canvas.width * layout.canvas.height * 4, 128);
      const feed = join(directory, 'feed.mkv');
      await writeFile(
        feed,
        Buffer.concat([
          matroskaHeader(layout.canvas.width, layout.canvas.height),
          ...[0, 125, 250, 375, 500].flatMap((time) => framer.frame(time, canvas)),
        ]),
      );
      for (const tags of [[], ['-colorspace', 'bt709', '-color_range', 'tv']]) {
        const result = spawnSync(
          ffmpeg,
          [
            ...['-hide_banner', '-nostdin', '-loglevel', 'verbose'],
            ...['-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30:duration=0.5'],
            ...[
              '-i',
              feed,
              '-filter_complex',
              `[0:v:0]format=yuv420p,setparams=range=${tags.length ? 'tv' : 'unknown'}${tags.length ? ':colorspace=bt709' : ''}[base];${overlay}`,
            ],
            ...['-map', '[video]', '-c:v', 'rawvideo', '-f', 'null', '-'],
          ],
          { encoding: 'utf8', timeout: 20_000, maxBuffer: 8 * 1024 * 1024 },
        );
        expect(result.status, result.stderr.slice(-1500)).toBe(0);
        expect(result.stderr).not.toMatch(
          /auto-inserting filter '[^']+' between the filter 'Parsed_overlay/,
        );
        expect(result.stderr).not.toMatch(/using intermediate RGB to convert/);
      }
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);
