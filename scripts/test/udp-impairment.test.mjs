import test from 'node:test';
import assert from 'node:assert/strict';
import { DatagramImpairmentQueue } from '../udp-impairment.mjs';
const config = {
  rateBitsPerSecond: 1024,
  burstBytes: 256,
  maxDatagramBytes: 128,
  maxQueuePackets: 8,
  maxQueueBytes: 1024,
  delayMilliseconds: 100,
};
function conserved(s) {
  const kinds = ['forwarded', 'injectedDrop', 'overflowDrop', 'oversizeDrop', 'closeDiscard'];
  for (const key of ['packets', 'wireBytes'])
    assert.equal(
      s.received[key],
      kinds.reduce((n, k) => n + s[k][key], s.queue[key]),
    );
}
test('FIFO delay and actual IPv4/UDP wire-byte accounting', () => {
  const q = new DatagramImpairmentQueue(config);
  assert.equal(q.enqueue(Buffer.alloc(100, 1), 0), true);
  assert.equal(q.enqueue(Buffer.alloc(100, 2), 0), true);
  assert.equal(q.takeReady(99), null);
  assert.equal(q.nextDelay(99), 1);
  assert.equal(q.takeReady(100)[0], 1);
  assert.equal(q.takeReady(100)[0], 2);
  assert.equal(q.takeReady(100), null);
  const s = q.snapshot();
  assert.equal(s.forwarded.wireBytes, 256);
  conserved(s);
});
test('tokens charge wire bytes and cached reads cannot manufacture credits', () => {
  const q = new DatagramImpairmentQueue({ ...config, delayMilliseconds: 0 });
  for (let i = 0; i < 4; i++) q.enqueue(Buffer.alloc(100, i), 0);
  q.takeReady(0);
  q.takeReady(0);
  for (let i = 0; i < 5; i++) assert.equal(q.takeReady(0), null);
  assert.equal(q.nextDelay(0), 1000);
  assert.equal(q.takeReady(999), null);
  assert.equal(q.takeReady(1000)[0], 2);
  assert.equal(q.takeReady(1000), null);
  assert.equal(q.takeReady(2000)[0], 3);
  conserved(q.snapshot());
});
test('idle credit is capped at the configured burst', () => {
  const q = new DatagramImpairmentQueue({ ...config, delayMilliseconds: 0 });
  q.enqueue(Buffer.alloc(100), 0);
  q.takeReady(0);
  for (let i = 0; i < 4; i++) q.enqueue(Buffer.alloc(100), 100000);
  q.takeReady(100000);
  q.takeReady(100000);
  assert.equal(q.takeReady(100000), null);
});
test('bounded FIFO owns queued bytes and counts all rejection paths', () => {
  const q = new DatagramImpairmentQueue({
    ...config,
    maxQueuePackets: 2,
    maxQueueBytes: 256,
    dropEvery: 3,
  });
  const a = Buffer.alloc(100, 1);
  q.enqueue(a, 0);
  a.fill(9);
  q.enqueue(Buffer.alloc(100, 2), 0);
  assert.equal(q.enqueue(Buffer.alloc(100), 0), false); // deterministic loss
  assert.equal(q.enqueue(Buffer.alloc(100), 0), false); // full
  assert.equal(q.enqueue(Buffer.alloc(129), 0), false); // too large
  assert.equal(q.takeReady(100)[0], 1);
  q.close();
  const s = q.snapshot();
  conserved(s);
  assert.equal(s.injectedDrop.packets, 1);
  assert.equal(s.overflowDrop.packets, 1);
  assert.equal(s.oversizeDrop.packets, 1);
  assert.equal(s.closeDiscard.packets, 1);
  assert.equal(s.queue.peakPackets, 2);
  assert.equal(s.queue.peakWireBytes, 256);
  q.enqueue(Buffer.alloc(1), 200);
  q.close();
  assert.deepEqual(q.snapshot(), s);
});
test('byte bound holds independently of packet bound', () => {
  const q = new DatagramImpairmentQueue({ ...config, maxQueuePackets: 8, maxQueueBytes: 200 });
  assert.equal(q.enqueue(Buffer.alloc(100), 0), true);
  assert.equal(q.enqueue(Buffer.alloc(100), 0), false);
  assert.equal(q.snapshot().queue.peakWireBytes, 128);
  conserved(q.snapshot());
});
test('packet bound holds independently of byte bound', () => {
  const q = new DatagramImpairmentQueue({ ...config, maxQueuePackets: 1 });
  q.enqueue(Buffer.alloc(1), 0);
  assert.equal(q.enqueue(Buffer.alloc(1), 0), false);
  assert.equal(q.snapshot().queue.peakPackets, 1);
});
test('unlimited rate still honors delay, FIFO and bounded memory', () => {
  const q = new DatagramImpairmentQueue({ ...config, rateBitsPerSecond: null });
  for (let i = 0; i < 8; i++) q.enqueue(Buffer.alloc(100, i), 0);
  for (let i = 0; i < 8; i++) assert.equal(q.takeReady(100)[0], i);
  assert.equal(q.nextDelay(100), null);
  conserved(q.snapshot());
});
test('rate ceiling holds over deterministic uneven timer wakeups', () => {
  const q = new DatagramImpairmentQueue({
    ...config,
    delayMilliseconds: 0,
    maxQueuePackets: 100,
    maxQueueBytes: 20000,
  });
  for (let i = 0; i < 100; i++) q.enqueue(Buffer.alloc(100), 0);
  const departures = [];
  for (const t of [0, 1, 50, 999, 1000, 1100, 4000, 4000, 4010, 10000]) {
    while (q.takeReady(t)) departures.push({ t, bytes: 128 });
    assert.ok(q.snapshot().forwarded.wireBytes <= 256 + (t * 1024) / 8000 + 1e-8);
  }
  for (const start of [0, 100, 1000, 4000])
    for (const end of [1100, 4000, 10000])
      if (end >= start)
        assert.ok(
          departures.filter((x) => x.t >= start && x.t <= end).length * 128 <=
            256 + ((end - start) * 1024) / 8000 + 1e-8,
        );
  conserved(q.snapshot());
});
for (const [name, change] of Object.entries({
  zeroRate: { rateBitsPerSecond: 0 },
  nanRate: { rateBitsPerSecond: NaN },
  negativeDelay: { delayMilliseconds: -1 },
  infiniteDelay: { delayMilliseconds: Infinity },
  smallBurst: { burstBytes: 100 },
  fractionalLoss: { dropEvery: 2.5 },
  negativeLoss: { dropEvery: -1 },
  zeroPackets: { maxQueuePackets: 0 },
  hugePackets: { maxQueuePackets: 100000 },
  smallQueue: { maxQueueBytes: 100 },
  oversize: { maxDatagramBytes: 65508 },
}))
  test(`rejects invalid ${name}`, () =>
    assert.throws(() => new DatagramImpairmentQueue({ ...config, ...change })));
