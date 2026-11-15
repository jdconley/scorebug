import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createUDPImpairmentProxy } from './udp-impairment.mjs';
import {
  measuredCapacityUplinkConfiguration,
  qualifyMeasuredCapacityUplink,
} from './measured-capacity-uplink.mjs';

// Standalone, payload-only UDP experiment. No camera, media, credentials or remote service.
const root = fileURLToPath(new URL('..', import.meta.url));
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/measured-capacity-uplink-'));
const configuration = measuredCapacityUplinkConfiguration('capacity550k');
const sourceFiles = [
  'scripts/test-measured-capacity-uplink.mjs',
  'scripts/measured-capacity-uplink.mjs',
  'scripts/native-measured-uplink.mjs',
  'scripts/udp-impairment.mjs',
  'scripts/datagram-timeline-qualification.mjs',
];
const hashes = {};
for (const file of sourceFiles) {
  const bytes = await readFile(join(root, file));
  hashes[file] = createHash('sha256').update(bytes).digest('hex');
  const savedSource = join(artifact, 'source', file);
  await mkdir(dirname(savedSource), { recursive: true });
  await writeFile(savedSource, bytes, { flag: 'wx' });
}
const save = (name, value) =>
  writeFile(join(artifact, name), JSON.stringify(value, null, 2) + '\n', { flag: 'wx' });
await save('configuration.json', {
  configuration,
  sourceHashes: hashes,
  durationMilliseconds: 180500,
  payloadBytes: 1316,
  sendIntervalMilliseconds: 10,
  replyEvery: 5,
  replyBytes: 100,
  scope: 'Owned loopback UDP fault mechanism; no native media/recovery qualification.',
});
console.log(`Capacity experiment: ${artifact}`);
const controller = new AbortController(),
  errors = [];
const fail = (error) => {
  if (errors.length < 8) errors.push(String(error).slice(0, 256));
  controller.abort();
};
const timeout = setTimeout(
  () => fail(new Error('Capacity campaign exceeded200s deadline')),
  200000,
);
const onSignal = () => fail(new Error('Capacity campaign interrupted'));
process.once('SIGINT', onSignal);
process.once('SIGTERM', onSignal);
const receiver = createSocket('udp4'),
  client = createSocket('udp4');
receiver.on('error', fail);
client.on('error', fail);
let proxy,
  timer,
  receiverBound = false,
  clientBound = false,
  sent = 0,
  received = 0,
  replies = 0,
  repliesSent = 0,
  pending = 0,
  peakPending = 0,
  replyPending = 0,
  peakReplyPending = 0,
  replySkipped = 0,
  skipped = 0,
  lastReceived = -1,
  lastReply = -1;
