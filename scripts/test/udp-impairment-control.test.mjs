import test from 'node:test';
import assert from 'node:assert/strict';
import { createSocket, Socket } from 'node:dgram';
import { setTimeout as delay } from 'node:timers/promises';
import { createUDPImpairmentProxy } from '../udp-impairment.mjs';
import { qualifyRateLedger } from '../rate-ledger-qualification.mjs';

async function socket(t) {
  const value = createSocket('udp4');
  await new Promise((resolve) => value.bind(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => value.close(resolve)));
  return value;
}
async function until(check) {
  const deadline = performance.now() + 2000;
  while (!check() && performance.now() < deadline) await delay(2);
  assert.ok(check(), 'UDP condition timed out');
}
function send(client, proxy, data) {
  return new Promise((resolve, reject) =>
    client.send(data, proxy.port, '127.0.0.1', (error) => (error ? reject(error) : resolve())),
  );
}
function conserved(queue) {
  for (const unit of ['packets', 'wireBytes'])
    assert.equal(
      queue.received[unit],
      queue.queue[unit] +
        ['forwarded', 'injectedDrop', 'overflowDrop', 'oversizeDrop', 'closeDiscard'].reduce(
          (sum, name) => sum + queue[name][unit],
          0,
        ),
    );
}
function rejectedWithoutMutation(proxy, operation) {
  const before = proxy.snapshot(),
    ledger = proxy.rateLedgerSnapshot();
  assert.throws(operation, /control|phase|closed|peer/i);
  assert.deepEqual(proxy.snapshot(), before);
  assert.deepEqual(proxy.rateLedgerSnapshot(), ledger);
}

test('receiver selection uses the actual connected target and retains one loopback publisher', async (t) => {
  const receiver = await socket(t),
    client = await socket(t),
    foreign = await socket(t),
    replies = [];
  const connect = Socket.prototype.connect,
    bind = Socket.prototype.bind,
    destinations = [],
    bindings = [];
  t.mock.method(Socket.prototype, 'connect', function (...args) {
    destinations.push(args.slice(0, 2));
    return connect.apply(this, args);
  });
  t.mock.method(Socket.prototype, 'bind', function (...args) {
    bindings.push(args.slice(0, 2));
    return bind.apply(this, args);
  });
  receiver.on('message', (data, rinfo) => receiver.send(data, rinfo.port, rinfo.address));
  client.on('message', (data) => replies.push(data));
  const proxy = await createUDPImpairmentProxy({
    receiverHost: '127.0.0.1',
    receiverPort: receiver.address().port,
  });
  t.after(() => proxy.close());
  assert.deepEqual(destinations, [[receiver.address().port, '127.0.0.1']]);
  assert.ok(bindings.some(([port, host]) => port === 0 && host === '127.0.0.1'));
  const payload = Buffer.from([0, 255, 128, 1]);
  await send(client, proxy, payload);
  await until(() => replies.length === 1);
  assert.deepEqual(replies, [payload]);
  await send(foreign, proxy, Buffer.from('foreign'));
  await until(() => proxy.snapshot().foreignPeerPackets === 1);
  assert.equal(proxy.snapshot().forward.queue.received.packets, 1);
  assert.equal('forwardRateControl' in proxy.snapshot(), false);
  assert.equal('constrainForward' in proxy, false);
  assert.equal('restoreForward' in proxy, false);
});

test('receiver validation rejects unsafe or ambiguous addresses before binding or connecting', async (t) => {
  let socketOperations = 0;
  t.mock.method(Socket.prototype, 'bind', () => socketOperations++);
  t.mock.method(Socket.prototype, 'connect', () => socketOperations++);
  for (const receiverHost of [
    null,
    1,
    '',
    'localhost',
    'http://127.0.0.1',
    '127.0.0.1:9000',
    '127.1',
    '127.00.0.1',
    ' 127.0.0.1',
    '127.0.0.1 ',
    '::1',
    '::ffff:127.0.0.1',
    '0.0.0.0',
    '8.8.8.8',
    '100.64.0.1',
    '169.254.0.1',
    '172.15.0.1',
    '172.32.0.1',
    '192.169.0.1',
    '224.0.0.1',
    '255.255.255.255',
    '192.168.1.256',
  ])
    await assert.rejects(
      createUDPImpairmentProxy({ receiverPort: 9, receiverHost }),
      /receiver host/i,
    );
  assert.equal(socketOperations, 0);
});

