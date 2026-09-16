import { expect, it } from 'vitest';
import { DecodedFrameHistory } from '../src/decoded-frame-history.js';
import { encoderTime90k, EncoderTimingTelemetry } from '../src/encoder-timing.js';
const row = (i: number, pts: number) => `frame:${i} pts:${pts} pts_time:0\nscorebug.source=1\n`;
it('retains exact decoded coordinates and observed times independently of snapshots', () => {
  let now = 10;
  const t = new DecodedFrameHistory(() => now, 'scope');
  for (const byte of Buffer.from(row(0, -3000))) t.push(Buffer.from([byte]));
  const saved = t.snapshot();
  now = 20;
  t.push(Buffer.from(row(1, 0) + row(2, 3000)));
  expect(t.snapshot()).toMatchObject({
    scopeID: 'scope',
    acceptedFrames: 3,
    invalidReason: null,
    frames: [
      { pts: -3000, observedAt: 10 },
      { pts: 0, observedAt: 20 },
      { pts: 3000, observedAt: 20 },
    ],
  });
  expect(saved.frames).toEqual([{ pts: -3000, observedAt: 10 }]);
});
it('evicts only the oldest decoder records at a fixed 512-record bound', () => {
  const t = new DecodedFrameHistory(() => 0);
  for (let i = 0; i < 20_000; i++) t.push(Buffer.from(row(i, i * 3000)));
  expect(t.snapshot()).toMatchObject({ acceptedFrames: 20_000, invalidReason: null });
  expect(t.snapshot().frames).toHaveLength(512);
  expect(t.snapshot().frames[0]?.pts).toBe(19_488 * 3000);
});
it.each([
  row(0, 0) + row(1, 0),
  row(0, 1) + row(1, 0),
  row(1, 0),
  'x'.repeat(1025),
  row(0, 0).slice(0, -1),
])('quarantines invalid decoder evidence %#', (input) => {
  const t = new DecodedFrameHistory(() => 0);
  t.push(Buffer.from(input));
  t.end();
  expect(t.snapshot().invalidReason).not.toBeNull();
  const saved = t.snapshot();
  t.push(Buffer.from(row(1, 3000)));
  expect(t.snapshot()).toEqual(saved);
});
it.each([NaN, Infinity, -1, Number.MAX_SAFE_INTEGER + 1, 0.5])(
  'rejects invalid or reversed decoder clocks %s',
  (bad) => {
    let now = 1;
    const t = new DecodedFrameHistory(() => now);
    t.push(Buffer.from(row(0, 0)));
    now = bad;
    t.push(Buffer.from(row(1, 1)));
    expect(t.snapshot().invalidReason).toBe('clock');
  },
);
it('contains throwing clock and pipe errors and freezes terminal history', () => {
  const throwing = new DecodedFrameHistory(() => {
    throw Error('SECRET');
  });
  expect(() => throwing.push(Buffer.from(row(0, 0)))).not.toThrow();
  expect(throwing.snapshot().invalidReason).toBe('clock');
  const t = new DecodedFrameHistory(() => 0);
  t.push(Buffer.from(row(0, 0)));
  t.invalidatePipe();
  t.end();
  const saved = t.snapshot();
  expect(saved).toMatchObject({ ended: true, invalidReason: 'pipe' });
  t.push(Buffer.from(row(1, 3000)));
  t.invalidatePipe();
  expect(t.snapshot()).toEqual(saved);
  const closed = new DecodedFrameHistory(() => 0);
  closed.push(Buffer.from(row(0, 0)));
  closed.end();
  closed.invalidatePipe();
  expect(closed.snapshot()).toMatchObject({ ended: true, invalidReason: null });
});
it('assigns independent pipeline scope unless explicitly shared', () => {
  const a = new EncoderTimingTelemetry(),
    b = new DecodedFrameHistory();
  expect(a.snapshot().scopeID).not.toBe(b.snapshot().scopeID);
  const shared = new DecodedFrameHistory(() => 0, a.scopeID);
  expect(shared.snapshot().scopeID).toBe(a.snapshot().scopeID);
});
it('projects rational encoder PTS exactly without rounding or unsafe numbers', () => {
  expect(encoderTime90k({ pts: '1', timeBaseNumerator: 1, timeBaseDenominator: 30 })).toBe(3000);
  expect(encoderTime90k({ pts: '-1', timeBaseNumerator: 1001, timeBaseDenominator: 30000 })).toBe(
    -3003,
  );
  expect(
    encoderTime90k({ pts: '1', timeBaseNumerator: 1001, timeBaseDenominator: 60000 }),
  ).toBeNull();
  expect(
    encoderTime90k({ pts: '9007199254740991', timeBaseNumerator: 1, timeBaseDenominator: 90000 }),
  ).toBe(Number.MAX_SAFE_INTEGER);
  expect(
    encoderTime90k({ pts: '9007199254740992', timeBaseNumerator: 1, timeBaseDenominator: 90000 }),
  ).toBeNull();
  expect(
    encoderTime90k({
      pts: '-9223372036854775808',
      timeBaseNumerator: 1,
      timeBaseDenominator: 90000,
    }),
  ).toBeNull();
});
