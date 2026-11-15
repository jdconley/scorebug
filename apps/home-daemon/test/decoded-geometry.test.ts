import { expect, it } from 'vitest';
import { DecodedGeometry } from '../src/decoded-geometry.mjs';
const prefix = '[showinfo@scorebug_geometry @ 0xabc] [info] ';
const config = prefix + 'config in time_base: 1/90000, frame_rate: 30/1\n';
const row = (n: number | string, pts: number | string, size = '426x240') =>
  `${prefix}n: ${n} pts: ${pts} pts_time:0 duration:3000 duration_time:0.0333333 fmt:yuv420p cl:left sar:1/1 s:${size} i:P iskey:1 type:I \n`;
const push = (p: DecodedGeometry, value: string) => p.push(Buffer.from(value));

it('joins split chunks into bounded contiguous decoded geometry runs and detached snapshots', () => {
  const p = new DecodedGeometry();
  const input =
    config +
    Array.from({ length: 18 }, (_, n) =>
      row(n, n * 3000, ['426x240', '640x360', '1280x720'][Math.floor(n / 6)]),
    ).join('');
  for (const byte of Buffer.from(input)) p.push(Uint8Array.of(byte));
  p.end();
  expect(p.snapshot()).toMatchObject({
    formatVersion: 1,
    diagnosticOnly: true,
    timeBase: '1/90000',
    maximumRuns: 64,
    ended: true,
    invalidReason: null,
    observedFrames: 18,
  });
  expect(p.snapshot().runs).toEqual(
    [426, 640, 1280].map((width, i) => ({
      width,
      height: [240, 360, 720][i],
      firstOrdinal: i * 6,
      lastOrdinal: i * 6 + 5,
      firstPTS: i * 18000,
      lastPTS: i * 18000 + 15000,
      frames: 6,
      maximumPTSDelta: 3000,
    })),
  );
  const detached = p.snapshot();
  detached.runs[0]!.width = 900;
  expect(p.snapshot().runs[0]!.width).toBe(426);
});
it('ignores auxiliary/unrelated private lines without retaining raw bytes', () => {
  const p = new DecodedGeometry();
  push(
    p,
    `SECRET_URL\n[showinfo@other @ 0xabc] n:0 pts:0 s:1920x1080\n${config}${prefix}color_range:SECRET\n${prefix}  side data - SECRET\n${prefix}User Data=SECRET\n${row(0, -3000)}${row(1, 0)}`,
  );
  p.end();
  expect(p.snapshot().invalidReason).toBeNull();
  expect(p.snapshot().observedFrames).toBe(2);
  expect(JSON.stringify(p.snapshot())).not.toContain('SECRET');
});
it.each([
  [config.replace('1/90000', '1/1000') + row(0, 0), 'time_base'],
  [row(0, 0), 'time_base'],
  [config + row(1, 0), 'ordinal'],
  [config + row(0, 0) + row(2, 3000), 'ordinal'],
  [config + row(0, 0) + row(0, 3000), 'ordinal'],
  [config + row(0, 0) + row(1, 0), 'pts_order'],
  [config + row(0, 0) + row(1, -1), 'pts_order'],
  [config + row('NaN', 0), 'number'],
  [config + row(0, '1e3'), 'number'],
  [config + row(0, '9007199254740992'), 'number'],
  [config + row(0, 0, '427x240'), 'dimensions'],
  [config + row(0, 0, '0x240'), 'dimensions'],
  [config + row(0, 0, '7682x4320'), 'dimensions'],
  [config + row(0, 0, '1280x4322'), 'dimensions'],
  [config + row(0, 0, 'SECRET'), 'dimensions'],
  [config + prefix + 'n: 0 pts: bad\n', 'frame_row'],
] as const)('fails closed for invalid rows (%s)', (input, reason) => {
  const p = new DecodedGeometry();
  push(p, input);
  const before = p.snapshot();
  push(p, row(0, 0));
  p.failPipe();
  p.timeOutDrain();
  p.end();
  expect(p.snapshot().invalidReason).toBe(reason);
  expect(p.snapshot().observedFrames).toBe(before.observedFrames);
  expect(JSON.stringify(p.snapshot())).not.toContain('SECRET');
});
it('keeps exactly 64 runs, rejects a 65th without eviction, and drains further input', () => {
  const p = new DecodedGeometry();
  push(p, config);
  for (let n = 0; n < 64; n++) push(p, row(n, n * 3000, n % 2 ? '640x360' : '426x240'));
  expect(p.snapshot().runs).toHaveLength(64);
  push(p, row(64, 192000));
  p.push(Buffer.alloc(1_000_000, 65));
  p.end();
  expect(p.snapshot()).toMatchObject({
    invalidReason: 'run_limit',
    observedFrames: 64,
    ended: true,
  });
  expect(p.snapshot().runs[0]?.firstOrdinal).toBe(0);
});
it.each(['pipe', 'drain', 'incomplete', 'oversized', 'empty', 'missing'] as const)(
  'records lifecycle failure %s',
  (mode) => {
    const p = new DecodedGeometry();
    if (mode !== 'missing') push(p, config);
    if (mode === 'pipe') p.failPipe();
    if (mode === 'drain') p.timeOutDrain();
    if (mode === 'incomplete') push(p, row(0, 0).trimEnd());
    if (mode === 'oversized') p.push(Buffer.alloc(4097, 65));
    p.end();
    p.end();
    push(p, row(0, 0));
    expect(p.snapshot().invalidReason).toBe(
      {
        pipe: 'pipe_error',
        drain: 'drain_timeout',
        incomplete: 'incomplete_line',
        oversized: 'oversized_line',
        empty: 'no_frames',
        missing: 'time_base',
      }[mode],
    );
    expect(p.snapshot().ended).toBe(true);
  },
);

it.each(['pts_time:NaN', 'duration:NaN', 'duration_time:SECRET'])(
  'rejects malformed numeric frame fields %s',
  (replacement) => {
    const p = new DecodedGeometry();
    const key = replacement.split(':')[0];
    push(p, config + row(0, 0).replace(new RegExp(key + ':\\S+'), replacement));
    p.end();
    expect(p.snapshot().invalidReason).toBe('number');
    expect(p.snapshot().observedFrames).toBe(0);
  },
);
it('accepts the exact framing and dimension limits and rejects unsafe PTS deltas', () => {
  const p = new DecodedGeometry();
  push(p, 'x'.repeat(4096) + '\n' + config + row(0, 0, '7680x4320'));
  p.end();
  expect(p.snapshot().invalidReason).toBeNull();
  const unsafe = new DecodedGeometry();
  push(unsafe, config + row(0, -Number.MAX_SAFE_INTEGER) + row(1, Number.MAX_SAFE_INTEGER));
  unsafe.end();
  expect(unsafe.snapshot().invalidReason).toBe('pts_order');
});