test('loopback and RFC1918 addresses reach connect validation without sending LAN traffic', async (t) => {
  const attempted = [];
  t.mock.method(Socket.prototype, 'connect', function (port, host) {
    attempted.push([port, host]);
    throw new Error('intercepted before network connection');
  });
  for (const receiverHost of [
    '127.0.0.2',
    '127.1.2.3',
    '10.1.2.3',
    '172.16.0.1',
    '172.31.254.254',
    '192.168.1.1',
    '192.168.1.255',
    '10.255.255.255',
    '127.255.255.255',
  ]) {
    await assert.rejects(
      createUDPImpairmentProxy({ receiverPort: 12345, receiverHost }),
      /intercepted before network connection/,
    );
    assert.deepEqual(attempted.at(-1), [12345, receiverHost]);
  }
});

test('control selection validates exact finite configuration before opening sockets', async (t) => {
  let socketOperations = 0;
  t.mock.method(Socket.prototype, 'bind', () => socketOperations++);
  t.mock.method(Socket.prototype, 'connect', () => socketOperations++);
  for (const forwardRateControl of [
    undefined,
    null,
    [],
    1,
    {},
    { rateBitsPerSecond: null },
    { rateBitsPerSecond: NaN },
    { rateBitsPerSecond: Infinity },
    { rateBitsPerSecond: 0 },
    { rateBitsPerSecond: -1 },
    { rateBitsPerSecond: 1e12 + 1 },
    { rateBitsPerSecond: '1024' },
    { rateBitsPerSecond: 1024, extra: true },
    { rateBitsPerSecond: 1024, [Symbol('extra')]: 1 },
  ])
    await assert.rejects(
      createUDPImpairmentProxy({ receiverPort: 9, forwardRateControl }),
      /control|rate/i,
    );
  for (const extra of [
    { forward: { rateBitsPerSecond: 1024 } },
    { forwardRateSchedule: null },
    {
      forwardRateSchedule: [
        { atMilliseconds: 0, rateBitsPerSecond: null },
        { atMilliseconds: 1, rateBitsPerSecond: 1024 },
      ],
    },
  ])
    await assert.rejects(
      createUDPImpairmentProxy({
        receiverPort: 9,
        forwardRateControl: { rateBitsPerSecond: 1024 },
        ...extra,
      }),
      /control|schedule|initial/i,
    );
  assert.equal(socketOperations, 0);
});

