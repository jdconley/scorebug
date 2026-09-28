import test from 'node:test';
import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { setTimeout as delay } from 'node:timers/promises';
import { createUDPOutageProxy } from '../udp-outage.mjs';

async function socket(t) {
  const value = createSocket('udp4');
  await new Promise((resolve) => value.bind(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => value.close(resolve)));
  return value;
}
async function until(check) {
  const end = performance.now() + 2000;
  while (!check() && performance.now() < end) await delay(5);
  assert.ok(check(), 'UDP condition timed out');
}

test('blackhole drops both directions and reconnect ports retain isolated reply routes', async (t) => {
  const receiver = await socket(t),
    first = await socket(t),
    next = await socket(t);
  const received = [],
    firstReplies = [],
    nextReplies = [];
  receiver.on('message', (data, peer) => received.push({ text: String(data), peer }));
  first.on('message', (data) => firstReplies.push(String(data)));
  next.on('message', (data) => nextReplies.push(String(data)));
  const proxy = await createUDPOutageProxy({ receiverPort: receiver.address().port });
  t.after(() => proxy.close());
  first.send(Buffer.from('before'), proxy.port, '127.0.0.1');
  await until(() => received.length === 1);
  const old = received[0].peer;
  await proxy.setBlocked(true);
  first.send(Buffer.from('lost'), proxy.port, '127.0.0.1');
  next.send(Buffer.from('lost retry'), proxy.port, '127.0.0.1');
  receiver.send(Buffer.from('lost reply'), old.port, old.address);
  await until(
    () => proxy.snapshot().forward.dropped === 2 && proxy.snapshot().reverse.dropped === 1,
  );
  assert.equal(received.length, 1);
  assert.deepEqual(firstReplies, []);
  await proxy.setBlocked(false);
  next.send(Buffer.from('reconnected'), proxy.port, '127.0.0.1');
  await until(() => received.length === 2);
  const replacement = received[1].peer;
  assert.notEqual(old.port, replacement.port);
  receiver.send(Buffer.from('late old reply'), old.port, old.address);
  receiver.send(Buffer.from('new reply'), replacement.port, replacement.address);
  await until(() => firstReplies.length === 1 && nextReplies.length === 1);
  assert.deepEqual(firstReplies, ['late old reply']);
  assert.deepEqual(nextReplies, ['new reply']);
  await proxy.close();
  await proxy.close();
  const result = proxy.snapshot();
  assert.equal(result.closed, true);
  assert.equal(result.pending, 0);
  assert.equal(result.routes, 2);
  assert.deepEqual(result.errors, []);
  for (const direction of ['forward', 'reverse'])
    assert.equal(result[direction].received, result[direction].sent + result[direction].dropped);
  assert.throws(() => proxy.setBlocked(true), /closed/);
});

test('outage proxy validates endpoints before allocating sockets', async () => {
  for (const config of [
    { receiverPort: 0 },
    { receiverPort: 65536 },
    { receiverPort: 9, receiverHost: '8.8.8.8' },
    { receiverPort: 9, extra: true },
  ])
    await assert.rejects(createUDPOutageProxy(config));
});

test('route limit fails closed and joins owned socket sends', async (t) => {
  const receiver = await socket(t),
    clients = [];
  for (let i = 0; i < 17; i++) clients.push(await socket(t));
  const proxy = await createUDPOutageProxy({ receiverPort: receiver.address().port });
  t.after(() => proxy.close());
  for (let i = 0; i < clients.length; i++) {
    clients[i].send(Buffer.from('route'), proxy.port, '127.0.0.1');
    await until(() => proxy.snapshot().routes === Math.min(i + 1, 16));
  }
  await until(() => proxy.snapshot().closed);
  const result = proxy.snapshot();
  assert.equal(result.pending, 0);
  assert.equal(result.routes, 16);
  assert.deepEqual(result.errors, ['Outage fixture route bound exceeded']);
  assert.equal(result.forward.received, result.forward.sent + result.forward.dropped);
});
