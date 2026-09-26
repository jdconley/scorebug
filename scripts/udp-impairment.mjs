import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { RateLedgerObserver } from './rate-ledger-observer.mjs';
import { SRTPacketDiagnostics } from './srt-packet-diagnostics.mjs';

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
const dispositions = [
  'received',
  'forwarded',
  'injectedDrop',
  'overflowDrop',
  'oversizeDrop',
  'closeDiscard',
];
const allCounters = () => Object.fromEntries(dispositions.map((k) => [k, counters()]));

/** Payload-free sparse bins on the queue's existing monotonic clock. Never controls delivery. */
class QueueTimeline {
  scope =
    'Sparse event bins; queue peaks observe occupancy before/after packet dispositions, not continuously sampled coverage.';
  windowMilliseconds = 100;
  capacity = 8192;
  windows = [];
  omitted = allCounters();
  omittedEvents = 0;
  firstObservedAt = null;
  lastObservedAt = null;
  time(now) {
    this.firstObservedAt ??= now;
    this.lastObservedAt = now;
  }
  window(now) {
    const start = Math.floor(now / this.windowMilliseconds) * this.windowMilliseconds;
    if (this.windows.at(-1)?.start === start) return this.windows.at(-1);
    if (this.windows.length === this.capacity) return null;
    const value = {
      start,
      end: start + this.windowMilliseconds,
      ...allCounters(),
      peakQueuePackets: 0,
      peakQueueBytes: 0,
      maximumForwardResidenceMilliseconds: 0,
    };
    this.windows.push(value);
    return value;
  }
  account(kind, bytes, now, packets, queueBytes, residence) {
    const row = this.window(now);
    const target = row ?? this.omitted;
    target[kind].packets++;
    target[kind].wireBytes += bytes;
    if (!row) {
      this.omittedEvents++;
      return;
    }
    row.peakQueuePackets = Math.max(row.peakQueuePackets, packets);
    row.peakQueueBytes = Math.max(row.peakQueueBytes, queueBytes);
    row.maximumForwardResidenceMilliseconds = Math.max(
      row.maximumForwardResidenceMilliseconds,
      residence,
    );
  }
  queued(now, packets, bytes) {
    const row = this.window(now);
    if (!row) return;
    row.peakQueuePackets = Math.max(row.peakQueuePackets, packets);
    row.peakQueueBytes = Math.max(row.peakQueueBytes, bytes);
  }
}
function validateRate(rate) {
  assert.ok(rate === null || (Number.isFinite(rate) && rate >= 1 && rate <= 1e12), 'Invalid rate');
}
function validateReceiverHost(host) {
  assert.ok(
    typeof host === 'string' && /^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$/.test(host),
    'Invalid receiver host',
  );
  const octets = host.split('.').map(Number);
  assert.ok(
    octets.every((octet) => octet <= 255) &&
      (octets[0] === 127 ||
        octets[0] === 10 ||
        (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] === 192 && octets[1] === 168)),
    'Invalid receiver host',
  );
}
function validateControl(configuration, initialRate) {
  if (!('forwardRateControl' in configuration)) return null;
  const control = configuration.forwardRateControl;
  assert.ok(
    control &&
      typeof control === 'object' &&
      !Array.isArray(control) &&
      Reflect.ownKeys(control).length === 1 &&
      Object.hasOwn(control, 'rateBitsPerSecond'),
    'Invalid forward rate control',
  );
  const rateBitsPerSecond = control.rateBitsPerSecond;
  assert.ok(Number.isFinite(rateBitsPerSecond), 'Invalid forward rate control');
  validateRate(rateBitsPerSecond);
  assert.equal(initialRate, null, 'Rate control requires an unlimited initial rate');
  assert.ok(!('forwardRateSchedule' in configuration), 'Rate control cannot select a schedule');
  return Object.freeze({ mode: 'single-constraint', rateBitsPerSecond });
}
function validateSchedule(schedule, initialRate) {
  if (schedule === null) return null;
  assert.ok(
    Array.isArray(schedule) && schedule.length >= 2 && schedule.length <= 8,
    'Invalid forward rate schedule',
  );
  let previous = -1;
  for (const phase of schedule) {
    assert.ok(
      phase &&
        typeof phase === 'object' &&
        Object.keys(phase).length === 2 &&
        'atMilliseconds' in phase &&
        'rateBitsPerSecond' in phase,
      'Invalid rate phase',
    );
    assert.ok(
      Number.isSafeInteger(phase.atMilliseconds) &&
        phase.atMilliseconds >= 0 &&
        phase.atMilliseconds <= 600000 &&
        phase.atMilliseconds > previous,
      'Invalid phase offset',
    );
    validateRate(phase.rateBitsPerSecond);
    previous = phase.atMilliseconds;
  }
  assert.equal(schedule[0].atMilliseconds, 0, 'Schedule must begin at zero');
  assert.equal(schedule[0].rateBitsPerSecond, initialRate, 'Initial phase must match queue rate');
  return structuredClone(schedule);
}

