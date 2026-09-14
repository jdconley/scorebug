import { expect, it } from 'vitest';
import { DecodedVideoParser, DecodedVideoTelemetry } from '../src/decoded-video.js';

const record = (ordinal: number, pts: number, time = '0') =>
  `frame:${ordinal}    pts:${pts}    pts_time:${time}\nscorebug.source=1\n`;

it('parses complete pairs across every byte boundary with signed ticks and diagnostic times', () => {
  const text = record(0, -9000, '-0.1') + record(1, 0, '0') + record(2, 3000, '3.33333e-2');
  for (let split = 0; split <= text.length; split++) {
    const values: number[] = [];
    const errors: string[] = [];
    const parser = new DecodedVideoParser(
      (pts) => values.push(pts),
      (reason) => errors.push(reason),
    );
    parser.push(Buffer.from(text.slice(0, split)));
    parser.push(Buffer.from(text.slice(split)));
    parser.end();
    expect(values).toEqual([-9000, 0, 3000]);
    expect(errors).toEqual([]);
  }
});

it.each([
  record(1, 0),
  record(0, 0) + record(2, 1),
  record(0, 0) + record(0, 1),
  record(0, 9007199254740992),
  record(0, 0, 'Infinity'),
  record(0, 0, 'NaN'),
  record(0, 0).replace('frame:0', 'frame:-1'),
  record(0, 0).replace('frame:0', 'frame:9007199254740992'),
  record(0, 0).replace('pts:0', 'pts:1.5'),
  record(0, 0).replace('pts:0', 'pts:1e3'),
  record(0, 0).replace('scorebug.source=1', 'scorebug.source=1 SECRET'),
  'scorebug.source=1\n',
  'frame:0 pts:0 pts_time:0\nframe:1 pts:1 pts_time:0\nscorebug.source=1\n',
  'x'.repeat(1025),
  record(0, 0).slice(0, -1),
  'frame:0 pts:0 pts_time:0\n',
])('latches malformed or incomplete evidence without exposing input (%#)', (text) => {
  const errors: string[] = [];
  const parser = new DecodedVideoParser(
    () => {},
    (reason) => errors.push(reason),
  );
  parser.push(Buffer.from(text));
  parser.end();
  expect(errors).toHaveLength(1);
  expect(JSON.stringify(errors)).not.toContain('SECRET');
  expect(() => parser.push(Buffer.alloc(1_000_000, 65))).not.toThrow();
  expect(errors).toHaveLength(1);
});

it('contains callback exceptions and keeps draining after failure', () => {
  const errors: string[] = [];
  const parser = new DecodedVideoParser(
    () => {
      throw new Error('SECRET');
    },
    (reason) => {
      errors.push(reason);
      throw new Error('ANOTHER_SECRET');
    },
  );
  expect(() => parser.push(Buffer.from(record(0, 0) + record(1, 1)))).not.toThrow();
  expect(errors).toEqual(['callback']);
  parser.end();
});

it('counts advancing PTS against the high watermark without labeling cadence gaps as loss', () => {
  let now = 100;
  const telemetry = new DecodedVideoTelemetry(() => now);
  telemetry.push(
    Buffer.from(
      [0, 3000, 3000, 1000, 2000, 90000].map((pts, index) => record(index, pts)).join(''),
    ),
  );
  expect(telemetry.snapshot().completed).toBeNull();
  now = 5100;
  expect(telemetry.snapshot().completed).toEqual({
    sequence: 1,
    durationMs: 5000,
    ageMs: 0,
    firstPTS: 0,
    lastPTS: 90000,
    freshFrames: 3,
    duplicateFrames: 1,
    reorderedFrames: 2,
    valid: true,
  });
  now = 5150;
  expect(telemetry.snapshot().completed?.ageMs).toBe(50);
});

it('assigns an exact-boundary frame to the next window and advances long zero-frame outages in constant space', () => {
  let now = 0;
  const telemetry = new DecodedVideoTelemetry(() => now);
  telemetry.push(Buffer.from(record(0, 0)));
  now = 5000;
  telemetry.push(Buffer.from(record(1, 3000)));
  expect(telemetry.snapshot().completed?.freshFrames).toBe(1);
  now = 10000;
  expect(telemetry.snapshot().completed?.freshFrames).toBe(1);
  now = 5_000_000_000;
  expect(telemetry.snapshot().completed).toMatchObject({
    sequence: 1_000_000,
    freshFrames: 0,
    firstPTS: null,
    lastPTS: null,
    ageMs: 0,
  });
});

