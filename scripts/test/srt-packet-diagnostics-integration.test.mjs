import assert from 'node:assert/strict';
import test from 'node:test';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatagramImpairmentQueue, createUDPImpairmentProxy } from '../udp-impairment.mjs';
import { createUplinkEvidenceStopper } from '../uplink-proxy-evidence.mjs';
const packet = (seq) => {
  const b = Buffer.alloc(16);
  b.writeUInt32BE(seq, 0);
  b.writeUInt32BE(0xc0000001, 4);
  return b;
};
async function until(check) {
  const end = performance.now() + 2000;
  while (!check()) {
    assert(performance.now() < end);
    await delay(2);
  }
}
async function directory(t) {
  const p = await mkdtemp(join(tmpdir(), 'srt-packet-export-'));
  t.after(() => rm(p, { recursive: true, force: true }));
  return p;
}

test('queue diagnostic events bind received ordinals without changing queue decisions', () => {
  const events = [];
  const options = { dropEvery: 3, maxQueuePackets: 1, maxQueueBytes: 4096 };
  const plain = new DatagramImpairmentQueue(options),
    observed = new DatagramImpairmentQueue(options, (e) =>
      events.push({ ...e, data: Buffer.from(e.data) }),
    );
  for (const q of [plain, observed]) {
    q.enqueue(packet(10), 0);
    q.enqueue(packet(11), 1);
    q.enqueue(packet(12), 2);
    assert.deepEqual(q.takeReady(3), packet(10));
    q.enqueue(packet(13), 4);
    q.close(5);
  }
  assert.deepEqual(observed.snapshot(), plain.snapshot());
  assert.deepEqual(
    events.map(({ ordinal, at, disposition }) => [ordinal, at, disposition]),
    [
      [1, 0, 'queued'],
      [2, 1, 'overflowDrop'],
      [3, 2, 'injectedDrop'],
      [1, 3, 'forwarded'],
      [4, 4, 'queued'],
      [4, 5, 'closeDiscard'],
    ],
  );
  assert.deepEqual(
    events.map((e) => e.data.readUInt32BE(0)),
    [10, 11, 12, 10, 13, 13],
  );
});
test('diagnostic callback failure never changes transport forwarding or legacy snapshots', () => {
  const q = new DatagramImpairmentQueue({}, () => {
    throw Error('observer');
  });
  q.enqueue(packet(1), 0);
  assert.deepEqual(q.takeReady(0), packet(1));
  q.close(1);
  assert.equal(q.packetDiagnosticErrors, 2);
  assert.equal(q.snapshot().forwarded.packets, 1);
  assert(!('packetDiagnosticErrors' in q.snapshot()));
});
for (const config of [
  { recordPacketDiagnostics: 1 },
  { packetDiagnosticsWindow: { startAfterMilliseconds: 0, endAfterMilliseconds: 10 } },
  { recordPacketDiagnostics: true },
  {
    recordPacketDiagnostics: true,
    packetDiagnosticsWindow: { startAfterMilliseconds: 10, endAfterMilliseconds: 10 },
  },
  {
    recordPacketDiagnostics: true,
    packetDiagnosticsWindow: { startAfterMilliseconds: -1, endAfterMilliseconds: 10 },
  },
  {
    recordPacketDiagnostics: true,
    packetDiagnosticsWindow: { startAfterMilliseconds: 0, endAfterMilliseconds: 600001 },
  },
])
  test('reject invalid packet diagnostic route ' + JSON.stringify(config), async () => {
    await assert.rejects(createUDPImpairmentProxy({ receiverPort: 9, ...config }));
  });

