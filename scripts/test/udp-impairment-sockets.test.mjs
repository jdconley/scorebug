import test from 'node:test';
import assert from 'node:assert/strict';
import { createSocket, Socket } from 'node:dgram';
import { setTimeout as delay } from 'node:timers/promises';
import { createUDPImpairmentProxy } from '../udp-impairment.mjs';
async function socket(t) {
  const s = createSocket('udp4');
  await new Promise((resolve) => s.bind(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => s.close(resolve)));
  return s;
}
async function until(check) {
  const end = performance.now() + 2000;
  while (!check() && performance.now() < end) await delay(5);
  assert.ok(check(), 'UDP condition timed out');
}
function conserved(s) {
  for (const key of ['packets', 'wireBytes'])
    assert.equal(
      s.received[key],
      s.queue[key] +
        ['forwarded', 'injectedDrop', 'overflowDrop', 'oversizeDrop', 'closeDiscard'].reduce(
          (n, k) => n + s[k][key],
          0,
        ),
    );
}
test('owned sockets preserve bidirectional payloads and reject a foreign frontend peer', async (t) => {
  const receiver = await socket(t),
    client = await socket(t),
    foreign = await socket(t);
  const messages = [],
    replies = [];
  receiver.on('message', (data, rinfo) => {
    messages.push(String(data));
    receiver.send(Buffer.from('reply:' + data), rinfo.port, rinfo.address);
  });
  client.on('message', (data) => replies.push(String(data)));
  const proxy = await createUDPImpairmentProxy({ receiverPort: receiver.address().port });
  t.after(() => proxy.close());
  client.send(Buffer.from('one'), proxy.port, '127.0.0.1');
  await until(() => replies.length === 1);
  assert.deepEqual(replies, ['reply:one']);
  foreign.send(Buffer.from('foreign'), proxy.port, '127.0.0.1');
  await until(() => proxy.snapshot().foreignPeerPackets === 1);
  assert.deepEqual(messages, ['one']);
  await proxy.close();
  await proxy.close();
  const s = proxy.snapshot();
  assert.equal(s.closed, true);
  assert.equal(s.forward.pendingPackets, 0);
  assert.equal(s.reverse.pendingPackets, 0);
  assert.ok(s.forward.peakPendingPackets > 0);
  assert.ok(s.reverse.peakPendingPackets > 0);
  assert.deepEqual(s.errors, []);
  conserved(s.forward.queue);
  conserved(s.reverse.queue);
});
test('forward and reverse loss/delay are independently applied', async (t) => {
  const receiver = await socket(t),
    client = await socket(t),
    messages = [],
    replies = [];
  receiver.on('message', (data, rinfo) => {
    messages.push(String(data));
    receiver.send(data, rinfo.port, rinfo.address);
  });
  client.on('message', (data) => replies.push(String(data)));
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forward: { delayMilliseconds: 30, dropEvery: 2 },
    reverse: { delayMilliseconds: 30, dropEvery: 2 },
  });
  t.after(() => proxy.close());
  const start = performance.now();
  for (let i = 1; i <= 4; i++) client.send(Buffer.from(String(i)), proxy.port, '127.0.0.1');
  await until(() => replies.length === 1);
  assert.ok(performance.now() - start >= 60);
  await until(() => proxy.snapshot().reverse.queue.injectedDrop.packets === 1);
  assert.deepEqual(messages, ['1', '3']);
  assert.deepEqual(replies, ['1']);
  await proxy.close();
  const s = proxy.snapshot();
  assert.equal(s.forward.queue.injectedDrop.packets, 2);
  conserved(s.forward.queue);
  conserved(s.reverse.queue);
});
test('socket flood stays within queue/pending bounds and close counts discarded packets', async (t) => {
  const receiver = await socket(t),
    client = await socket(t);
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forward: { delayMilliseconds: 1000, maxQueuePackets: 2, maxQueueBytes: 4096 },
  });
  t.after(() => proxy.close());
  for (let i = 0; i < 20; i++) client.send(Buffer.alloc(1000), proxy.port, '127.0.0.1');
  await until(() => proxy.snapshot().forward.queue.received.packets === 20);
  assert.equal(proxy.snapshot().forward.queue.overflowDrop.packets, 18);
  await proxy.close();
  const s = proxy.snapshot();
  assert.equal(s.forward.queue.closeDiscard.packets, 2);
  assert.ok(s.forward.peakPendingPackets <= 16);
  conserved(s.forward.queue);
});
test('rejects invalid endpoint/configuration before opening sockets', async () => {
  for (const c of [
    { receiverPort: 0 },
    { receiverPort: 65536 },
    { receiverPort: 1, host: 'example.com' },
    { receiverPort: 1, forward: { rateBitsPerSecond: NaN } },
  ])
    await assert.rejects(createUDPImpairmentProxy(c));
});