test('rejects bad or reversed clocks instead of silently refilling', () => {
  const q = new DatagramImpairmentQueue(config);
  q.enqueue(Buffer.alloc(1), 10);
  for (const time of [9, -1, NaN, Infinity]) assert.throws(() => q.takeReady(time));
});

test('rejects rates that overflow the supported timer range', () => {
  for (const rateBitsPerSecond of [Number.MIN_VALUE, 0.5])
    assert.throws(() => new DatagramImpairmentQueue({ ...config, rateBitsPerSecond }));
});

test('rate changes settle old-rate credits and preserve FIFO, delay and accounting', () => {
  const q = new DatagramImpairmentQueue({ ...config, delayMilliseconds: 0 });
  for (let i = 0; i < 5; i++) q.enqueue(Buffer.alloc(100, i), 0);
  assert.equal(q.takeReady(0)[0], 0);
  assert.equal(q.takeReady(0)[0], 1);
  q.setRate(2048, 500); // 64 bytes earned at old rate, not 128 at new rate.
  assert.equal(q.takeReady(500), null);
  assert.equal(q.nextDelay(500), 250);
  assert.equal(q.takeReady(750)[0], 2);
  assert.equal(q.nextDelay(750), 500);
  q.setRate(1024, 1000); // Another 64 bytes, old rate.
  assert.equal(q.takeReady(1499), null);
  assert.equal(q.takeReady(1500)[0], 3);
  assert.equal(q.nextDelay(1500), 1000);
  conserved(q.snapshot());
});
test('unlimited transitions cannot reset tokens or queued delay deadlines', () => {
  const q = new DatagramImpairmentQueue(config);
  for (let i = 0; i < 5; i++) q.enqueue(Buffer.alloc(100, i), 0);
  q.takeReady(100);
  q.takeReady(100);
  q.setRate(null, 100);
  assert.equal(q.takeReady(100)[0], 2);
  q.setRate(1024, 100000);
  assert.equal(q.takeReady(100000), null, 'Unlimited time cannot create credits');
  assert.equal(q.takeReady(101000)[0], 3);
  q.setRate(null, 101000);
  assert.equal(q.takeReady(101000)[0], 4);
  q.enqueue(Buffer.alloc(100, 5), 101000);
  q.setRate(1024, 101000);
  assert.equal(q.takeReady(101099), null);
  assert.equal(q.takeReady(102000)[0], 5);
  conserved(q.snapshot());
});
test('invalid or closed rate updates are atomic', () => {
  const q = new DatagramImpairmentQueue(config);
  q.enqueue(Buffer.alloc(1), 10);
  const before = q.snapshot();
  for (const rate of [undefined, 0, -1, NaN, Infinity, 1e13, 0.5, '1024'])
    assert.throws(() => q.setRate(rate, 1000));
  for (const time of [9, NaN, Infinity, -1]) assert.throws(() => q.setRate(2048, time));
  assert.deepEqual(q.snapshot(), before);
  assert.equal(q.takeReady(110).length, 1);
  q.close();
  const closed = q.snapshot();
  assert.throws(() => q.setRate(null, 110));
  assert.deepEqual(q.snapshot(), closed);
});
test('same-rate updates cannot grant repeated burst credit', () => {
  const q = new DatagramImpairmentQueue({ ...config, delayMilliseconds: 0 });
  for (let i = 0; i < 5; i++) q.enqueue(Buffer.alloc(100), 0);
  q.takeReady(0);
  q.takeReady(0);
  for (let i = 0; i < 5; i++) {
    q.setRate(1024, 0);
    assert.equal(q.takeReady(0), null);
  }
  assert.equal(q.takeReady(1000).length, 100);
  conserved(q.snapshot());
});
