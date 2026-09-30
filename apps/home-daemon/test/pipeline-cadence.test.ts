import { spawnSync } from 'node:child_process';
import { expect, it } from 'vitest';
import { FrameRateCap } from '../src/frame-rate-cap.js';
import { buildFfmpegArgs } from '../src/pipeline.js';

function selectedPTS(rate: number, duration: number, timestamps: string): number[] {
  const args = buildFfmpegArgs({
    gameId: 'cadence',
    pullUrl: 'unused',
    recordingPath: 'unused',
    scoreFile: 'unused',
    nvenc: false,
    profile: { width: 64, height: 64, fps: 30, bitrateKbps: 100 },
  });
  const graph = args[args.indexOf('-vf') + 1]!;
  const cap = /\[live\]settb=1\/90000,(select='[^']+'),scale=/.exec(graph)?.[1];
  expect(cap).toBeDefined();
  const result = spawnSync(
    process.env.SCOREBUG_FFMPEG_PATH ?? 'ffmpeg',
    [
      '-hide_banner',
      '-nostdin',
      '-f',
      'lavfi',
      '-i',
      `testsrc2=size=64x64:rate=${rate}:duration=${duration}`,
      '-vf',
      `settb=1/90000,setpts='${timestamps}',${cap},showinfo`,
      '-fps_mode',
      'passthrough',
      '-f',
      'null',
      '-',
    ],
    { encoding: 'utf8', timeout: 10000, maxBuffer: 2 * 1024 * 1024 },
  );
  expect(result.error).toBeUndefined();
  expect(result.status, result.stderr.slice(-1500)).toBe(0);
  return [...result.stderr.matchAll(/\bn:\s*\d+\s+pts:\s*(-?\d+)/g)].map((match) =>
    Number(match[1]),
  );
}

it('preserves every acquired 30fps frame with small alternating clock jitter', () => {
  const pts = selectedPTS(30, 5, 'N*3000+if(mod(N,2),-30,30)');
  expect(pts).toEqual(Array.from({ length: 150 }, (_, n) => n * 3000 + (n % 2 ? -30 : 30)));
});

it('caps 60fps acquisition at 30fps with at most one spare frame of burst credit', () => {
  const pts = selectedPTS(60, 5, 'N*1500');
  expect(pts.length).toBeGreaterThanOrEqual(150);
  expect(pts.length).toBeLessThanOrEqual(151);
  expect(pts.every((p, i) => !i || p > pts[i - 1]!)).toBe(true);
});

it('does not duplicate source timestamps or fill acquisition gaps', () => {
  const pts = selectedPTS(60, 5, 'floor(N/2)*3000+if(gte(N,120),90000,0)');
  expect(pts.length).toBe(150);
  expect(pts.every((p, i) => !i || p > pts[i - 1]!)).toBe(true);
  expect(Math.max(...pts.slice(1).map((p, i) => p - pts[i]!))).toBeGreaterThan(90000);
});

it('does not accumulate unbounded output credits during a long acquisition gap', () => {
  const pts = selectedPTS(60, 5, 'N*1500+if(gte(N,120),90000000,0)');
  const afterGap = pts.filter((p) => p >= 90000000);
  expect(afterGap.length).toBeLessThanOrEqual(92);
});

it('matches the FFmpeg cap decisions across jitter, bursts, gaps and long clock offsets', () => {
  for (const expression of [
    'N*3000+if(mod(N,2),-30,30)',
    'N*1500',
    'floor(N/2)*3000+if(gte(N,120),90000,0)',
    'N*1500+if(gte(N,120),90000000,0)',
    'N*1500+9000000000',
    'N*1500-900000',
  ]) {
    const actual = selectedPTS(60, 5, expression);
    const cap = new FrameRateCap(30);
    const source = Array.from({ length: 300 }, (_, n) => {
      if (expression.startsWith('floor')) return Math.floor(n / 2) * 3000 + (n >= 120 ? 90000 : 0);
      if (expression.includes('mod')) return n * 3000 + (n % 2 ? -30 : 30);
      if (expression.includes('gte')) return n * 1500 + (n >= 120 ? 90000000 : 0);
      return (
        n * 1500 +
        (expression.endsWith('+9000000000')
          ? 9000000000
          : expression.endsWith('-900000')
            ? -900000
            : 0)
      );
    });
    expect(
      source.filter((pts) => cap.select(pts)),
      expression,
    ).toEqual(actual);
  }
});