test('connected UDP error closes both owned sockets and clears queued work', async (t) => {
  const unavailable = createSocket('udp4');
  await new Promise((resolve) => unavailable.bind(0, '127.0.0.1', resolve));
  const receiverPort = unavailable.address().port;
  await new Promise((resolve) => unavailable.close(resolve));
  const client = await socket(t);
  const proxy = await createUDPImpairmentProxy({ receiverPort });
  t.after(() => proxy.close());
  client.send(Buffer.from('trigger ICMP'), proxy.port, '127.0.0.1');
  await until(() => proxy.snapshot().closed);
  await proxy.close();
  const s = proxy.snapshot();
  assert.ok(s.errors.length > 0);
  assert.equal(s.forward.pendingPackets, 0);
  assert.equal(s.reverse.pendingPackets, 0);
  conserved(s.forward.queue);
  conserved(s.reverse.queue);
});

for (const direction of ['forward', 'reverse'])
  test(`joined close during a real pending ${direction} send`, async (t) => {
    const receiver = await socket(t),
      client = await socket(t);
    receiver.on('message', (data, rinfo) => receiver.send(data, rinfo.port, rinfo.address));
    const proxy = await createUDPImpairmentProxy({ receiverPort: receiver.address().port });
    t.after(() => proxy.close());
    const send = Socket.prototype.send;
    let closing, pendingAtClose;
    t.mock.method(Socket.prototype, 'send', function (...args) {
      const result = send.apply(this, args);
      const callback = args.at(-1);
      if (
        !closing &&
        typeof callback === 'function' &&
        args.length === (direction === 'forward' ? 2 : 4)
      ) {
        pendingAtClose = proxy.snapshot()[direction].pendingPackets;
        closing = proxy.close();
      }
      return result;
    });
    client.send(Buffer.from('close during send'), proxy.port, '127.0.0.1');
    await until(() => closing !== undefined);
    assert.ok(pendingAtClose > 0, 'Must actually close before the native send callback');
    await closing;
    const snapshot = proxy.snapshot();
    assert.equal(snapshot.closed, true);
    assert.equal(snapshot.forward.pendingPackets, 0);
    assert.equal(snapshot.reverse.pendingPackets, 0);
    conserved(snapshot.forward.queue);
    conserved(snapshot.reverse.queue);
  });

