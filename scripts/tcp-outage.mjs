// Local client-network fixture. Never inspect or log HTTP data or credentials.
import assert from 'node:assert/strict';
import { createServer, connect } from 'node:net';
import { validatePrivateLabBind, isPrivateLabIPv4 } from './private-lab-network.mjs';

export async function createTCPOutageProxy(config) {
  assert(
    Object.keys(config).every((key) => ['receiverHost', 'receiverPort', 'bindHost'].includes(key)),
  );
  const { receiverHost = '127.0.0.1', receiverPort, bindHost = '127.0.0.1' } = config;
  validatePrivateLabBind(bindHost);
  assert(receiverHost === '127.0.0.1' || isPrivateLabIPv4(receiverHost));
  assert(Number.isInteger(receiverPort) && receiverPort > 0 && receiverPort <= 65535);
  const pairs = new Set(),
    errors = [],
    phases = [];
  let blocked = false,
    closing,
    closed = false,
    accepted = 0,
    rejected = 0;
  let forwardedBytes = 0,
    returnedBytes = 0;
  const snapshot = () => ({
    blocked,
    closed,
    active: pairs.size,
    accepted,
    rejected,
    forwardedBytes,
    returnedBytes,
    errors: [...errors],
    phases: [...phases],
  });
  const server = createServer((client) => {
    // Retain rejected sockets too, so close() joins everything we own.
    const pair = { client, upstream: undefined, done: undefined };
    pairs.add(pair);
    const clientDone = new Promise((resolve) => client.once('close', resolve));
    client.on('error', (error) => {
      if (!['ECONNRESET', 'EPIPE'].includes(error.code)) errors.push(error.code ?? 'client-error');
      pair.upstream?.destroy();
    });
    if (blocked || closing || pairs.size > 64) {
      if (!blocked && !closing) errors.push('Connection bound exceeded');
      rejected++;
      pair.done = clientDone.finally(() => pairs.delete(pair));
      client.destroy();
      return;
    }
    accepted++;
    const upstream = connect({ host: receiverHost, port: receiverPort });
    pair.upstream = upstream;
    const upstreamDone = new Promise((resolve) => upstream.once('close', resolve));
    pair.done = Promise.all([clientDone, upstreamDone]).finally(() => pairs.delete(pair));
    upstream.on('error', (error) => {
      if (!['ECONNRESET', 'EPIPE'].includes(error.code))
        errors.push(error.code ?? 'upstream-error');
      client.destroy();
    });
    client.once('close', () => upstream.destroy());
    upstream.once('close', () => client.destroy());
    client.on('data', (data) => {
      forwardedBytes += data.length;
    });
    upstream.on('data', (data) => {
      returnedBytes += data.length;
    });
    client.pipe(upstream).pipe(client);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, bindHost, () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
  server.on('error', (error) => {
    errors.push(error.code ?? 'server-error');
  });
  const port = server.address().port;
  async function destroyPairs() {
    const owned = [...pairs];
    for (const pair of owned) {
      pair.client.destroy();
      pair.upstream?.destroy();
    }
    await Promise.all(owned.map((pair) => pair.done));
  }
  return {
    port,
    snapshot,
    async setBlocked(value) {
      assert(!closing && !closed, 'Outage fixture is closed');
      assert.equal(typeof value, 'boolean');
      blocked = value;
      if (blocked) await destroyPairs();
      phases.push({ at: Date.now(), blocked, accepted, rejected, forwardedBytes, returnedBytes });
    },
    close() {
      return (closing ??= (async () => {
        blocked = true;
        const stopped = new Promise((resolve) => server.close(resolve));
        await destroyPairs();
        await stopped;
        closed = true;
      })());
    },
  };
}