test('event controls retain exact boundary evidence, reject invalid calls and restore the denied FIFO', async (t) => {
  const receiver = await socket(t),
    client = await socket(t),
    messages = [],
    replies = [];
  receiver.on('message', (data, rinfo) => {
    messages.push(data[0]);
    receiver.send(data, rinfo.port, rinfo.address);
  });
  client.on('message', (data) => replies.push(data[0]));
  const forwardRateControl = { rateBitsPerSecond: 1 };
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forwardRateControl,
    forward: {
      recordTimeline: true,
      recordRateLedger: true,
      maxDatagramBytes: 100,
      burstBytes: 128,
      maxQueuePackets: 8,
      maxQueueBytes: 1024,
    },
    reverse: { delayMilliseconds: 1 },
  });
  t.after(() => proxy.close());
  forwardRateControl.rateBitsPerSecond = 1e12;
  assert.deepEqual(proxy.snapshot().forwardRateControl, {
    requested: { mode: 'single-constraint', rateBitsPerSecond: 1 },
    startedAt: null,
    stoppedAt: null,
    phases: [],
  });
  rejectedWithoutMutation(proxy, () => proxy.constrainForward());
  rejectedWithoutMutation(proxy, () => proxy.restoreForward());
  await delay(10);
  assert.equal(proxy.snapshot().forwardRateControl.startedAt, null);
  await send(client, proxy, Buffer.from([0]));
  await until(() => replies.length === 1);
  const baseline = proxy.snapshot().forwardRateControl.phases[0];
  assert.equal(baseline.phase, 'baseline');
  assert.equal(baseline.rateBitsPerSecond, null);
  assert.equal(baseline.forward.queue.received.packets, 0);
  assert.equal(baseline.forward.queue.timeline.lastObservedAt, baseline.appliedAt);
  assert.equal(proxy.snapshot().forwardRateControl.startedAt, baseline.appliedAt);
  rejectedWithoutMutation(proxy, () => proxy.restoreForward());
  const limited = proxy.constrainForward(),
    originalLimited = structuredClone(limited);
  assert.equal(limited.phase, 'constrained');
  assert.equal(limited.rateBitsPerSecond, 1);
  assert.equal(limited.forward.queue.timeline.lastObservedAt, limited.appliedAt);
  assert.equal(limited.reverse.queue.configuration.delayMilliseconds, 1);
  rejectedWithoutMutation(proxy, () => proxy.constrainForward());
  limited.forward.queue.configuration.rateBitsPerSecond = 100;
  limited.forward.queue.timeline.windows.length = 0;
  assert.deepEqual(proxy.snapshot().forwardRateControl.phases[1], originalLimited);
  for (let i = 1; i <= 6; i++) await send(client, proxy, Buffer.alloc(100, i));
  await until(() => proxy.snapshot().forward.queue.received.packets === 7);
  const queued = proxy.snapshot().forward.queue;
  assert.ok(queued.rateLedgerFirstDenial, 'Requires actual ready-head token denial');
  assert.equal(queued.queue.packets, 5);
  const restored = proxy.restoreForward(),
    originalRestored = structuredClone(restored);
  assert.equal(restored.phase, 'restored');
  assert.equal(restored.rateBitsPerSecond, null);
  assert.equal(
    restored.forward.queue.queue.packets,
    5,
    'Boundary must precede the restoration pump',
  );
  assert.equal(restored.forward.queue.timeline.lastObservedAt, restored.appliedAt);
  assert.ok(
    proxy.snapshot().forward.queue.forwarded.packets > restored.forward.queue.forwarded.packets,
    'Restore pumps synchronously',
  );
  const phases = proxy.snapshot().forwardRateControl.phases;
  phases[0].forward.queue.received.packets = 999;
  phases.length = 0;
  restored.forward.queue.timeline.windows.length = 0;
  assert.equal(proxy.snapshot().forwardRateControl.phases.length, 3);
  assert.deepEqual(proxy.snapshot().forwardRateControl.phases[2], originalRestored);
  rejectedWithoutMutation(proxy, () => proxy.constrainForward());
  rejectedWithoutMutation(proxy, () => proxy.restoreForward());
  await until(() => replies.length === 7);
  assert.deepEqual(messages, [0, 1, 2, 3, 4, 5, 6]);
  assert.deepEqual(replies, messages);
  const closing = proxy.close();
  assert.equal(proxy.close(), closing);
  rejectedWithoutMutation(proxy, () => proxy.constrainForward());
  rejectedWithoutMutation(proxy, () => proxy.restoreForward());
  await closing;
  const snapshot = proxy.snapshot(),
    ledger = proxy.rateLedgerSnapshot();
  assert.equal(snapshot.closed, true);
  assert.deepEqual(snapshot.errors, []);
  assert.ok(snapshot.forwardRateControl.stoppedAt >= originalRestored.appliedAt);
  for (const direction of [snapshot.forward, snapshot.reverse]) {
    assert.equal(direction.pendingPackets, 0);
    assert.ok(direction.peakPendingPackets <= 16);
    assert.ok(direction.queue.queue.peakPackets <= direction.queue.configuration.maxQueuePackets);
    assert.ok(direction.queue.queue.peakWireBytes <= direction.queue.configuration.maxQueueBytes);
    conserved(direction.queue);
  }
  assert.equal(ledger.header.limit.at, originalLimited.appliedAt);
  assert.equal(
    ledger.header.limit.ordinal,
    originalLimited.forward.queue.rateLedgerOperationOrdinal,
  );
  assert.equal(ledger.footer.restoration.at, originalRestored.appliedAt);
  assert.equal(
    ledger.footer.restoration.ordinal,
    originalRestored.forward.queue.rateLedgerOperationOrdinal,
  );
  assert.equal(
    qualifyRateLedger(
      {
        ledger,
        limited: { appliedAt: originalLimited.appliedAt, queue: originalLimited.forward.queue },
        restored: { appliedAt: originalRestored.appliedAt, queue: originalRestored.forward.queue },
      },
      { configuration: originalLimited.forward.queue.configuration },
    ).rateBoundQualified,
    true,
  );
  for (const phase of snapshot.forwardRateControl.phases) {
    assert.equal('rateLedger' in phase.forward.queue, false);
    assert.ok(phase.forward.queue.timeline.windows.length <= 8192);
  }
  rejectedWithoutMutation(proxy, () => proxy.constrainForward());
  rejectedWithoutMutation(proxy, () => proxy.restoreForward());
});