it('does not start empty evidence and seals final partial windows without inventing later windows', () => {
  let now = 0;
  const telemetry = new DecodedVideoTelemetry(() => now);
  now = 1_000_000;
  expect(telemetry.snapshot().completed).toBeNull();
  telemetry.push(Buffer.from(record(0, 0)));
  now += 6000;
  telemetry.end();
  now += 10000;
  expect(telemetry.snapshot()).toMatchObject({
    ended: true,
    completed: { sequence: 1, ageMs: 11000, freshFrames: 1 },
  });
  const reset = new DecodedVideoTelemetry(() => now);
  expect(reset.snapshot()).toEqual({ completed: null, invalidReason: null, ended: false });
});

it('invalidates clock reversal/nonfinite time, sequence overflow, and malformed telemetry permanently', () => {
  for (const bad of [-1, NaN, Infinity, Number.MAX_SAFE_INTEGER * 5000]) {
    let now = 0;
    const telemetry = new DecodedVideoTelemetry(() => now);
    telemetry.push(Buffer.from(record(0, 0)));
    now = 5000;
    telemetry.snapshot();
    now = bad;
    expect(telemetry.snapshot().invalidReason).not.toBeNull();
    now = 10000;
    expect(telemetry.snapshot().completed?.valid).toBe(false);
  }
  const telemetry = new DecodedVideoTelemetry(() => 0);
  telemetry.push(Buffer.from('bad\n'));
  expect(telemetry.snapshot().invalidReason).not.toBeNull();
});

it('reports only fresh PTS bounds, with null bounds for duplicate/reordered-only windows', () => {
  let now = 0;
  const telemetry = new DecodedVideoTelemetry(() => now);
  telemetry.push(Buffer.from(record(0, 3000) + record(1, 1000)));
  now = 5000;
  telemetry.push(Buffer.from(record(2, 3000) + record(3, 2000)));
  expect(telemetry.snapshot().completed).toMatchObject({ firstPTS: 3000, lastPTS: 3000 });
  now = 10000;
  expect(telemetry.snapshot().completed).toMatchObject({
    firstPTS: null,
    lastPTS: null,
    freshFrames: 0,
    duplicateFrames: 1,
    reorderedFrames: 1,
  });
});

it('latches counter overflow rather than rounding fresh-frame evidence', () => {
  const telemetry = new DecodedVideoTelemetry(() => 0);
  telemetry.push(Buffer.from(record(0, 0)));
  // Fault injection exercises the otherwise unreachable-in-a-short-test safe-integer boundary.
  (telemetry as unknown as { active: { freshFrames: number } }).active.freshFrames =
    Number.MAX_SAFE_INTEGER;
  telemetry.push(Buffer.from(record(1, 1)));
  expect(telemetry.snapshot().invalidReason).toBe('overflow');
});

it('invalidates before the combined counters exceed the safe-integer wire bound', () => {
  const telemetry = new DecodedVideoTelemetry(() => 0);
  telemetry.push(Buffer.from(record(0, 0)));
  const active = (
    telemetry as unknown as { active: { freshFrames: number; duplicateFrames: number } }
  ).active;
  active.freshFrames = Number.MAX_SAFE_INTEGER - 1;
  active.duplicateFrames = 1;
  telemetry.push(Buffer.from(record(1, 0)));
  expect(telemetry.snapshot().invalidReason).toBe('overflow');
  expect(active.duplicateFrames).toBe(1);
});

it.each(['0x10', '0b1', '0o7'])('rejects non-decimal diagnostic timestamp syntax %s', (time) => {
  const errors: string[] = [];
  const values: number[] = [];
  const parser = new DecodedVideoParser(
    (value) => values.push(value),
    (reason) => errors.push(reason),
  );
  parser.push(Buffer.from(record(0, 0, time)));
  expect(errors).toEqual(['numeric']);
  expect(values).toEqual([]);
});
