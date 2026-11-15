import test from 'node:test';
import assert from 'node:assert/strict';
import { DatagramImpairmentQueue } from '../udp-impairment.mjs';
const config = {
  maxDatagramBytes: 128,
  burstBytes: 256,
  maxQueueBytes: 256,
  maxQueuePackets: 2,
  delayMilliseconds: 10,
};
test('queue timeline defaults off and explicitly validates selection', () => {
  assert.equal(new DatagramImpairmentQueue(config).snapshot().timeline, undefined);
  for (const value of [null, 1, 'true', {}])
    assert.throws(() => new DatagramImpairmentQueue({ ...config, recordTimeline: value }));
});
test('timeline retains half-open bins, exact dispositions, peaks and residence without changing FIFO', () => {
  const q = new DatagramImpairmentQueue({ ...config, recordTimeline: true });
  q.enqueue(Buffer.alloc(100, 1), 0);
  q.enqueue(Buffer.alloc(100, 2), 99);
  q.enqueue(Buffer.alloc(100), 99);
  q.enqueue(Buffer.alloc(129), 99);
  assert.equal(q.takeReady(100)[0], 1);
  assert.equal(q.takeReady(109)[0], 2);
  q.close(150);
  const t = q.snapshot().timeline;
  assert.equal(t.windowMilliseconds, 100);
  assert.equal(t.capacity, 8192);
  assert.equal(t.windows.length, 2);
  assert.deepEqual(
    t.windows.map((w) => w.start),
    [0, 100],
  );
  assert.equal(t.windows[0].received.packets, 4);
  assert.equal(t.windows[0].received.wireBytes, 541);
  assert.equal(t.windows[0].overflowDrop.packets, 1);
  assert.equal(t.windows[0].oversizeDrop.packets, 1);
  assert.equal(t.windows[0].peakQueueBytes, 256);
  assert.equal(t.windows[0].peakQueuePackets, 2);
  assert.equal(t.windows[1].forwarded.packets, 2);
  assert.equal(t.windows[1].maximumForwardResidenceMilliseconds, 100);
  assert.equal(t.omittedEvents, 0);
  assert.equal(t.firstObservedAt, 0);
  assert.equal(t.lastObservedAt, 150);
  t.windows[0].received.packets = 900;
  assert.equal(q.snapshot().timeline.windows[0].received.packets, 4);
});
test('timeline counts close and injected loss and rejects reversed close before mutation', () => {
  const q = new DatagramImpairmentQueue({ ...config, recordTimeline: true, dropEvery: 2 });
  q.enqueue(Buffer.alloc(100), 0);
  q.enqueue(Buffer.alloc(100), 100);
  const before = q.snapshot();
  assert.throws(() => q.close(99));
  assert.deepEqual(q.snapshot(), before);
  q.close(200);
  q.close(300);
  const t = q.snapshot().timeline;
  assert.equal(t.windows[1].injectedDrop.packets, 1);
  assert.equal(t.windows[2].closeDiscard.packets, 1);
  assert.equal(t.lastObservedAt, 200);
  assert.equal(q.snapshot().queue.wireBytes, 0);
});
test('timeline bounds sparse history and reconciles every omitted counter', () => {
  const q = new DatagramImpairmentQueue({ ...config, recordTimeline: true, delayMilliseconds: 0 });
  for (let n = 0; n < 8200; n++) {
    q.enqueue(Buffer.alloc(100), n * 100);
    q.takeReady(n * 100);
  }
  q.close(820000);
  const s = q.snapshot(),
    t = s.timeline;
  assert.equal(t.windows.length, 8192);
  assert.equal(t.omittedEvents, 16);
  for (const kind of [
    'received',
    'forwarded',
    'injectedDrop',
    'overflowDrop',
    'oversizeDrop',
    'closeDiscard',
  ])
    for (const k of ['packets', 'wireBytes'])
      assert.equal(t.windows.reduce((n, w) => n + w[kind][k], 0) + t.omitted[kind][k], s[kind][k]);
  assert.equal(t.omitted.received.packets, 8);
  assert.equal(t.omitted.forwarded.wireBytes, 1024);
  assert.equal(t.lastObservedAt, 820000);
});

