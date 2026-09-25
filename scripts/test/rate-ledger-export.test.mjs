import assert from 'node:assert/strict';
import test from 'node:test';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createUDPImpairmentProxy } from '../udp-impairment.mjs';
import { qualifyRateLedger } from '../rate-ledger-qualification.mjs';
const module = await import('../uplink-proxy-evidence.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const maximumBytes = 32 * 1024 * 1024;
async function directory(t) {
  const artifact = await mkdtemp(join(tmpdir(), 'rate-ledger-export-'));
  t.after(() => rm(artifact, { recursive: true, force: true }));
  return artifact;
}
function stopper(options) {
  assert.equal(typeof module.createUplinkEvidenceStopper, 'function');
  return module.createUplinkEvidenceStopper(options);
}
function fakeProxy(ledger) {
  let closed = false,
    closes = 0,
    reads = 0;
  return {
    close: async () => {
      closes++;
      await delay(1);
      closed = true;
    },
    snapshot: () => {
      assert(closed);
      return { closed };
    },
    rateLedgerSnapshot: () => {
      assert(closed);
      reads++;
      return ledger;
    },
    counts: () => ({ closes, reads }),
  };
}
for (const policy of ['unknown', '', null, 1])
  test(`export rejects invalid evidence policy ${JSON.stringify(policy)} before closing`, () => {
    const uplink = fakeProxy(null);
    assert.throws(
      () => stopper({ uplink, artifact: '/unused', capacityEvidencePolicy: policy }),
      /capacity evidence policy/i,
    );
    assert.deepEqual(uplink.counts(), { closes: 0, reads: 0 });
  });
test('joined export is compact, immutable and idempotent across collect and cleanup', async (t) => {
  const artifact = await directory(t),
    ledger = { operations: [[1, 2, 'advance']] };
  const uplink = fakeProxy(ledger);
  const stop = stopper({ artifact, uplink, capacityEvidencePolicy: 'rate-ledger-v1' });
  const first = stop();
  assert.equal(stop(), first);
  await first;
  const path = join(artifact, 'uplink-rate-ledger.json');
  const original = await readFile(path, 'utf8'),
    metadata = await stat(path);
  assert.equal(original, JSON.stringify(ledger));
  assert.equal(
    await readFile(join(artifact, 'uplink-proxy.json'), 'utf8'),
    JSON.stringify({ closed: true }, null, 2),
  );
  ledger.operations.push([3]);
  await stop();
  assert.equal(await readFile(path, 'utf8'), original);
  assert.equal((await stat(path)).mtimeMs, metadata.mtimeMs);
  assert.deepEqual(uplink.counts(), { closes: 1, reads: 1 });
});
test('default evidence keeps legacy snapshot and never reads or writes a ledger', async (t) => {
  const artifact = await directory(t),
    uplink = fakeProxy({ operations: [] });
  await stopper({ artifact, uplink })();
  assert.deepEqual(JSON.parse(await readFile(join(artifact, 'uplink-proxy.json'))), {
    closed: true,
  });
  assert.deepEqual(uplink.counts(), { closes: 1, reads: 0 });
  await assert.rejects(readFile(join(artifact, 'uplink-rate-ledger.json')), { code: 'ENOENT' });
});
for (const ledger of [null, { footer: null }, { overflow: true, invalidReasons: ['capacity'] }])
  test(`preserves diagnostic evidence ${JSON.stringify(ledger)} without qualifying it`, async (t) => {
    const artifact = await directory(t);
    await stopper({
      artifact,
      uplink: fakeProxy(ledger),
      capacityEvidencePolicy: 'rate-ledger-v1',
    })();
    const saved = JSON.parse(await readFile(join(artifact, 'uplink-rate-ledger.json')));
    assert.deepEqual(saved, ledger);
    assert.throws(() =>
      qualifyRateLedger({ ledger: saved, limited: null, restored: null }, { configuration: {} }),
    );
  });
test('oversized ledger fails after closure and retains failure on repeated cleanup', async (t) => {
  const artifact = await directory(t),
    uplink = fakeProxy('x'.repeat(maximumBytes));
  const stop = stopper({ artifact, uplink, capacityEvidencePolicy: 'rate-ledger-v1' });
  const result = stop();
  await assert.rejects(result, /export/i);
  assert.equal(stop(), result);
  await assert.rejects(stop(), /export/i);
  assert.deepEqual(uplink.counts(), { closes: 1, reads: 1 });
  assert.deepEqual(JSON.parse(await readFile(join(artifact, 'uplink-proxy.json'))), {
    closed: true,
  });
  await assert.rejects(readFile(join(artifact, 'uplink-rate-ledger.json')), { code: 'ENOENT' });
});
test('existing evidence is never overwritten and its error survives repeated cleanup', async (t) => {
  const artifact = await directory(t),
    path = join(artifact, 'uplink-rate-ledger.json');
  await writeFile(path, 'original');
  const uplink = fakeProxy(null);
  const stop = stopper({ artifact, uplink, capacityEvidencePolicy: 'rate-ledger-v1' });
  await assert.rejects(stop(), /export/i);
  await assert.rejects(stop(), /export/i);
  assert.equal(await readFile(path, 'utf8'), 'original');
  assert.equal(uplink.counts().closes, 1);
});
test('snapshot export error still attempts ledger export after closure', async (t) => {
  const artifact = await directory(t),
    uplink = fakeProxy(null);
  await writeFile(join(artifact, 'uplink-proxy.json'), 'original');
  await assert.rejects(
    stopper({ artifact, uplink, capacityEvidencePolicy: 'rate-ledger-v1' })(),
    /export/i,
  );
  assert.equal(await readFile(join(artifact, 'uplink-rate-ledger.json'), 'utf8'), 'null');
  assert.equal(await readFile(join(artifact, 'uplink-proxy.json'), 'utf8'), 'original');
  assert.equal(uplink.counts().closes, 1);
});
async function until(predicate) {
  const deadline = performance.now() + 1000;
  while (!predicate()) {
    assert(performance.now() < deadline, 'Loopback phase deadline exceeded');
    await delay(2);
  }
}
test('loopback proxy exports forward ledger separately with original immutable phase anchors', async (t) => {
  const artifact = await directory(t),
    receiver = createSocket('udp4'),
    sender = createSocket('udp4');
  receiver.bind(0, '127.0.0.1');
  await once(receiver, 'listening');
  t.after(() => {
    receiver.close();
    sender.close();
  });
  const proxy = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forward: {
      recordTimeline: true,
      recordRateLedger: true,
      maxDatagramBytes: 100,
      burstBytes: 128,
    },
    forwardRateSchedule: [
      { atMilliseconds: 0, rateBitsPerSecond: null },
      { atMilliseconds: 40, rateBitsPerSecond: 1024 },
      { atMilliseconds: 250, rateBitsPerSecond: null },
    ],
  });
  t.after(() => proxy.close());
  assert.equal(typeof proxy.rateLedgerSnapshot, 'function');
  const send = () =>
    new Promise((resolve, reject) =>
      sender.send(Buffer.alloc(100), proxy.port, '127.0.0.1', (e) => (e ? reject(e) : resolve())),
    );
  await send();
  await until(() => proxy.snapshot().forwardRateSchedule.phases.length >= 2);
  const limited = proxy.snapshot().forwardRateSchedule.phases[1],
    originalLimited = structuredClone(limited);
  await send();
  await send();
  await send();
  await until(() => proxy.snapshot().forwardRateSchedule.phases.length === 3);
  const originalRestored = proxy.snapshot().forwardRateSchedule.phases[2];
  await until(() => proxy.snapshot().forward.queue.queue.packets === 0);
  const stop = stopper({ artifact, uplink: proxy, capacityEvidencePolicy: 'rate-ledger-v1' });
  await stop();
  await stop();
  const saved = JSON.parse(await readFile(join(artifact, 'uplink-proxy.json')));
  const raw = await readFile(join(artifact, 'uplink-rate-ledger.json'), 'utf8'),
    ledger = JSON.parse(raw);
  assert(raw.length < maximumBytes);
  assert.equal(raw, JSON.stringify(ledger));
  assert.deepEqual(saved.forwardRateSchedule.phases[1], originalLimited);
  assert.deepEqual(saved.forwardRateSchedule.phases[2], originalRestored);
  assert.deepEqual(limited, originalLimited);
  assert(!('operations' in saved.forward.queue));
  assert(!('rateLedger' in saved.forward.queue));
  assert.equal(ledger.header.limit.ordinal, limited.forward.queue.rateLedgerOperationOrdinal);
  assert.equal(
    ledger.footer.restoration.ordinal,
    originalRestored.forward.queue.rateLedgerOperationOrdinal,
  );
  assert.deepEqual(ledger.denial, originalRestored.forward.queue.rateLedgerFirstDenial);
  assert.equal(
    qualifyRateLedger(
      {
        ledger,
        limited: { appliedAt: limited.appliedAt, queue: limited.forward.queue },
        restored: { appliedAt: originalRestored.appliedAt, queue: originalRestored.forward.queue },
      },
      { configuration: limited.forward.queue.configuration },
    ).rateBoundQualified,
    true,
  );
  ledger.operations.length = 0;
  assert(proxy.rateLedgerSnapshot().operations.length > 0);
  assert.equal(saved.closed, true);
  assert.equal(saved.forward.pendingPackets, 0);
});
