import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, get } from 'node:http';
import { connect } from 'node:net';
import { once } from 'node:events';
import { createTCPOutageProxy } from '../tcp-outage.mjs';

function request(port) {
  return new Promise((resolve, reject) => {
    const req = get({ host: '127.0.0.1', port, agent: false }, (res) => {
      res.resume();
      res.once('end', () => resolve(res.statusCode));
    });
    req.once('error', reject);
    req.setTimeout(2000, () => req.destroy(new Error('timeout')));
  });
}

test('client outage drops existing sockets, rejects API traffic, restores access and joins cleanup', async (t) => {
  const backend = createServer((_req, res) => res.end('ok'));
  backend.listen(0, '127.0.0.1');
  await once(backend, 'listening');
  t.after(() => new Promise((resolve) => backend.close(resolve)));
  const proxy = await createTCPOutageProxy({ receiverPort: backend.address().port });
  t.after(() => proxy.close());
  assert.equal(await request(proxy.port), 200);
  const idle = connect(proxy.port, '127.0.0.1');
  idle.on('error', () => {});
  await once(idle, 'connect');
  const closed = new Promise((resolve) => idle.once('close', resolve));
  await proxy.setBlocked(true);
  await closed;
  await assert.rejects(request(proxy.port));
  assert.equal(await request(backend.address().port), 200);
  const blocked = proxy.snapshot();
  assert.equal(blocked.active, 0);
  assert(blocked.rejected > 0);
  await proxy.setBlocked(false);
  assert.equal(await request(proxy.port), 200);
  await proxy.close();
  await proxy.close();
  assert.equal(proxy.snapshot().active, 0);
  assert.equal(proxy.snapshot().closed, true);
  assert.deepEqual(proxy.snapshot().errors, []);
});

test('invalid endpoints are rejected before binding', async () => {
  for (const config of [
    { receiverPort: 0 },
    { receiverPort: 65536 },
    { receiverPort: 9, receiverHost: '8.8.8.8' },
    { receiverPort: 9, extra: true },
  ])
    await assert.rejects(createTCPOutageProxy(config));
});