for (const state of ['idle', 'baseline', 'constrained'])
  test(`close in ${state} retains incomplete control evidence and joined cleanup`, async (t) => {
    const receiver = await socket(t),
      client = await socket(t);
    const proxy = await createUDPImpairmentProxy({
      receiverPort: receiver.address().port,
      forwardRateControl: { rateBitsPerSecond: 1024 },
      forward: {
        recordTimeline: true,
        recordRateLedger: true,
        delayMilliseconds: 1000,
        maxQueuePackets: 2,
        maxQueueBytes: 4096,
      },
    });
    t.after(() => proxy.close());
    if (state !== 'idle') {
      await send(client, proxy, Buffer.from('start'));
      await until(() => proxy.snapshot().forwardRateControl.phases.length === 1);
      if (state === 'constrained') proxy.constrainForward();
      for (let i = 0; i < 10; i++) await send(client, proxy, Buffer.alloc(1000));
      await until(() => proxy.snapshot().forward.queue.received.packets === 11);
      assert.equal(proxy.snapshot().forward.queue.overflowDrop.packets, 9);
    }
    const closing = proxy.close();
    assert.equal(proxy.close(), closing);
    await closing;
    const snapshot = proxy.snapshot(),
      control = snapshot.forwardRateControl;
    assert.equal(control.phases.length, state === 'idle' ? 0 : state === 'baseline' ? 1 : 2);
    assert.equal(control.startedAt === null, state === 'idle');
    assert.ok(Number.isFinite(control.stoppedAt));
    assert.ok(control.phases.every((phase) => phase.phase !== 'restored'));
    assert.equal(snapshot.forward.queue.closeDiscard.packets, state === 'idle' ? 0 : 2);
    assert.equal(snapshot.forward.pendingPackets, 0);
    conserved(snapshot.forward.queue);
    if (state === 'constrained') {
      assert.equal(proxy.rateLedgerSnapshot().footer.restoration, null);
      assert.ok(proxy.rateLedgerSnapshot().invalidReasons.includes('closed-before-restoration'));
    }
    rejectedWithoutMutation(proxy, () => proxy.constrainForward());
    rejectedWithoutMutation(proxy, () => proxy.restoreForward());
    await delay(20);
    assert.deepEqual(proxy.snapshot(), snapshot);
  });