test('loopback diagnostic export is opt-in, windowed, immutable and joined', async (t) => {
  const receiver = createSocket('udp4'),
    sender = createSocket('udp4');
  receiver.bind(0, '127.0.0.1');
  await once(receiver, 'listening');
  t.after(() => {
    receiver.close();
    sender.close();
  });
  const replies = [];
  receiver.on('message', (data, r) => receiver.send(data, r.port, r.address));
  sender.on('message', (d) => replies.push(d));
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    recordPacketDiagnostics: true,
    packetDiagnosticsWindow: { startAfterMilliseconds: 0, endAfterMilliseconds: 10000 },
  });
  t.after(() => proxy.close());
  sender.send(packet(123), proxy.port, '127.0.0.1');
  await until(() => replies.length === 1);
  const artifact = await directory(t),
    stop = createUplinkEvidenceStopper({ uplink: proxy, artifact });
  const first = stop();
  assert.equal(stop(), first);
  await first;
  const path = join(artifact, 'uplink-packet-diagnostics.json'),
    raw = await readFile(path, 'utf8'),
    saved = JSON.parse(raw);
  assert.equal(saved.diagnosticOnly, true);
  assert.equal(saved.closed, true);
  assert.equal(saved.events.length, 4);
  assert.deepEqual(
    saved.events.map((e) => [e.direction, e.ordinal, e.disposition]),
    [
      ['forward', 1, 'queued'],
      ['forward', 1, 'forwarded'],
      ['reverse', 1, 'queued'],
      ['reverse', 1, 'forwarded'],
    ],
  );
  assert.equal(saved.captureWindow.startAfterMilliseconds, 0);
  assert(saved.captureWindow.originAt > 0);
  assert.deepEqual(saved.observerErrors, { forward: 0, reverse: 0 });
  const snap = proxy.packetDiagnosticsSnapshot();
  snap.events.length = 0;
  assert.equal(proxy.packetDiagnosticsSnapshot().events.length, 4);
  await stop();
  assert.equal(await readFile(path, 'utf8'), raw);
  assert.deepEqual(replies, [packet(123)]);
});
test('before-window traffic is excluded explicitly and ordinary proxy snapshots stay unchanged', async (t) => {
  const receiver = createSocket('udp4'),
    sender = createSocket('udp4');
  receiver.bind(0, '127.0.0.1');
  await once(receiver, 'listening');
  t.after(() => {
    receiver.close();
    sender.close();
  });
  let received = false;
  receiver.on('message', () => (received = true));
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    recordPacketDiagnostics: true,
    packetDiagnosticsWindow: { startAfterMilliseconds: 100000, endAfterMilliseconds: 110000 },
  });
  t.after(() => proxy.close());
  sender.send(packet(1), proxy.port, '127.0.0.1');
  await until(() => received);
  await proxy.close();
  const s = proxy.packetDiagnosticsSnapshot();
  assert.equal(s.events.length, 0);
  assert.equal(s.captureWindow.excludedBefore, 2);
  assert.equal(s.captureWindow.excludedAfter, 0);
  assert(!('packetDiagnostics' in proxy.snapshot()));
});
test('default proxy has no diagnostics artifact', async (t) => {
  const proxy = await createUDPImpairmentProxy({ receiverPort: 9 });
  t.after(() => proxy.close());
  assert.equal(proxy.packetDiagnosticsSnapshot(), null);
  const artifact = await directory(t);
  await createUplinkEvidenceStopper({ uplink: proxy, artifact })();
  assert.deepEqual(await readdir(artifact), ['uplink-proxy.json']);
});
test('diagnostic export preserves existing files and joins other evidence on failure', async (t) => {
  const artifact = await directory(t),
    path = join(artifact, 'uplink-packet-diagnostics.json');
  await writeFile(path, 'original');
  let closed = false;
  const proxy = {
    close: async () => {
      closed = true;
    },
    snapshot: () => ({ closed }),
    packetDiagnosticsSnapshot: () => {
      assert(closed);
      return { diagnosticOnly: true, closed, events: [] };
    },
  };
  const stop = createUplinkEvidenceStopper({ uplink: proxy, artifact });
  const first = stop();
  await assert.rejects(first, /export/i);
  assert.equal(stop(), first);
  assert.equal(await readFile(path, 'utf8'), 'original');
  assert.equal(JSON.parse(await readFile(join(artifact, 'uplink-proxy.json'))).closed, true);
});

