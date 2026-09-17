import { expect, it } from 'vitest';
import { DecoderCadenceTelemetry } from '../src/decoder-cadence.js';
const record = (ordinal: number, pts: number) =>
  Buffer.from(`frame:${ordinal} pts:${pts} pts_time:${pts / 90000}\nscorebug.source=1\n`);
function fixture() {
  let now = 100;
  const telemetry = new DecoderCadenceTelemetry(() => now);
  let ordinal = 0;
  return {
    telemetry,
    at: (time: number) => {
      now = time;
    },
    frame: (pts: number) => telemetry.push(record(ordinal++, pts)),
  };
}
it('measures independent complete one- and two-second windows at exact boundaries', () => {
  const f = fixture();
  for (let n = 0; n < 60; n++) {
    f.at(100 + (n * 1000) / 30);
    f.frame(n * 3000);
  }
  f.at(2100);
  const s = f.telemetry.snapshot();
  expect(s.oneSecond).toMatchObject({
    sequence: 2,
    durationMs: 1000,
    freshFrames: 30,
    firstPTS: 90000,
    lastPTS: 177000,
    ageMs: 0,
  });
  expect(s.twoSeconds).toMatchObject({
    sequence: 1,
    durationMs: 2000,
    freshFrames: 60,
    firstPTS: 0,
    lastPTS: 177000,
    ageMs: 0,
  });
  expect(s.progress).toMatchObject({ lastFreshPTS: 177000, stalled: false });
});
it.each([23, 24, 30])(
  'reports actual one-second count %i without rounding or inventing healthy delivery',
  (count) => {
    const f = fixture();
    for (let n = 0; n < count; n++) {
      f.at(100 + n * 30);
      f.frame(n * 3000);
    }
    f.at(1100);
    expect(f.telemetry.snapshot().oneSecond?.freshFrames).toBe(count);
  },
);
it('watchdog fires at one second without new input and ignores duplicate/reordered PTS', () => {
  const f = fixture();
  f.frame(0);
  f.at(1099);
  f.frame(0);
  f.frame(-3000);
  expect(f.telemetry.snapshot().progress?.stalled).toBe(false);
  f.at(1100);
  const s = f.telemetry.snapshot();
  expect(s.progress).toEqual({ lastFreshPTS: 0, ageMs: 1000, stalled: true });
  expect(s.oneSecond).toMatchObject({ freshFrames: 1, duplicateFrames: 1, reorderedFrames: 1 });
  f.at(1150);
  f.frame(3000);
  expect(f.telemetry.snapshot().progress?.stalled).toBe(false);
});
it('unstarted and ended pipelines never claim a live stall', () => {
  const f = fixture();
  f.at(5000);
  expect(f.telemetry.snapshot().progress).toBeNull();
  f.frame(0);
  f.at(5500);
  f.telemetry.end();
  f.at(9000);
  const s = f.telemetry.snapshot();
  expect(s.ended).toBe(true);
  expect(s.progress?.stalled).toBe(false);
  expect(s.oneSecond).toBeNull();
  f.frame(3000);
  expect(f.telemetry.snapshot()).toEqual(s);
});
it('sparse sampling retains the latest actual empty windows without unbounded history', () => {
  const f = fixture();
  f.frame(0);
  f.at(10_000_100);
  const s = f.telemetry.snapshot();
  expect(s.oneSecond).toMatchObject({
    sequence: 10000,
    freshFrames: 0,
    firstPTS: null,
    lastPTS: null,
  });
  expect(s.twoSeconds).toMatchObject({ sequence: 5000, freshFrames: 0 });
  expect(s.progress?.stalled).toBe(true);
  expect(JSON.stringify(s).length).toBeLessThan(1500);
});
it.each([NaN, Infinity, -1, 99])(
  'invalid clocks invalidate evidence and cannot claim a stall (%s)',
  (time) => {
    const f = fixture();
    f.frame(0);
    f.at(time);
    const s = f.telemetry.snapshot();
    expect(s.invalidReason).toBe('clock');
    expect(s.progress?.stalled).toBe(false);
    f.at(3000);
    f.frame(3000);
    expect(f.telemetry.snapshot().invalidReason).toBe('clock');
  },
);
it('clock exceptions, malformed records and pipe failure fail closed', () => {
  const broken = new DecoderCadenceTelemetry(() => {
    throw new Error('private');
  });
  broken.push(record(0, 0));
  expect(broken.snapshot().invalidReason).toBe('clock');
  for (const mode of ['syntax', 'pipe', 'partial']) {
    const f = fixture();
    f.frame(0);
    if (mode === 'syntax') f.telemetry.push(Buffer.from('SECRET\n'));
    else if (mode === 'pipe') f.telemetry.invalidatePipe();
    else {
      f.telemetry.push(Buffer.from('frame:1'));
      f.telemetry.end();
    }
    f.at(5000);
    const s = f.telemetry.snapshot();
    expect(s.invalidReason).not.toBeNull();
    expect(s.progress?.stalled).toBe(false);
    expect(JSON.stringify(s)).not.toContain('SECRET');
  }
});
it('new pipelines have independent scope and snapshots cannot mutate the owner', () => {
  const a = fixture(),
    b = fixture();
  expect(a.telemetry.snapshot().scopeID).not.toBe(b.telemetry.snapshot().scopeID);
  a.frame(0);
  a.at(1100);
  const s = a.telemetry.snapshot();
  if (s.oneSecond) s.oneSecond.freshFrames = 900;
  expect(a.telemetry.snapshot().oneSecond?.freshFrames).toBe(1);
});
