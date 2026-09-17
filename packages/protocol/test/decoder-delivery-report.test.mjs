import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  deliveryPacketValid,
  deliveryDelta,
  advanceDelivery,
  deliverySnapshot,
} from '../dist/decoder-delivery-report.js';
const scopeID = '11111111-1111-4111-8111-111111111111';
const full = (n = 3) => ({
  formatVersion: 1,
  scopeID,
  sampledAtMs: n * 40 + 10,
  coverageAtMs: n > 256 ? (n - 256) * 40 : 0,
  afterOrdinal: Math.max(0, n - 256),
  lastOrdinal: n,
  arrivals: Array.from({ length: Math.min(n, 256) }, (_, i) => [
    (Math.max(0, n - 256) + i) * 3000,
    (Math.max(0, n - 256) + i + 1) * 40,
  ]),
  invalidReason: null,
  ended: false,
});
test('round trips full, partial, overlap and retired histories without changing source identity', () => {
  let h = advanceDelivery(undefined, full());
  for (const n of [6, 9, 260, 300, 600]) {
    const f = full(n);
    const d = deliveryDelta(f, { scopeID, lastOrdinal: h.lastOrdinal });
    h = advanceDelivery(h, d);
    assert.deepEqual(h, f);
    assert.deepEqual(advanceDelivery(h, d), f, 'lost acknowledgement can resend overlap');
  }
  const s = deliverySnapshot(h);
  assert.equal(s.arrivals.length, 256);
  assert.equal(s.arrivals[0].ordinal, 345);
  assert.equal(s.coverageAgeMs, h.sampledAtMs - h.coverageAtMs);
  assert.equal(s.arrivals.at(-1).ageMs, 10);
});
test('rejects partial history without a base; falls back to a full retained tail for old or wrong cursors', () => {
  const f = full(300);
  assert.equal(deliveryDelta(f, { scopeID, lastOrdinal: 10 }).afterOrdinal, 44);
  assert.equal(deliveryDelta(f, { scopeID: 'other', lastOrdinal: 290 }).afterOrdinal, 44);
  assert.throws(() => advanceDelivery(undefined, deliveryDelta(f, { scopeID, lastOrdinal: 299 })));
});
test('preserves omission and rejects changed overlap, clocks, lost base, reversed scope and terminal resurrection', () => {
  const h = full(260);
  assert.equal(advanceDelivery(h, undefined), h);
  for (const damage of [
    (p) => (p.scopeID = '22222222-2222-4222-8222-222222222222'),
    (p) => p.sampledAtMs--,
    (p) => p.arrivals[0][0]++,
    (p) => p.arrivals[0][1]++,
    (p) => p.coverageAtMs++,
  ]) {
    const p = structuredClone(h);
    damage(p);
    assert.throws(() => advanceDelivery(h, p));
  }
  const gap = deliveryDelta(full(270), { scopeID, lastOrdinal: 265 });
  assert.throws(() => advanceDelivery(h, gap));
  assert.throws(() => advanceDelivery({ ...h, ended: true }, full(270)));
  assert.throws(() => advanceDelivery({ ...h, invalidReason: 'clock' }, full(270)));
  const future = full(261);
  future.arrivals.at(-1)[1] = h.sampledAtMs - 1;
  assert.throws(() => advanceDelivery(h, future));
});
test('strict shape rejects unsafe numeric bounds, extra keys and mismatched lengths', () => {
  assert(deliveryPacketValid(full()));
  for (const damage of [
    (p) => (p.extra = 1),
    (p) => (p.lastOrdinal = Infinity),
    (p) => (p.afterOrdinal = -1),
    (p) => (p.afterOrdinal = 1),
    (p) => p.arrivals[0].push(1),
    (p) => (p.arrivals[0][0] = 0.5),
    (p) => (p.arrivals[0][1] = NaN),
    (p) => (p.coverageAtMs = 1),
    (p) => (p.sampledAtMs = 0),
    (p) => (p.invalidReason = 'anything'),
    (p) => (p.ended = 1),
    (p) => (p.arrivals = Array(257).fill([0, 0])),
  ]) {
    const p = full();
    damage(p);
    assert(!deliveryPacketValid(p));
  }
});
test('ordinary 30 fps reports send three new tuples, with bounded resynchronization', () => {
  const h = full(256);
  const d = deliveryDelta(full(259), { scopeID, lastOrdinal: 256 });
  assert.equal(d.arrivals.length, 3);
  assert(Buffer.byteLength(JSON.stringify(d)) < 400);
  assert.equal(deliveryDelta(full(600), { scopeID, lastOrdinal: 256 }).arrivals.length, 256);
});