test('owned schedule starts on the publisher and repumps preserved FIFO on recovery', async (t) => {
  const receiver = await socket(t),
    client = await socket(t),
    messages = [];
  receiver.on('message', (data) => messages.push(data[0]));
  const schedule = [
    { atMilliseconds: 0, rateBitsPerSecond: null },
    { atMilliseconds: 30, rateBitsPerSecond: 1024 },
    { atMilliseconds: 500, rateBitsPerSecond: null },
  ];
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forward: { burstBytes: 256, maxDatagramBytes: 128 },
    forwardRateSchedule: schedule,
  });
  t.after(() => proxy.close());
  schedule[1].rateBitsPerSecond = 1e12; // Caller cannot mutate the owned schedule.
  assert.equal(proxy.snapshot().forwardRateSchedule.startedAt, null);
  await delay(40);
  assert.equal(proxy.snapshot().forwardRateSchedule.phases.length, 0);
  client.send(Buffer.from([0]), proxy.port, '127.0.0.1');
  await until(() => proxy.snapshot().forwardRateSchedule.phases.length === 2);
  for (let i = 1; i <= 5; i++) client.send(Buffer.alloc(100, i), proxy.port, '127.0.0.1');
  await until(() => proxy.snapshot().forward.queue.received.packets === 6);
  assert.ok(proxy.snapshot().forward.queue.queue.packets >= 3);
  await until(() => messages.length === 6);
  assert.deepEqual(messages, [0, 1, 2, 3, 4, 5]);
  await proxy.close();
  const s = proxy.snapshot(),
    phases = s.forwardRateSchedule.phases;
  assert.equal(s.closed, true);
  assert.equal(phases.length, 3);
  assert.equal(phases[0].forward.queue.received.packets, 0);
  assert.equal(phases[1].rateBitsPerSecond, 1024);
  assert.ok(phases[1].appliedAt >= s.forwardRateSchedule.startedAt + 30);
  assert.ok(phases[2].appliedAt >= s.forwardRateSchedule.startedAt + 500);
  assert.equal(phases[2].forward.queue.configuration.rateBitsPerSecond, null);
  assert.ok(phases[2].forward.queue.queue.packets > 0, 'Boundary snapshot precedes recovery drain');
  assert.ok(
    phases[2].forward.queue.forwarded.wireBytes - phases[1].forward.queue.forwarded.wireBytes <=
      256 + ((phases[2].appliedAt - phases[1].appliedAt) * 1024) / 8000 + 1,
  );
  conserved(s.forward.queue);
  assert.equal(s.forward.queue.closeDiscard.packets, 0);
  assert.equal(s.forward.pendingPackets, 0);
});
test('no-peer and interrupted schedules close without future phase mutations', async (t) => {
  const receiver = await socket(t),
    client = await socket(t);
  const configuration = {
    receiverPort: receiver.address().port,
    forwardRateSchedule: [
      { atMilliseconds: 0, rateBitsPerSecond: null },
      { atMilliseconds: 60, rateBitsPerSecond: 1024 },
    ],
  };
  const idle = await createUDPImpairmentProxy(configuration);
  await idle.close();
  assert.equal(idle.snapshot().forwardRateSchedule.startedAt, null);
  assert.deepEqual(idle.snapshot().forwardRateSchedule.phases, []);
  const active = await createUDPImpairmentProxy(configuration);
  t.after(() => active.close());
  client.send(Buffer.from('start'), active.port, '127.0.0.1');
  await until(() => active.snapshot().forwardRateSchedule.phases.length === 1);
  await active.close();
  const snapshot = active.snapshot();
  await delay(80);
  assert.deepEqual(active.snapshot(), snapshot);
});
test('schedule validation rejects timer overflow and malformed phases before allocating sockets', async () => {
  const start = { atMilliseconds: 0, rateBitsPerSecond: null };
  for (const forwardRateSchedule of [
    [],
    [start],
    [start, { atMilliseconds: 1, rateBitsPerSecond: 0 }],
    [start, { atMilliseconds: 600001, rateBitsPerSecond: 1 }],
    [start, { atMilliseconds: Infinity, rateBitsPerSecond: 1 }],
    [start, { atMilliseconds: 1.5, rateBitsPerSecond: 1 }],
    [start, { atMilliseconds: 0, rateBitsPerSecond: 1 }],
    [start, { atMilliseconds: 1, rateBitsPerSecond: 1, extra: true }],
    [
      { atMilliseconds: 1, rateBitsPerSecond: null },
      { atMilliseconds: 2, rateBitsPerSecond: 1 },
    ],
    [
      { atMilliseconds: 0, rateBitsPerSecond: 1 },
      { atMilliseconds: 2, rateBitsPerSecond: null },
    ],
    Array.from({ length: 9 }, (_, atMilliseconds) => ({ atMilliseconds, rateBitsPerSecond: null })),
  ])
    await assert.rejects(createUDPImpairmentProxy({ receiverPort: 9, forwardRateSchedule }));
});
