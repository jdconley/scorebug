import { PassThrough } from 'node:stream';
import { expect, it } from 'vitest';
import {
  EncoderTimingTelemetry,
  observeEncoderTimingPipe,
  encoderTimingInterval,
  type EncoderTime,
} from '../src/encoder-timing.js';
const time = (pts: string | number, n = 1, d = 30): EncoderTime => ({
  pts: String(pts),
  timeBaseNumerator: n,
  timeBaseDenominator: d,
});
const row = (tag: string, n: number, pts: string | number, tb = '1/30') =>
  `${tag} ${n} ${tb} ${pts}\n`;

it('correlates exact wide and negative rational coordinates across stage timebases', () => {
  let clock = 10;
  const tracker = new EncoderTimingTelemetry(() => clock);
  tracker.push(Buffer.from(row('pre', 0, -3) + row('pre', 1, '9007199254740993')));
  clock = 20;
  tracker.push(
    Buffer.from(row('post', 0, -9000, '1/90000') + row('post', 1, '27021597764222979', '1/90')),
  );
  const snapshot = tracker.snapshot();
  expect(snapshot).toMatchObject({
    submittedFrames: 2,
    completedFrames: 2,
    pendingFrames: 0,
    invalidReason: null,
  });
  expect(snapshot.frames.map((x) => x.completedAt)).toEqual([20, 20]);
  expect(encoderTimingInterval(snapshot, time(-3), time('9007199254740993'))).toEqual({
    submittedFrames: 1,
    meanObservedDurationMs: 10,
    maximumObservedDurationMs: 10,
  });
});
it('allows reordered completions while preserving submission order and exact matching', () => {
  let clock = 0;
  const t = new EncoderTimingTelemetry(() => clock);
  t.push(Buffer.from(row('pre', 0, 0) + row('pre', 1, 1) + row('pre', 2, 2)));
  clock = 4;
  t.push(Buffer.from(row('post', 0, 2)));
  clock = 8;
  t.push(Buffer.from(row('post', 1, 0) + row('post', 2, 1)));
  expect(t.snapshot().frames.map((x) => x.completedAt)).toEqual([8, 8, 4]);
  expect(t.snapshot().maximumObservedPendingFrames).toBe(3);
  expect(encoderTimingInterval(t.snapshot(), time(0), time(2))).toEqual({
    submittedFrames: 2,
    meanObservedDurationMs: 6,
    maximumObservedDurationMs: 8,
  });
});
it('handles arbitrary byte chunking and preserves current pending age', () => {
  let clock = 100;
  const t = new EncoderTimingTelemetry(() => clock);
  for (const byte of Buffer.from(row('pre', 0, 0))) t.push(Buffer.from([byte]));
  clock = 350;
  expect(t.snapshot()).toMatchObject({
    pendingFrames: 1,
    oldestPendingAgeMs: 250,
    invalidReason: null,
  });
  expect(encoderTimingInterval(t.snapshot(), time(0), time(1))).toBeNull();
  t.push(Buffer.from(row('post', 0, 0)));
  expect(t.snapshot()).toMatchObject({ pendingFrames: 0, oldestPendingAgeMs: null });
});
it('requires both exact retained anchors and completion of every included submission', () => {
  const t = new EncoderTimingTelemetry(() => 1);
  t.push(
    Buffer.from(
      row('pre', 0, 0) +
        row('pre', 1, 1) +
        row('pre', 2, 2) +
        row('post', 0, 0) +
        row('post', 1, 2),
    ),
  );
  expect(encoderTimingInterval(t.snapshot(), time(0), time(2))).toBeNull();
  t.push(Buffer.from(row('post', 2, 1)));
  expect(encoderTimingInterval(t.snapshot(), time(0), time(2))?.submittedFrames).toBe(2);
  for (const [a, b] of [
    [time(-1), time(2)],
    [time(0), time(3)],
    [time(1), time(1)],
    [time(2), time(0)],
    [time('NaN'), time(2)],
    [time(0, 0), time(2)],
  ])
    expect(encoderTimingInterval(t.snapshot(), a!, b!)).toBeNull();
});
it.each([
  row('pre', 1, 0),
  row('pre', 0, 0) + row('pre', 0, 1),
  row('pre', 0, 0) + row('pre', 1, 0),
  row('pre', 0, 1) + row('pre', 1, 0),
  row('post', 0, 0),
  row('pre', 0, 0) + row('post', 1, 0),
  row('pre', 0, 0) + row('post', 0, 0) + row('post', 1, 0),
  row('pre', 0, '9223372036854775808'),
  row('pre', 0, '-9223372036854775808'),
  row('pre', 0, 0, '0/0'),
  row('pre', 0, 0, '1/2147483648'),
  row('pre', 0, 0, '-1/30'),
  'pre 9007199254740992 1/30 0\n',
  'pre 0 1/30 1.2\n',
  'pre 0 1/30 0 SECRET\n',
  'x'.repeat(257) + '\n',
  'pre 0 1/30 0\u0000\n',
  'pre 0 1/30 0é\n',
])('quarantines malformed or contradictory evidence %#', (input) => {
  const t = new EncoderTimingTelemetry(() => 0);
  t.push(Buffer.from(input));
  expect(t.snapshot().invalidReason).not.toBeNull();
  t.push(Buffer.from(row('pre', 0, 0) + row('post', 0, 0)));
  expect(encoderTimingInterval(t.snapshot(), time(0), time(1))).toBeNull();
});
it('bounds retained history and never evicts an outstanding frame silently', () => {
  const t = new EncoderTimingTelemetry(() => 0);
  for (let i = 0; i < 20_000; i++) t.push(Buffer.from(row('pre', i, i) + row('post', i, i)));
  expect(t.snapshot()).toMatchObject({
    submittedFrames: 20_000,
    completedFrames: 20_000,
    invalidReason: null,
  });
  expect(t.snapshot().frames).toHaveLength(256);
  expect(encoderTimingInterval(t.snapshot(), time(19_743), time(19_999))).toBeNull();
  expect(encoderTimingInterval(t.snapshot(), time(19_744), time(19_999))?.submittedFrames).toBe(
    255,
  );
  const blocked = new EncoderTimingTelemetry(() => 0);
  for (let i = 0; i < 257; i++) blocked.push(Buffer.from(row('pre', i, i)));
  expect(blocked.snapshot().invalidReason).not.toBeNull();
  expect(blocked.snapshot().frames.length).toBeLessThanOrEqual(256);
});
it.each([NaN, Infinity, -1, Number.MAX_SAFE_INTEGER + 1, 0.5])(
  'quarantines invalid or reversed clocks %s',
  (bad) => {
    let clock = 1;
    const t = new EncoderTimingTelemetry(() => clock);
    t.push(Buffer.from(row('pre', 0, 0)));
    clock = bad;
    t.push(Buffer.from(row('post', 0, 0)));
    expect(t.snapshot().invalidReason).not.toBeNull();
  },
);
it('quarantines a throwing clock without escaping the pipe drain', () => {
  const t = new EncoderTimingTelemetry(() => {
    throw Error('secret');
  });
  expect(() => t.push(Buffer.from(row('pre', 0, 0)))).not.toThrow();
  expect(t.snapshot().invalidReason).toBe('clock');
});
it('closes and freezes partial pending ages; immutable snapshots retain prior values', () => {
  let clock = 1;
  const t = new EncoderTimingTelemetry(() => clock);
  t.push(Buffer.from(row('pre', 0, 0)));
  const before = t.snapshot();
  clock = 2;
  t.push(Buffer.from(row('post', 0, 0) + row('pre', 1, 1)));
  clock = 3;
  t.end();
  const closed = t.snapshot();
  expect(closed).toMatchObject({
    ended: true,
    pendingFrames: 1,
    oldestPendingAgeMs: 1,
    invalidReason: null,
  });
  clock = 100;
  t.push(Buffer.from(row('post', 1, 1)));
  t.end();
  expect(t.snapshot()).toEqual(closed);
  expect(before.frames[0]?.completedAt).toBeNull();
  expect(before.ended).toBe(false);
});
it('rejects a truncated terminal record', () => {
  const t = new EncoderTimingTelemetry(() => 0);
  t.push(Buffer.from('pre 0 1/30 0'));
  t.end();
  expect(t.snapshot()).toMatchObject({ ended: true, invalidReason: 'incomplete' });
});

