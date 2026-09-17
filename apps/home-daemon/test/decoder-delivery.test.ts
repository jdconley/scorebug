import { expect, it } from 'vitest';
import { DecoderDeliveryTelemetry } from '../src/decoder-delivery.js';
const packet = (n: number, pts: number) =>
  Buffer.from(`frame:${n} pts:${pts} pts_time:${pts / 90000}\nscorebug.source=1\n`);
function fixture() {
  let now = 100;
  const t = new DecoderDeliveryTelemetry(() => now);
  let n = 0;
  return { t, at: (v: number) => (now = v), frame: (pts: number) => t.push(packet(n++, pts)) };
}
it('retains every duplicate and reordered arrival with its actual age and ordinal', () => {
  const f = fixture();
  f.at(110);
  f.frame(3000);
  f.at(120);
  f.frame(3000);
  f.at(130);
  f.frame(0);
  f.at(150);
  const s = f.t.snapshot();
  expect(s.arrivals).toEqual([
    { ordinal: 1, pts: 3000, ageMs: 40 },
    { ordinal: 2, pts: 3000, ageMs: 30 },
    { ordinal: 3, pts: 0, ageMs: 20 },
  ]);
  expect(s.coverageAgeMs).toBe(50);
  expect(s.lastOrdinal).toBe(3);
  expect(s.invalidReason).toBeNull();
});
it('retirement advances the exclusive coverage boundary without claiming missing history', () => {
  const f = fixture();
  for (let n = 0; n < 300; n++) {
    f.at(101 + n);
    f.frame(n * 3000);
  }
  f.at(500);
  const s = f.t.snapshot();
  expect(s.arrivals).toHaveLength(256);
  expect(s.arrivals[0]?.ordinal).toBe(45);
  expect(s.lastOrdinal).toBe(300);
  expect(s.coverageAgeMs).toBe(500 - 144);
  s.arrivals[0]!.pts = -100;
  expect(f.t.snapshot().arrivals[0]?.pts).toBe(44 * 3000);
});
it('a silence snapshot advances coverage without fabricating arrivals; end freezes ages', () => {
  const f = fixture();
  f.frame(0);
  f.at(2100);
  expect(f.t.snapshot().arrivals[0]?.ageMs).toBe(2000);
  f.t.end();
  f.at(9100);
  expect(f.t.snapshot()).toMatchObject({ ended: true, lastOrdinal: 1, coverageAgeMs: 2000 });
  expect(f.t.snapshot().arrivals[0]?.ageMs).toBe(2000);
  f.frame(3000);
  expect(f.t.snapshot().arrivals).toHaveLength(1);
});
it.each([99, NaN, Infinity, -1])('invalid clock %s cannot produce live usable history', (time) => {
  const f = fixture();
  f.frame(0);
  f.at(time);
  expect(f.t.snapshot().invalidReason).toBe('clock');
});
it('invalid pipe and malformed metadata remain invalid through end', () => {
  for (const mode of ['pipe', 'metadata']) {
    const f = fixture();
    if (mode === 'pipe') f.t.invalidatePipe();
    else f.t.push(Buffer.from('frame:0 pts:bad pts_time:bad\nscorebug.source=1\n'));
    expect(f.t.snapshot().invalidReason).not.toBeNull();
    f.t.end();
    expect(f.t.snapshot().invalidReason).not.toBeNull();
  }
});

it('matches the shared native golden timeline without absolute worker timestamps', async () => {
  const { readFile } = await import('node:fs/promises');
  const golden = JSON.parse(
    await readFile(
      new URL('../../../packages/protocol/fixtures/decoder-delivery-v1.json', import.meta.url),
      'utf8',
    ),
  );
  const f = fixture();
  for (const [at, pts] of [
    [1200, 0],
    [1600, 3000],
    [2900, 6000],
  ]) {
    f.at(at!);
    f.frame(pts!);
  }
  f.at(3100);
  expect({ ...f.t.snapshot(), scopeID: golden.scopeID }).toEqual(golden);
});
