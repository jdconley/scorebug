import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';

const defaults = Object.freeze({
  rateBitsPerSecond: null,
  delayMilliseconds: 0,
  dropEvery: 0,
  maxDatagramBytes: 2048,
  burstBytes: 16384,
  maxQueuePackets: 256,
  maxQueueBytes: 262144,
});
const counters = () => ({ packets: 0, wireBytes: 0 });

/** Opaque IPv4 UDP fixture queue. Rate includes 28-byte IPv4/UDP headers;
 * payload already includes SRT headers. Actual elapsed time replenishes a bounded
 * token bucket: delayed timers cannot accumulate an unbounded catch-up burst. */
export class DatagramImpairmentQueue {
  #configuration;
  #storage;
  #head = 0;
  #count = 0;
  #bytes = 0;
  #tokens;
  #lastTime = null;
  #closed = false;
  #peakPackets = 0;
  #peakBytes = 0;
  #firstForwardedAt = null;
  #lastForwardedAt = null;
  #counts = Object.fromEntries(
    ['received', 'forwarded', 'injectedDrop', 'overflowDrop', 'oversizeDrop', 'closeDiscard'].map(
      (k) => [k, counters()],
    ),
  );
  constructor(configuration = {}) {
    assert.ok(configuration && typeof configuration === 'object' && !Array.isArray(configuration));
    for (const key of Object.keys(configuration))
      assert.ok(key in defaults, `Unknown impairment option ${key}`);
    const c = { ...defaults, ...configuration };
    assert.ok(
      c.rateBitsPerSecond === null ||
        (Number.isFinite(c.rateBitsPerSecond) &&
          c.rateBitsPerSecond >= 1 &&
          c.rateBitsPerSecond <= 1e12),
      'Invalid rate',
    );
    assert.ok(
      Number.isFinite(c.delayMilliseconds) &&
        c.delayMilliseconds >= 0 &&
        c.delayMilliseconds <= 60000,
      'Invalid delay',
    );
    for (const [key, min, max] of [
      ['dropEvery', 0, 1e9],
      ['maxDatagramBytes', 1, 65507],
      ['burstBytes', c.maxDatagramBytes + 28, 1048576],
      ['maxQueuePackets', 1, 4096],
      ['maxQueueBytes', c.maxDatagramBytes + 28, 16777216],
    ])
      assert.ok(Number.isSafeInteger(c[key]) && c[key] >= min && c[key] <= max, `Invalid ${key}`);
    this.#configuration = Object.freeze(c);
    this.#storage = Array(c.maxQueuePackets);
    this.#tokens = c.burstBytes;
  }
  #advance(now) {
    assert.ok(
      Number.isFinite(now) &&
        now >= 0 &&
        now <= 1e12 &&
        (this.#lastTime === null || now >= this.#lastTime),
      'Invalid/reversed monotonic time',
    );
    const c = this.#configuration;
    if (this.#lastTime !== null && c.rateBitsPerSecond !== null)
      this.#tokens = Math.min(
        c.burstBytes,
        this.#tokens + ((now - this.#lastTime) * c.rateBitsPerSecond) / 8000,
      );
    this.#lastTime = now;
  }
  #account(kind, bytes) {
    this.#counts[kind].packets++;
    this.#counts[kind].wireBytes += bytes;
  }
  enqueue(data, now) {
    if (this.#closed) return false;
    assert.ok(Buffer.isBuffer(data), 'UDP data must be a Buffer');
    this.#advance(now);
    const bytes = data.length + 28,
      c = this.#configuration;
    this.#account('received', bytes);
    if (data.length > c.maxDatagramBytes) {
      this.#account('oversizeDrop', bytes);
      return false;
    }
    if (c.dropEvery && this.#counts.received.packets % c.dropEvery === 0) {
      this.#account('injectedDrop', bytes);
      return false;
    }
    if (this.#count === c.maxQueuePackets || this.#bytes + bytes > c.maxQueueBytes) {
      this.#account('overflowDrop', bytes);
      return false;
    }
    this.#storage[(this.#head + this.#count) % this.#storage.length] = {
      data: Buffer.from(data),
      bytes,
      readyAt: now + c.delayMilliseconds,
    };
    this.#count++;
    this.#bytes += bytes;
    this.#peakPackets = Math.max(this.#peakPackets, this.#count);
    this.#peakBytes = Math.max(this.#peakBytes, this.#bytes);
    return true;
  }
  takeReady(now) {
    if (this.#closed) return null;
    this.#advance(now);
    const item = this.#storage[this.#head];
    if (
      !this.#count ||
      item.readyAt > now ||
      (this.#configuration.rateBitsPerSecond !== null && this.#tokens + 1e-9 < item.bytes)
    )
      return null;
    if (this.#configuration.rateBitsPerSecond !== null)
      this.#tokens = Math.max(0, this.#tokens - item.bytes);
    this.#storage[this.#head] = undefined;
    this.#head = (this.#head + 1) % this.#storage.length;
    this.#count--;
    this.#bytes -= item.bytes;
    this.#account('forwarded', item.bytes);
    this.#firstForwardedAt ??= now;
    this.#lastForwardedAt = now;
    return item.data;
  }
  nextDelay(now) {
    if (this.#closed) return null;
    this.#advance(now);
    if (!this.#count) return null;
    const item = this.#storage[this.#head],
      rate = this.#configuration.rateBitsPerSecond;
    return Math.max(
      0,
      item.readyAt - now,
      rate === null ? 0 : ((item.bytes - this.#tokens) * 8000) / rate,
    );
  }
  close() {
    if (this.#closed) return;
    this.#closed = true;
    for (let i = 0; i < this.#count; i++) {
      const index = (this.#head + i) % this.#storage.length;
      this.#account('closeDiscard', this.#storage[index].bytes);
      this.#storage[index] = undefined;
    }
    this.#count = 0;
    this.#bytes = 0;
  }
  snapshot() {
    return structuredClone({
      configuration: this.#configuration,
      ...this.#counts,
      queue: {
        packets: this.#count,
        wireBytes: this.#bytes,
        peakPackets: this.#peakPackets,
        peakWireBytes: this.#peakBytes,
      },
      closed: this.#closed,
      firstForwardedAt: this.#firstForwardedAt,
      lastForwardedAt: this.#lastForwardedAt,
    });
  }
}

/** Owned loopback-only fixture. Forwarded counters are UDP send attempts, not
 * remote receipt; any socket error invalidates qualification and closes the proxy. */
export async function createUDPImpairmentProxy(configuration) {
  assert.ok(configuration && typeof configuration === 'object');
  for (const key of Object.keys(configuration))
    assert.ok(['receiverPort', 'forward', 'reverse'].includes(key), 'Unknown proxy option');
  const { receiverPort, forward = {}, reverse = {} } = configuration;
  assert.ok(
    Number.isInteger(receiverPort) && receiverPort > 0 && receiverPort <= 65535,
    'Invalid loopback receiver port',
  );
  const makeDirection = (options) => ({
    queue: new DatagramImpairmentQueue(options),
    timer: null,
    pending: 0,
    peakPending: 0,
    pendingBytes: 0,
    peakPendingBytes: 0,
  });
  const outgoing = makeDirection(forward),
    incoming = makeDirection(reverse);
  const frontend = createSocket('udp4'),
    backend = createSocket('udp4');
  let peer = null,
    foreignPeerPackets = 0,
    closing = false,
    closed = false,
    closePromise,
    resolvePending;
  const errors = [];
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
    for (const direction of [outgoing, incoming]) {
      clearTimeout(direction.timer);
      direction.timer = null;
      direction.queue.close();
    }
    const pendingDrained = new Promise((resolve) => {
      resolvePending = resolve;
      if (outgoing.pending + incoming.pending === 0) resolve();
    });
    // Closing an unconnected UDP socket can discard sends still in Node's address
    // lookup path without calling their callbacks. Drain those bounded sends first.
    closePromise = pendingDrained
      .then(() => Promise.all([closeSocket(frontend), closeSocket(backend)]))
      .then(() => {
        closed = true;
      });
    return closePromise;
  }
  function fail(error) {
    errors.push(error.code ?? 'UDP_ERROR');
    void close();
  }
  frontend.on('error', fail);
  backend.on('error', fail);
  function pump(direction, send) {
    if (closing) return;
    clearTimeout(direction.timer);
    direction.timer = null;
    while (direction.pending < 16) {
      const data = direction.queue.takeReady(performance.now());
      if (data === null) break;
      direction.pending++;
      direction.pendingBytes += data.length;
      direction.peakPending = Math.max(direction.peakPending, direction.pending);
      direction.peakPendingBytes = Math.max(direction.peakPendingBytes, direction.pendingBytes);
      const done = (error) => {
        direction.pending--;
        direction.pendingBytes -= data.length;
        if (closing && outgoing.pending + incoming.pending === 0) resolvePending?.();
        if (error) fail(error);
        else pump(direction, send);
      };
      try {
        send(data, done);
      } catch (error) {
        done(error);
      }
      if (closing) return;
    }
    if (direction.pending >= 16) return;
    const delay = direction.queue.nextDelay(performance.now());
    if (delay !== null)
      direction.timer = setTimeout(() => pump(direction, send), Math.max(1, Math.ceil(delay)));
  }
  const sendForward = (data, done) => backend.send(data, done);
  const sendReverse = (data, done) => frontend.send(data, peer.port, peer.address, done);
  frontend.on('message', (data, rinfo) => {
    if (closing) return;
    if (
      rinfo.address !== '127.0.0.1' ||
      (peer && (peer.address !== rinfo.address || peer.port !== rinfo.port))
    ) {
      foreignPeerPackets++;
      return;
    }
    peer ??= { address: rinfo.address, port: rinfo.port };
    outgoing.queue.enqueue(data, performance.now());
    pump(outgoing, sendForward);
  });
  backend.on('message', (data) => {
    if (closing || !peer) return;
    incoming.queue.enqueue(data, performance.now());
    pump(incoming, sendReverse);
  });
  const directionSnapshot = (d) => ({
    queue: d.queue.snapshot(),
    pendingPackets: d.pending,
    pendingPayloadBytes: d.pendingBytes,
    peakPendingPackets: d.peakPending,
    peakPendingPayloadBytes: d.peakPendingBytes,
  });
  try {
    frontend.bind(0, '127.0.0.1');
    await once(frontend, 'listening');
    backend.connect(receiverPort, '127.0.0.1');
    await once(backend, 'connect');
    assert.ok(!closing, 'Proxy closed during startup');
    const port = frontend.address().port;
    return {
      port,
      close,
      snapshot: () => ({
        formatVersion: 1,
        closed,
        foreignPeerPackets,
        errors: [...errors],
        forward: directionSnapshot(outgoing),
        reverse: directionSnapshot(incoming),
      }),
    };
  } catch (error) {
    await close();
    throw error;
  }
}