test('independent timeline verifier rejects mutated counts, bounds and clock intervals', async () => {
  const { qualifyDatagramTimeline } = await import('../datagram-timeline-qualification.mjs');
  const q = new DatagramImpairmentQueue({ ...config, recordTimeline: true });
  q.enqueue(Buffer.alloc(100), 0);
  q.takeReady(10);
  q.close(100);
  const s = q.snapshot();
  assert.equal(qualifyDatagramTimeline(s).complete, true);
  for (const mutate of [
    (s) => s.timeline.windows[0].received.packets++,
    (s) => s.timeline.omittedEvents++,
    (s) => (s.timeline.windows[0].peakQueueBytes = 257),
    (s) => (s.timeline.windows[0].start = 99),
    (s) => (s.timeline.lastObservedAt = -1),
    (s) => (s.timeline.windows[0].maximumForwardResidenceMilliseconds = 101),
  ]) {
    const changed = structuredClone(s);
    mutate(changed);
    assert.throws(() => qualifyDatagramTimeline(changed));
  }
});

test('observation preserves queue results across rate, delay, overflow and close transitions', () => {
  const queues = [false, true].map(
    (recordTimeline) =>
      new DatagramImpairmentQueue({ ...config, recordTimeline, rateBitsPerSecond: 1024 }),
  );
  for (let n = 0; n < 1000; n++) {
    const now = n * 7,
      data = Buffer.alloc(n % 3 === 0 ? 129 : 100, n % 255);
    assert.equal(queues[0].enqueue(data, now), queues[1].enqueue(data, now));
    assert.deepEqual(queues[0].takeReady(now), queues[1].takeReady(now));
    if (n === 200 || n === 600) for (const q of queues) q.setRate(n === 200 ? null : 4096, now);
    if (n % 100 === 0) {
      const { timeline, ...observed } = queues[1].snapshot();
      assert.deepEqual(observed, queues[0].snapshot());
    }
  }
  for (const q of queues) q.close(7000);
  const { timeline, ...observed } = queues[1].snapshot();
  assert.deepEqual(observed, queues[0].snapshot());
});

test('later forwarding bin preserves pre-dequeue occupancy and rejects impossible event chronology', async () => {
  const { qualifyDatagramTimeline } = await import('../datagram-timeline-qualification.mjs');
  const q = new DatagramImpairmentQueue({ ...config, recordTimeline: true });
  q.enqueue(Buffer.alloc(100), 0);
  q.takeReady(150);
  q.close(200);
  const s = q.snapshot();
  assert.equal(s.timeline.windows[1].peakQueuePackets, 1);
  assert.equal(s.timeline.windows[1].peakQueueBytes, 128);
  assert.equal(qualifyDatagramTimeline(s).complete, true);
  const changed = structuredClone(s);
  changed.timeline.windows[0].received = { packets: 0, wireBytes: 0 };
  changed.timeline.windows[0].forwarded = { packets: 1, wireBytes: 128 };
  changed.timeline.windows[1].received = { packets: 1, wireBytes: 128 };
  changed.timeline.windows[1].forwarded = { packets: 0, wireBytes: 0 };
  assert.throws(() => qualifyDatagramTimeline(changed), /chronology/);
});

test('omitted bytes cannot conceal missing evidence behind zero omitted events', async () => {
  const { qualifyDatagramTimeline } = await import('../datagram-timeline-qualification.mjs');
  const q = new DatagramImpairmentQueue({ ...config, recordTimeline: true });
  q.enqueue(Buffer.alloc(100), 0);
  q.takeReady(20);
  q.close(30);
  const s = q.snapshot();
  for (const k of ['received', 'forwarded']) {
    s.timeline.omitted[k].wireBytes = 100;
    s[k].wireBytes += 100;
  }
  assert.throws(() => qualifyDatagramTimeline(s));
});