for (const extra of [
  { origin: 'unknown' },
  { origin: null },
  { origin: 'constrain' },
  { origin: 'firstPeerPacket', extra: true },
]) {
  test('reject invalid diagnostic origin ' + JSON.stringify(extra), async () => {
    await assert.rejects(
      createUDPImpairmentProxy({
        receiverPort: 9,
        recordPacketDiagnostics: true,
        packetDiagnosticsWindow: { startAfterMilliseconds: 0, endAfterMilliseconds: 25, ...extra },
      }),
    );
  });
}

test('constrain-anchored capture excludes baseline, binds the receipt and survives restore', async (t) => {
  const receiver = createSocket('udp4'),
    sender = createSocket('udp4');
  receiver.bind(0, '127.0.0.1');
  await once(receiver, 'listening');
  t.after(() => {
    receiver.close();
    sender.close();
  });
  const received = [];
  receiver.on('message', (d) => received.push(d));
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forwardRateControl: { rateBitsPerSecond: 750000 },
    recordPacketDiagnostics: true,
    packetDiagnosticsWindow: {
      origin: 'constrain',
      startAfterMilliseconds: 0,
      endAfterMilliseconds: 150,
    },
  });
  t.after(() => proxy.close());
  async function send(data) {
    const count = received.length;
    sender.send(data, proxy.port, '127.0.0.1');
    await until(() => received.length === count + 1);
  }
  await send(packet(1));
  assert.equal(proxy.packetDiagnosticsSnapshot().captureWindow.originAt, null);
  assert.equal(proxy.packetDiagnosticsSnapshot().events.length, 0);
  const receipt = proxy.constrainForward();
  const retransmission = packet(2);
  retransmission.writeUInt32BE(0xc4000001, 4);
  await send(retransmission);
  proxy.restoreForward();
  await send(packet(3));
  const first = proxy.packetDiagnosticsSnapshot();
  assert.equal(first.captureWindow.originAt, receipt.appliedAt);
  assert.equal(first.captureWindow.excludedBefore, 2);
  assert.deepEqual(
    first.events.map((e) => [e.packet.sequence, e.packet.retransmitted, e.disposition]),
    [
      [2, true, 'queued'],
      [2, true, 'forwarded'],
      [3, false, 'queued'],
      [3, false, 'forwarded'],
    ],
  );
  await delay(Math.max(0, receipt.appliedAt + 170 - performance.now()));
  await send(packet(4));
  const artifact = await directory(t);
  await createUplinkEvidenceStopper({ uplink: proxy, artifact })();
  const saved = JSON.parse(
    await readFile(join(artifact, 'uplink-packet-diagnostics.json'), 'utf8'),
  );
  assert.equal(saved.closed, true);
  assert.equal(saved.captureWindow.originAt, receipt.appliedAt);
  assert.equal(saved.captureWindow.excludedAfter, 2);
  assert.deepEqual(saved.events, first.events);
  assert.deepEqual(saved.observerErrors, { forward: 0, reverse: 0 });
  assert.equal(saved.overflow, false);
  assert.deepEqual(received, [packet(1), retransmission, packet(3), packet(4)]);
  assert.equal(proxy.snapshot().forward.queue.forwarded.packets, 4);
});

test('constrain-anchored capture remains empty when publication ends before constrain', async (t) => {
  const receiver = createSocket('udp4'),
    sender = createSocket('udp4');
  receiver.bind(0, '127.0.0.1');
  await once(receiver, 'listening');
  t.after(() => {
    receiver.close();
    sender.close();
  });
  let received = false;
  receiver.on('message', () => {
    received = true;
  });
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forwardRateControl: { rateBitsPerSecond: 750000 },
    recordPacketDiagnostics: true,
    packetDiagnosticsWindow: {
      origin: 'constrain',
      startAfterMilliseconds: 0,
      endAfterMilliseconds: 25000,
    },
  });
  t.after(() => proxy.close());
  sender.send(packet(1), proxy.port, '127.0.0.1');
  await until(() => received);
  await proxy.close();
  const result = proxy.packetDiagnosticsSnapshot();
  assert.equal(result.closed, true);
  assert.equal(result.captureWindow.originAt, null);
  assert.equal(result.captureWindow.excludedBefore, 2);
  assert.equal(result.events.length, 0);
});