it.each([true, false])('isolates pipe errors even when timing is enabled=%s', (enabled) => {
  const pipe = new PassThrough();
  const timing = new EncoderTimingTelemetry(() => 0);
  observeEncoderTimingPipe(pipe, enabled ? timing : undefined);
  expect(() => pipe.emit('error', new Error('SECRET diagnostic failure'))).not.toThrow();
  if (enabled) expect(timing.snapshot().invalidReason).toBe('pipe');
  pipe.emit('close');
  if (enabled) expect(timing.snapshot().ended).toBe(true);
});
it('treats a side channel closing without EOF as unavailable evidence', () => {
  const pipe = new PassThrough();
  const timing = new EncoderTimingTelemetry(() => 0);
  observeEncoderTimingPipe(pipe, timing);
  pipe.emit('close');
  expect(timing.snapshot()).toMatchObject({ ended: true, invalidReason: 'pipe' });
});
it('evicts completed history while preserving younger pending correlations', () => {
  const t = new EncoderTimingTelemetry(() => 0);
  for (let i = 0; i < 200; i++) t.push(Buffer.from(row('pre', i, i) + row('post', i, i)));
  for (let i = 200; i < 300; i++) t.push(Buffer.from(row('pre', i, i)));
  expect(t.snapshot()).toMatchObject({ pendingFrames: 100, invalidReason: null });
  for (let i = 200; i < 300; i++) t.push(Buffer.from(row('post', i, i)));
  expect(t.snapshot()).toMatchObject({
    pendingFrames: 0,
    completedFrames: 300,
    invalidReason: null,
  });
  expect(encoderTimingInterval(t.snapshot(), time(44), time(299))?.submittedFrames).toBe(255);
});
