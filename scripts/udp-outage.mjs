import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { isPrivateLabIPv4, validatePrivateLabBind } from './private-lab-network.mjs';

/** Outage-only private lab fixture. Distinct backend sockets preserve reply routing
 * across reconnect source ports. No rate queues, payload logs or host network edits.
 * Counters describe socket sends, not remote receipt. Any fixture error invalidates a run. */
export async function createUDPOutageProxy(configuration) {
  assert(configuration && typeof configuration === 'object');
  assert(
    Object.keys(configuration).every((key) =>
      ['receiverPort', 'receiverHost', 'bindHost'].includes(key),
    ),
  );
  const { receiverPort, receiverHost = '127.0.0.1', bindHost = '127.0.0.1' } = configuration;
  validatePrivateLabBind(bindHost);
  assert(
    receiverHost === '127.0.0.1' || isPrivateLabIPv4(receiverHost),
    'Receiver must be private IPv4',
  );
  assert(Number.isInteger(receiverPort) && receiverPort > 0 && receiverPort <= 65535);
  const frontend = createSocket('udp4'),
    routes = new Map();
  const forward = { received: 0, sent: 0, dropped: 0 },
    reverse = { received: 0, sent: 0, dropped: 0 };
  const errors = [],
    phases = [],
    drainWaiters = [];
  let blocked = false,
    closing = false,
    closed = false,
    closePromise;
  let pending = 0,
    peakPending = 0,
    clientAddress;
  const drained = () =>
    pending === 0 ? Promise.resolve() : new Promise((resolve) => drainWaiters.push(resolve));
  function fail(error) {
    if (errors.length < 16) errors.push(error.code ?? error.message ?? 'UDP_ERROR');
    void close();
  }
  function send(socket, data, port, address, counts) {
    if (blocked) {
      counts.dropped++;
      return;
    }
    if (data.length > 2048 || pending >= 64) {
      counts.dropped++;
      fail(new Error('Outage fixture send bound exceeded'));
      return;
    }
    pending++;
    peakPending = Math.max(peakPending, pending);
    const done = (error) => {
      pending--;
      if (error) {
        counts.dropped++;
        fail(error);
      } else counts.sent++;
      if (pending === 0) for (const resolve of drainWaiters.splice(0)) resolve();
    };
    try {
      socket.send(data, port, address, done);
    } catch (error) {
      done(error);
    }
  }
  function closeSocket(socket) {
    return new Promise((resolve) => {
      try {
        socket.close(resolve);
      } catch (error) {
        if (error.code !== 'ERR_SOCKET_DGRAM_NOT_RUNNING')
          errors.push(error.code ?? 'UDP_CLOSE_ERROR');
        resolve();
      }
    });
  }
  function close() {
    if (closePromise) return closePromise;
    closing = true;
    closePromise = drained()
      .then(() => Promise.all([frontend, ...routes.values()].map(closeSocket)))
      .then(() => {
        closed = true;
      });
    return closePromise;
  }
  frontend.on('error', fail);
  frontend.on('message', (data, peer) => {
    if (closing) return;
    forward.received++;
    if (
      (peer.address !== '127.0.0.1' && !isPrivateLabIPv4(peer.address)) ||
      (clientAddress && peer.address !== clientAddress)
    ) {
      forward.dropped++;
      fail(new Error('Unexpected outage fixture client address'));
      return;
    }
    clientAddress ??= peer.address;
    if (blocked) {
      forward.dropped++;
      return;
    }
    const key = `${peer.address}:${peer.port}`;
    let backend = routes.get(key);
    if (!backend) {
      if (routes.size === 16) {
        forward.dropped++;
        fail(new Error('Outage fixture route bound exceeded'));
        return;
      }
      backend = createSocket('udp4');
      routes.set(key, backend);
      backend.on('error', fail);
      backend.on('message', (reply, origin) => {
        if (closing) return;
        reverse.received++;
        if (origin.address !== receiverHost || origin.port !== receiverPort) {
          reverse.dropped++;
          fail(new Error('Unexpected outage fixture receiver'));
          return;
        }
        send(frontend, reply, peer.port, peer.address, reverse);
      });
    }
    send(backend, data, receiverPort, receiverHost, forward);
  });
  try {
    frontend.bind(0, bindHost);
    await once(frontend, 'listening');
    assert(!closing, 'Outage fixture closed during startup');
    return {
      port: frontend.address().port,
      close,
      setBlocked(value) {
        assert(!closing, 'Outage fixture is closed');
        assert.equal(typeof value, 'boolean');
        assert.notEqual(value, blocked, 'Outage state already selected');
        blocked = value;
        phases.push({
          blocked,
          at: performance.now(),
          forward: { ...forward },
          reverse: { ...reverse },
        });
        // Joining pre-fault native sends defines the beginning of the blackhole.
        return drained();
      },
      snapshot: () =>
        structuredClone({
          scope: 'Publisher UDP only; API and relay management unaffected',
          blocked,
          closed,
          routes: routes.size,
          pending,
          peakPending,
          forward,
          reverse,
          phases,
          errors,
        }),
    };
  } catch (error) {
    await close();
    throw error;
  }
}