/** Opaque IPv4 UDP fixture queue. Rate includes 28-byte IPv4/UDP headers;
 * payload already includes SRT headers. Actual elapsed time replenishes a bounded
 * token bucket: delayed timers cannot accumulate an unbounded catch-up burst. */
export class DatagramImpairmentQueue {
  #configuration;
  #timeline;
  #rateLedger;
  #packetObserver;
  #packetDiagnosticErrors = 0;
  #operationOrdinal = 0;
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
  constructor(configuration = {}, packetObserver) {
    assert.ok(packetObserver === undefined || typeof packetObserver === 'function');
    this.#packetObserver = packetObserver;
    assert.ok(configuration && typeof configuration === 'object' && !Array.isArray(configuration));
    for (const key of Object.keys(configuration))
      assert.ok(
        key in defaults || key === 'recordTimeline' || key === 'recordRateLedger',
        `Unknown impairment option ${key}`,
      );
    const {
      recordTimeline = false,
      recordRateLedger = false,
      ...queueConfiguration
    } = configuration;
    assert.equal(typeof recordTimeline, 'boolean', 'Invalid timeline selection');
    assert.equal(typeof recordRateLedger, 'boolean', 'Invalid rate ledger selection');
    const c = { ...defaults, ...queueConfiguration };
    validateRate(c.rateBitsPerSecond);
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
    if (recordTimeline) this.#timeline = new QueueTimeline();
    if (recordRateLedger) this.#rateLedger = new RateLedgerObserver(c);
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
    if (this.#rateLedger) this.#operationOrdinal++;
    this.#timeline?.time(now);
  }
  setRate(rateBitsPerSecond, now) {
    assert.ok(!this.#closed, 'Cannot change a closed queue');
    validateRate(rateBitsPerSecond);
    // Advance at the old rate, preserving the token balance and FIFO deadlines.
    this.#advance(now);
    const previousRate = this.#configuration.rateBitsPerSecond;
    this.#configuration = Object.freeze({ ...this.#configuration, rateBitsPerSecond });
    if (this.#rateLedger)
      this.#rateLedger.rateChange(
        previousRate,
        this.#configuration,
        this.#operationOrdinal,
        now,
        this.#tokens,
        this.#ledgerState(),
      );
  }
  #ledgerState() {
    return {
      counters: this.#counts,
      fifo: Array.from({ length: this.#count }, (_, i) => {
        const item = this.#storage[(this.#head + i) % this.#storage.length];
        return [item.receivedOrdinal, item.bytes, item.enqueuedAt, item.readyAt];
      }),
    };
  }
  #recordOperation(kind, detail, tokens = this.#tokens) {
    if (this.#rateLedger?.active)
      this.#rateLedger.record([this.#operationOrdinal, this.#lastTime, kind, tokens, detail]);
  }
  rateLedgerSnapshot() {
    return this.#rateLedger?.snapshot() ?? null;
  }
  get packetDiagnosticErrors() {
    return this.#packetDiagnosticErrors;
  }
  #observePacket(data, disposition, ordinal = this.#counts.received.packets) {
    if (!this.#packetObserver) return;
    try {
      this.#packetObserver({ data, disposition, ordinal, at: this.#lastTime });
    } catch {
      this.#packetDiagnosticErrors++;
    }
  }
  #account(kind, bytes, residence = 0) {
    this.#counts[kind].packets++;
    this.#counts[kind].wireBytes += bytes;
    this.#timeline?.account(kind, bytes, this.#lastTime, this.#count, this.#bytes, residence);
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
      this.#observePacket(data, 'oversizeDrop');
      if (this.#rateLedger?.recording)
        this.#recordOperation('enqueue', [this.#counts.received.packets, bytes, 'oversizeDrop']);
      return false;
    }
    if (c.dropEvery && this.#counts.received.packets % c.dropEvery === 0) {
      this.#account('injectedDrop', bytes);
      this.#observePacket(data, 'injectedDrop');
      if (this.#rateLedger?.recording)
        this.#recordOperation('enqueue', [this.#counts.received.packets, bytes, 'injectedDrop']);
      return false;
    }
    if (this.#count === c.maxQueuePackets || this.#bytes + bytes > c.maxQueueBytes) {
      this.#account('overflowDrop', bytes);
      this.#observePacket(data, 'overflowDrop');
      if (this.#rateLedger?.recording)
        this.#recordOperation('enqueue', [this.#counts.received.packets, bytes, 'overflowDrop']);
      return false;
    }
    this.#storage[(this.#head + this.#count) % this.#storage.length] = {
      data: Buffer.from(data),
      receivedOrdinal: this.#counts.received.packets,
      bytes,
      readyAt: now + c.delayMilliseconds,
      enqueuedAt: now,
    };
    this.#count++;
    this.#bytes += bytes;
    this.#peakPackets = Math.max(this.#peakPackets, this.#count);
    this.#peakBytes = Math.max(this.#peakBytes, this.#bytes);
    this.#timeline?.queued(now, this.#count, this.#bytes);
    this.#observePacket(data, 'queued');
    if (this.#rateLedger?.recording)
      this.#recordOperation('enqueue', [this.#counts.received.packets, bytes, 'queued']);
    return true;
  }
  takeReady(now) {
    if (this.#closed) return null;
    this.#advance(now);
    const item = this.#storage[this.#head];
    if (!this.#count) {
      if (this.#rateLedger?.recording) this.#recordOperation('takeReady', ['empty', null, null]);
      return null;
    }
    if (item.readyAt > now) {
      if (this.#rateLedger?.recording)
        this.#recordOperation('takeReady', ['delay', item.receivedOrdinal, item.bytes]);
      return null;
    }
    if (this.#configuration.rateBitsPerSecond !== null && this.#tokens + 1e-9 < item.bytes) {
      if (this.#rateLedger?.recording)
        this.#recordOperation('takeReady', ['tokenDenied', item.receivedOrdinal, item.bytes]);
      this.#rateLedger?.denial(
        this.#operationOrdinal,
        now,
        item.receivedOrdinal,
        item.bytes,
        this.#tokens,
      );
      return null;
    }
    if (this.#rateLedger?.recording)
      this.#recordOperation('takeReady', ['forwarded', item.receivedOrdinal, item.bytes]);
    if (this.#configuration.rateBitsPerSecond !== null)
      this.#tokens = Math.max(0, this.#tokens - item.bytes);
    this.#timeline?.queued(now, this.#count, this.#bytes);
    this.#storage[this.#head] = undefined;
    this.#head = (this.#head + 1) % this.#storage.length;
    this.#count--;
    this.#bytes -= item.bytes;
    this.#account('forwarded', item.bytes, now - item.enqueuedAt);
    this.#firstForwardedAt ??= now;
    this.#lastForwardedAt = now;
    this.#observePacket(item.data, 'forwarded', item.receivedOrdinal);
    return item.data;
  }
  nextDelay(now) {
    if (this.#closed) return null;
    this.#advance(now);
    if (!this.#count) {
      if (this.#rateLedger?.recording) this.#recordOperation('nextDelay', null);
      return null;
    }
    const item = this.#storage[this.#head],
      rate = this.#configuration.rateBitsPerSecond;
    const delay = Math.max(
      0,
      item.readyAt - now,
      rate === null ? 0 : ((item.bytes - this.#tokens) * 8000) / rate,
    );
    if (this.#rateLedger?.recording) this.#recordOperation('nextDelay', delay);
    return delay;
  }
  close(now = this.#lastTime ?? 0) {
    if (this.#closed) return;
    this.#advance(now);
    this.#closed = true;
    if (this.#rateLedger?.recording) this.#recordOperation('close', null);
    for (let i = 0; i < this.#count; i++) {
      const index = (this.#head + i) % this.#storage.length;
      this.#account('closeDiscard', this.#storage[index].bytes);
      this.#observePacket(
        this.#storage[index].data,
        'closeDiscard',
        this.#storage[index].receivedOrdinal,
      );
      this.#storage[index] = undefined;
    }
    this.#count = 0;
    this.#bytes = 0;
    if (this.#rateLedger?.active)
      this.#rateLedger.finish(
        this.#operationOrdinal,
        now,
        this.#tokens,
        this.#ledgerState(),
        false,
      );
  }
  snapshot() {
    return structuredClone({
      configuration: this.#configuration,
      ...(this.#rateLedger
        ? {
            rateLedgerOperationOrdinal: this.#operationOrdinal,
            rateLedgerFirstDenial: this.#rateLedger.firstDenialSnapshot(),
          }
        : {}),
      ...(this.#timeline ? { timeline: this.#timeline } : {}),
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

/** Owned loopback-frontend fixture with a loopback/private IPv4 receiver.
 * Forwarded counters are UDP send attempts, not
 * remote receipt; any socket error invalidates qualification and closes the proxy. */
export async function createUDPImpairmentProxy(configuration) {
  assert.ok(configuration && typeof configuration === 'object');
  for (const key of Object.keys(configuration))
    assert.ok(
      [
        'receiverPort',
        'receiverHost',
        'forward',
        'reverse',
        'forwardRateSchedule',
        'forwardRateControl',
        'recordPacketDiagnostics',
        'packetDiagnosticsWindow',
      ].includes(key),
      'Unknown proxy option',
    );
  const {
    receiverPort,
    receiverHost = '127.0.0.1',
    forward = {},
    reverse = {},
    forwardRateSchedule = null,
  } = configuration;
  validateReceiverHost(receiverHost);
  const control = validateControl(configuration, forward.rateBitsPerSecond ?? null);
  const { recordPacketDiagnostics = false, packetDiagnosticsWindow = null } = configuration;
  assert.equal(typeof recordPacketDiagnostics, 'boolean', 'Invalid packet diagnostic selection');
  assert.equal(
    recordPacketDiagnostics,
    packetDiagnosticsWindow !== null,
    'Packet diagnostics require an explicit capture window',
  );
  if (packetDiagnosticsWindow !== null) {
    const w = packetDiagnosticsWindow;
    assert.ok(
      w &&
        typeof w === 'object' &&
        !Array.isArray(w) &&
        Object.keys(w).every((key) =>
          ['origin', 'startAfterMilliseconds', 'endAfterMilliseconds'].includes(key),
        ) &&
        (!Object.hasOwn(w, 'origin') || ['firstPeerPacket', 'constrain'].includes(w.origin)) &&
        (w.origin !== 'constrain' || control !== null) &&
        Number.isSafeInteger(w.startAfterMilliseconds) &&
        Number.isSafeInteger(w.endAfterMilliseconds) &&
        w.startAfterMilliseconds >= 0 &&
        w.endAfterMilliseconds > w.startAfterMilliseconds &&
        w.endAfterMilliseconds <= 600000,
      'Invalid packet diagnostic window',
    );
  }
  const packetDiagnostics = recordPacketDiagnostics ? new SRTPacketDiagnostics() : null;
  const captureWindow = packetDiagnostics
    ? { ...packetDiagnosticsWindow, originAt: null, excludedBefore: 0, excludedAfter: 0 }
    : null;
  const observePacket = (direction) =>
    packetDiagnostics
      ? (event) => {
          if (captureWindow.originAt === null) {
            captureWindow.excludedBefore++;
            return;
          }
          const elapsed = event.at - captureWindow.originAt;
          if (elapsed < captureWindow.startAfterMilliseconds) {
            captureWindow.excludedBefore++;
            return;
          }
          if (elapsed >= captureWindow.endAfterMilliseconds) {
            captureWindow.excludedAfter++;
            return;
          }
          packetDiagnostics.observe({ direction, ...event });
        }
      : undefined;
  const schedule = validateSchedule(forwardRateSchedule, forward.rateBitsPerSecond ?? null);
  assert.ok(
    Number.isInteger(receiverPort) && receiverPort > 0 && receiverPort <= 65535,
    'Invalid loopback receiver port',
  );
  const makeDirection = (options, direction) => ({
    queue: new DatagramImpairmentQueue(options, observePacket(direction)),
    timer: null,
    pending: 0,
    peakPending: 0,
    pendingBytes: 0,
    peakPendingBytes: 0,
  });
  const outgoing = makeDirection(forward, 'forward'),
    incoming = makeDirection(reverse, 'reverse');
  const frontend = createSocket('udp4'),
    backend = createSocket('udp4');
  let peer = null,
    foreignPeerPackets = 0,
    closing = false,
    closed = false,
    closePromise,
    resolvePending;
  const errors = [];
  let scheduleStartedAt = null,
    scheduleStoppedAt = null,
    scheduleTimer = null,
    phaseIndex = 0;
  const phases = [];
  let controlStartedAt = null,
    controlStoppedAt = null;
  const controlPhases = [];
  function applyControlPhase(phase, rateBitsPerSecond) {
    const now = performance.now();
    outgoing.queue.setRate(rateBitsPerSecond, now);
    if (phase === 'baseline') controlStartedAt = now;
    // Diagnostics share the exact fault boundary; they never select or change it.
    if (phase === 'constrained' && captureWindow?.origin === 'constrain')
      captureWindow.originAt = now;
    const receipt = {
      phase,
      rateBitsPerSecond,
      appliedAt: now,
      forward: directionSnapshot(outgoing),
      reverse: directionSnapshot(incoming),
    };
    controlPhases.push(receipt);
    // Preserve the exact after-change/pre-pump ledger boundary, including its
    // bounded timeline. Restoration then drains the existing FIFO immediately.
    pump(outgoing, sendForward);
    return structuredClone(receipt);
  }
  function constrainForward() {
    assert.ok(
      !closing && peer && controlPhases.length === 1,
      'Invalid control phase or closed peer',
    );
    return applyControlPhase('constrained', control.rateBitsPerSecond);
  }
  function restoreForward() {
    assert.ok(
      !closing && peer && controlPhases.length === 2,
      'Invalid control phase or closed peer',
    );
    return applyControlPhase('restored', null);
  }
  function applyDuePhases() {
    if (closing || !schedule || scheduleStartedAt === null) return;
    clearTimeout(scheduleTimer);
    scheduleTimer = null;
    const now = performance.now();
    while (
      phaseIndex < schedule.length &&
      now >= scheduleStartedAt + schedule[phaseIndex].atMilliseconds
    ) {
      const phase = schedule[phaseIndex++];
      outgoing.queue.setRate(phase.rateBitsPerSecond, now);
      phases.push({
        ...phase,
        appliedAt: now,
        forward: directionSnapshot(outgoing),
        reverse: directionSnapshot(incoming),
      });
    }
    pump(outgoing, sendForward);
    if (!closing && phaseIndex < schedule.length)
      scheduleTimer = setTimeout(
        applyDuePhases,
        Math.max(
          1,
          Math.ceil(scheduleStartedAt + schedule[phaseIndex].atMilliseconds - performance.now()),
        ),
      );
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
    scheduleStoppedAt = performance.now();
    if (control) controlStoppedAt = scheduleStoppedAt;
    clearTimeout(scheduleTimer);
    scheduleTimer = null;
    for (const direction of [outgoing, incoming]) {
      clearTimeout(direction.timer);
      direction.timer = null;
      direction.queue.close(performance.now());
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
        packetDiagnostics?.close();
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
    if (!peer) {
      peer = { address: rinfo.address, port: rinfo.port };
      if (captureWindow && captureWindow.origin !== 'constrain')
        captureWindow.originAt = performance.now();
      if (schedule) {
        scheduleStartedAt = performance.now();
        applyDuePhases();
      }
      if (control) applyControlPhase('baseline', null);
    }
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
    backend.connect(receiverPort, receiverHost);
    await once(backend, 'connect');
    assert.ok(!closing, 'Proxy closed during startup');
    const port = frontend.address().port;
    return {
      port,
      close,
      ...(control ? { constrainForward, restoreForward } : {}),
      rateLedgerSnapshot: () => outgoing.queue.rateLedgerSnapshot(),
      packetDiagnosticsSnapshot: () =>
        packetDiagnostics
          ? {
              ...packetDiagnostics.snapshot(),
              captureWindow: { ...captureWindow },
              observerErrors: {
                forward: outgoing.queue.packetDiagnosticErrors,
                reverse: incoming.queue.packetDiagnosticErrors,
              },
            }
          : null,
      snapshot: () => ({
        formatVersion: 1,
        closed,
        foreignPeerPackets,
        errors: [...errors],
        ...(control
          ? {
              forwardRateControl: {
                requested: { ...control },
                startedAt: controlStartedAt,
                stoppedAt: controlStoppedAt,
                phases: structuredClone(controlPhases),
              },
            }
          : {}),
        ...(schedule
          ? {
              forwardRateSchedule: {
                requested: structuredClone(schedule),
                startedAt: scheduleStartedAt,
                stoppedAt: scheduleStoppedAt,
                phases: structuredClone(phases),
              },
            }
          : {}),
        forward: directionSnapshot(outgoing),
        reverse: directionSnapshot(incoming),
      }),
    };
  } catch (error) {
    await close();
    throw error;
  }
}
