import test from 'node:test';
import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { createConnection } from 'node:net';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createUDPImpairmentProxy } from '../udp-impairment.mjs';
import { startOrdinaryRecoveryControl } from '../ordinary-recovery-control.mjs';

async function fixture(t) {
  const artifact = await mkdtemp(join(tmpdir(), 'scorebug-recovery-control-'));
  const receiver = createSocket('udp4'),
    publisher = createSocket('udp4');
  await new Promise((resolve) => receiver.bind(0, '127.0.0.1', resolve));
  await new Promise((resolve) => publisher.bind(0, '127.0.0.1', resolve));
  const uplink = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forward: { recordTimeline: true, recordRateLedger: true },
    reverse: { recordTimeline: true },
    forwardRateControl: { rateBitsPerSecond: 750000 },
  });
  const control = await startOrdinaryRecoveryControl({ uplink, artifact });
  t.after(async () => {
    await control.stop();
    await uplink.close();
    await Promise.all([receiver, publisher].map((s) => new Promise((resolve) => s.close(resolve))));
    await rm(artifact, { recursive: true, force: true });
  });
  const diagnostic = {
    policyOwnerKey: 'a'.repeat(64),
    policyAttemptID: 'attempt',
    policyAppliedRevision: '2',
  };
  const request = (operation, sequence, overrides = {}) =>
    fetch(`${control.endpoint}/${operation}`, {
      method: 'POST',
      headers: { authorization: `Bearer ${control.token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ runID: control.runID, sequence, diagnostic, ...overrides }),
      signal: AbortSignal.timeout(3000),
    });
  async function peer() {
    publisher.send(Buffer.from('actual-publisher'), uplink.port, '127.0.0.1');
    const end = performance.now() + 1000;
    while (!uplink.snapshot().forwardRateControl.startedAt && performance.now() < end)
      await delay(2);
    assert(uplink.snapshot().forwardRateControl.startedAt);
  }
  return { artifact, control, uplink, request, peer };
}

test('authenticated native requests apply exactly two real UDP phases and preserve host brackets', async (t) => {
  const f = await fixture(t);
  assert.equal(
    (await f.request('constrain', 1)).status,
    409,
    'No publisher means no applied phase',
  );
  await f.peer();
  const first = await f.request('constrain', 1);
  assert.equal(first.status, 200);
  const constrained = await first.json();
  assert.equal(constrained.phase, 'constrained');
  assert.equal(constrained.rateBitsPerSecond, 750000);
  assert.equal((await f.request('constrain', 1)).status, 409);
  assert.equal((await f.request('restore', 3)).status, 409);
  const second = await f.request('restore', 2);
  assert.equal(second.status, 200);
  const restored = await second.json();
  assert.equal(restored.phase, 'restored');
  assert.equal(restored.rateBitsPerSecond, null);
  const phases = f.uplink.snapshot().forwardRateControl.phases;
  assert.equal(phases.length, 3);
  assert.equal(constrained.appliedAt, phases[1].appliedAt);
  assert.equal(restored.appliedAt, phases[2].appliedAt);
  await Promise.all([f.control.stop(), f.control.stop()]);
  const audit = JSON.parse(await readFile(join(f.artifact, 'ordinary-recovery-control.json')));
  assert.equal(audit.closed, true);
  assert.equal(audit.records.length, 2);
  for (const row of audit.records) {
    assert(row.receivedAtHost <= row.receipt.appliedAt);
    assert(row.receipt.appliedAt <= row.respondedAtHost);
    assert.equal(row.diagnostic.policyOwnerKey, 'a'.repeat(64));
  }
  assert.equal(JSON.stringify(audit).includes(f.control.token), false);
  await assert.rejects(
    fetch(`${f.control.endpoint}/restore`, { signal: AbortSignal.timeout(500) }),
  );
});

test('unauthorized, malformed, oversized and out-of-order control never alter the UDP phase', async (t) => {
  const f = await fixture(t);
  await f.peer();
  assert.equal((await fetch(`${f.control.endpoint}/constrain`, { method: 'POST' })).status, 401);
  assert.equal((await f.request('other', 1)).status, 404);
  assert.equal((await f.request('restore', 1)).status, 409);
  assert.equal((await f.request('constrain', 1, { runID: 'foreign' })).status, 400);
  assert.equal(
    (await f.request('constrain', 1, { diagnostic: { a: 'x'.repeat(4100) } })).status,
    400,
  );
  assert.equal((await f.request('constrain', 1, { diagnostic: { a: 1 } })).status, 400);
  const response = await fetch(`${f.control.endpoint}/constrain`, {
    method: 'POST',
    headers: { authorization: `Bearer ${f.control.token}` },
    body: 'x'.repeat(9000),
  });
  assert.equal(response.status, 413);
  assert.equal(f.uplink.snapshot().forwardRateControl.phases.length, 1);
  assert.equal((await f.request('constrain', 1)).status, 200);
});

test('control joins an unfinished request and retains incomplete phase evidence', async (t) => {
  const f = await fixture(t);
  await f.peer();
  const socket = createConnection({
    host: '127.0.0.1',
    port: Number(new URL(f.control.endpoint).port),
  });
  socket.on('error', () => {});
  const finished = once(socket, 'close');
  await once(socket, 'connect');
  socket.write(
    `POST /constrain HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${f.control.token}\r\nContent-Length: 1000\r\n\r\n{`,
  );
  await delay(20);
  assert.equal(
    (await f.request('constrain', 1)).status,
    409,
    'Concurrent mutation must be rejected',
  );
  await f.control.stop();
  await finished;
  const audit = JSON.parse(await readFile(join(f.artifact, 'ordinary-recovery-control.json')));
  assert.equal(audit.records.length, 0);
  assert.equal(f.uplink.snapshot().forwardRateControl.phases.length, 1);
});