test('restoration preserves delayed FIFO deadlines', async (t) => {
  const receiver = await socket(t),
    client = await socket(t),
    messages = [];
  receiver.on('message', (data) => messages.push({ value: data[0], at: performance.now() }));
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forwardRateControl: { rateBitsPerSecond: 1e12 },
    forward: { recordRateLedger: true, delayMilliseconds: 100 },
  });
  t.after(() => proxy.close());
  await send(client, proxy, Buffer.from([0]));
  await until(() => proxy.snapshot().forward.queue.received.packets === 1);
  proxy.constrainForward();
  await send(client, proxy, Buffer.from([1]));
  await until(() => proxy.snapshot().forward.queue.received.packets === 2);
  const restored = proxy.restoreForward(),
    fifo = proxy.rateLedgerSnapshot().footer.finalFIFO;
  assert.ok(fifo.length > 0);
  assert.equal(restored.forward.queue.queue.packets, fifo.length);
  await until(() => messages.length === 2);
  assert.deepEqual(
    messages.map(({ value }) => value),
    [0, 1],
  );
  for (const [ordinal, , enqueuedAt, readyAt] of fifo) {
    assert.equal(readyAt, enqueuedAt + 100);
    assert.ok(messages[ordinal - 1].at >= readyAt, 'Restoration must retain original readiness');
  }
});

for (const direction of ['forward', 'reverse'])
  test(`event mode joins close during a real pending ${direction} send`, async (t) => {
    const receiver = await socket(t),
      client = await socket(t);
    receiver.on('message', (data, rinfo) => receiver.send(data, rinfo.port, rinfo.address));
    const proxy = await createUDPImpairmentProxy({
      receiverPort: receiver.address().port,
      forwardRateControl: { rateBitsPerSecond: 1024 },
    });
    t.after(() => proxy.close());
    const originalSend = Socket.prototype.send;
    let closing, pendingAtClose;
    t.mock.method(Socket.prototype, 'send', function (...args) {
      const result = originalSend.apply(this, args);
      if (
        !closing &&
        typeof args.at(-1) === 'function' &&
        args.length === (direction === 'forward' ? 2 : 4)
      ) {
        pendingAtClose = proxy.snapshot()[direction].pendingPackets;
        closing = proxy.close();
      }
      return result;
    });
    // No callback here: the interception must capture a proxy-owned send.
    client.send(Buffer.from('pending'), proxy.port, '127.0.0.1');
    await until(() => closing !== undefined);
    assert.ok(pendingAtClose > 0);
    assert.equal(proxy.close(), closing);
    await closing;
    const snapshot = proxy.snapshot();
    assert.equal(snapshot.closed, true);
    assert.equal(snapshot.forwardRateControl.phases.length, 1);
    for (const value of [snapshot.forward, snapshot.reverse]) {
      assert.equal(value.pendingPackets, 0);
      conserved(value.queue);
    }
  });

test('control captures and validates one rate value from caller configuration', async (t) => {
  const receiver = await socket(t);
  let reads = 0;
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forwardRateControl: {
      get rateBitsPerSecond() {
        reads++;
        return reads === 1 ? 1024 : Infinity;
      },
    },
  });
  t.after(() => proxy.close());
  assert.equal(reads, 1);
  assert.equal(proxy.snapshot().forwardRateControl.requested.rateBitsPerSecond, 1024);
});

test('frontend rejects unsafe binds before allocation and leaves receiver validation unchanged', async (t) => {
  const bindings = [];
  t.mock.method(Socket.prototype, 'bind', (...args) => {
    bindings.push(args);
    throw new Error('Allocated socket');
  });
  for (const bindHost of ['0.0.0.0', '8.8.8.8', 'localhost', '192.168.001.2'])
    await assert.rejects(createUDPImpairmentProxy({ receiverPort: 9999, bindHost }), /bind/);
  assert.deepEqual(bindings, []);
});
