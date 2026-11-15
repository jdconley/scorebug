import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { MatroskaFramer, matroskaHeader } from '../src/scorebug/matroska.js';

const ffprobe = process.env.SCOREBUG_FFPROBE_PATH ?? 'ffprobe';
const ffmpeg = process.env.SCOREBUG_FFMPEG_PATH ?? 'ffmpeg';

describe('MatroskaFramer', () => {
  it('opens a cluster, then writes 16-bit relative keyframe blocks', () => {
    const framer = new MatroskaFramer();
    const first = Buffer.concat(framer.frame(1000, Buffer.from([1, 2, 3, 4])));
    // Cluster ID, unknown size, Timestamp 1000 (0x03E8), SimpleBlock.
    expect(first.subarray(0, 4)).toEqual(Buffer.from([0x1f, 0x43, 0xb6, 0x75]));
    expect(first.subarray(12, 16)).toEqual(Buffer.from([0xe7, 0x82, 0x03, 0xe8]));
    expect(first.subarray(16)).toEqual(Buffer.from([0xa3, 0x88, 0x81, 0, 0, 0x80, 1, 2, 3, 4]));
    const second = Buffer.concat(framer.frame(1125, Buffer.from([5, 6, 7, 8])));
    expect(second).toEqual(Buffer.from([0xa3, 0x88, 0x81, 0x00, 0x7d, 0x80, 5, 6, 7, 8]));
  });
  it('starts a new cluster before the relative timestamp could overflow', () => {
    const framer = new MatroskaFramer();
    framer.frame(0, Buffer.alloc(4));
    expect(framer.frame(29_999, Buffer.alloc(4))[0]![0]).toBe(0xa3);
    expect(framer.frame(30_000, Buffer.alloc(4))[0]).toEqual(Buffer.from([0x1f, 0x43, 0xb6, 0x75]));
  });
  it('rejects non-increasing or invalid timestamps', () => {
    const framer = new MatroskaFramer();
    framer.frame(10, Buffer.alloc(4));
    expect(() => framer.frame(10, Buffer.alloc(4))).toThrow('matroska_timestamp_order');
    expect(() => framer.frame(-1, Buffer.alloc(4))).toThrow('matroska_timestamp');
    expect(() => framer.frame(1.5, Buffer.alloc(4))).toThrow('matroska_timestamp');
  });
});

it('demuxes in FFmpeg as RGBA rawvideo with the written transport-clock timestamps', () => {
  const directory = mkdtempSync(join(tmpdir(), 'scorebug-mkv-'));
  try {
    const path = join(directory, 'overlay.mkv');
    const framer = new MatroskaFramer();
    const pixel = (r: number) => Buffer.from([r, 20, 30, 200, r, 20, 30, 200]);
    // Two pixels wide, one high. Large PTS like a camera's, plus a cluster rollover.
    const times = [3_601_400, 3_601_525, 3_640_000];
    writeFileSync(
      path,
      Buffer.concat([
        matroskaHeader(2, 1),
        ...times.flatMap((time, index) => framer.frame(time, pixel(100 + index))),
      ]),
    );
    const probe = spawnSync(
      ffprobe,
      ['-v', 'error', '-show_streams', '-show_frames', '-of', 'json', path],
      { encoding: 'utf8', timeout: 10_000 },
    );
    expect(probe.status, probe.stderr).toBe(0);
    const parsed = JSON.parse(probe.stdout);
    expect(parsed.streams[0]).toMatchObject({ codec_name: 'rawvideo', pix_fmt: 'rgba', width: 2 });
    expect(parsed.frames.map((frame: { pts: number }) => frame.pts)).toEqual(times);
    const pixels = spawnSync(
      ffmpeg,
      ['-v', 'error', '-i', path, '-fps_mode', 'passthrough', '-f', 'rawvideo', '-'],
      {
        timeout: 10_000,
      },
    );
    expect(pixels.status).toBe(0);
    expect([...pixels.stdout.subarray(0, 4)]).toEqual([100, 20, 30, 200]);
    expect([...pixels.stdout.subarray(16, 20)]).toEqual([102, 20, 30, 200]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
