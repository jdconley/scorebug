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