let failure;
async function until(check, milliseconds) {
  const end = performance.now() + milliseconds;
  while (!check() && performance.now() < end) {
    controller.signal.throwIfAborted();
    await delay(10, undefined, { signal: controller.signal });
  }
  assert(check(), 'Pending sockets/queues failed to drain');
}
async function close(socket) {
  await new Promise((resolve) => socket.close(resolve));
}
try {
  receiver.bind(0, '127.0.0.1');
  await once(receiver, 'listening');
  receiverBound = true;
  client.bind(0, '127.0.0.1');
  await once(client, 'listening');
  clientBound = true;
  receiver.on('message', (data, remote) => {
    try {
      assert.equal(remote.address, '127.0.0.1');
      assert.equal(data.length, 1316);
      const id = data.readUInt32BE(0);
      assert(id > lastReceived, 'Reordered/duplicate receiver payload');
      lastReceived = id;
      received++;
      if (received % 5 === 0) {
        if (replyPending === 64) {
          replySkipped++;
          throw new Error('Reply send bound exceeded');
        }
        const reply = Buffer.alloc(100);
        reply.writeUInt32BE(id);
        repliesSent++;
        replyPending++;
        peakReplyPending = Math.max(peakReplyPending, replyPending);
        try {
          receiver.send(reply, remote.port, remote.address, (error) => {
            replyPending--;
            if (error) fail(error);
          });
        } catch (error) {
          replyPending--;
          throw error;
        }
      }
    } catch (error) {
      fail(error);
    }
  });
  client.on('message', (data) => {
    try {
      assert.equal(data.length, 100);
      const id = data.readUInt32BE(0);
      assert(id > lastReply, 'Reordered/duplicate reply');
      lastReply = id;
      replies++;
    } catch (error) {
      fail(error);
    }
  });
  proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    ...configuration,
  });
  const send = () => {
    if (pending === 16) {
      skipped++;
      return;
    }
    const data = Buffer.alloc(1316);
    data.writeUInt32BE(sent++);
    pending++;
    peakPending = Math.max(peakPending, pending);
    try {
      client.send(data, proxy.port, '127.0.0.1', (error) => {
        pending--;
        if (error) fail(error);
      });
    } catch (error) {
      pending--;
      fail(error);
    }
  };
  send();
  timer = setInterval(send, 10);
  await delay(180500, undefined, { signal: controller.signal });
  clearInterval(timer);
  timer = undefined;
  // Join each hop in order. Empty queues alone do not prove socket receipt.
  await until(
    () => pending === 0 && proxy.snapshot().forward.queue.received.packets === sent,
    1000,
  );
  await until(() => {
    const d = proxy.snapshot().forward;
    return (
      d.pendingPackets === 0 &&
      d.queue.queue.packets === 0 &&
      received === d.queue.forwarded.packets
    );
  }, 1000);
  await until(
    () => replyPending === 0 && proxy.snapshot().reverse.queue.received.packets === repliesSent,
    1000,
  );
  await until(() => {
    const d = proxy.snapshot().reverse;
    return (
      d.pendingPackets === 0 && d.queue.queue.packets === 0 && replies === d.queue.forwarded.packets
    );
  }, 1000);
} catch (error) {
  failure = error;
} finally {
  clearInterval(timer);
  clearTimeout(timeout);
  process.removeListener('SIGINT', onSignal);
  process.removeListener('SIGTERM', onSignal);
  if (proxy) await proxy.close();
  // Error/cancellation cleanup also gives unconnected send callbacks a bounded
  // chance to finish before socket close. Exhaustion remains a failed campaign.
  const drainDeadline = performance.now() + 1000;
  while ((pending || replyPending) && performance.now() < drainDeadline) await delay(10);
  if (pending || replyPending) failure ??= new Error('Endpoint send callbacks did not join');
  if (clientBound) await close(client);
  if (receiverBound) await close(receiver);
}
const snapshot = proxy?.snapshot();
if (snapshot) await save('uplink.json', snapshot);
await save('endpoints.json', {
  sent,
  received,
  repliesSent,
  replies,
  pending,
  peakPending,
  replyPending,
  peakReplyPending,
  replyPendingLimit: 64,
  replySkipped,
  sendCallbacksJoined: pending === 0 && replyPending === 0,
  skipped,
  errors,
  joined: true,
});
const changed = [];
for (const file of sourceFiles) {
  const digest = createHash('sha256')
    .update(await readFile(join(root, file)))
    .digest('hex');
  if (digest !== hashes[file]) changed.push(file);
}
await save('source-verification.json', { count: sourceFiles.length, changed });
try {
  if (failure) throw failure;
  assert.deepEqual(changed, []);
  assert.deepEqual(errors, []);
  assert.equal(pending, 0);
  assert.equal(replyPending, 0);
  assert.equal(replySkipped, 0);
  assert(peakReplyPending <= 64);
  assert.equal(skipped, 0);
  assert.equal(sent, snapshot.forward.queue.received.packets, 'Loopback input loss');
  assert.equal(received, snapshot.forward.queue.forwarded.packets, 'Loopback receiver loss');
  assert.equal(repliesSent, snapshot.reverse.queue.received.packets, 'Loopback reply input loss');
  assert.equal(replies, snapshot.reverse.queue.forwarded.packets, 'Loopback reply output loss');
  const qualification = qualifyMeasuredCapacityUplink(snapshot);
  await save('qualification.json', qualification);
  console.log(JSON.stringify({ artifact, ...qualification }));
} catch (error) {
  await save('failure.json', { message: String(error), stack: error.stack });
  throw error;
}
