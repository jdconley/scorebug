import test from 'node:test';
import assert from 'node:assert/strict';
import { DatagramImpairmentQueue } from '../udp-impairment.mjs';
import { RateLedgerObserver, RATE_LEDGER_LIMITS } from '../rate-ledger-observer.mjs';

const configuration = {
  rateBitsPerSecond: null,
  burstBytes: 256,
  maxDatagramBytes: 128,
  maxQueuePackets: 8,
  maxQueueBytes: 1024,
};
const packet = (id = 1) => Buffer.alloc(100, id);
function queue(extra = {}) {
  return new DatagramImpairmentQueue({ ...configuration, recordRateLedger: true, ...extra });
}

function withoutObserverAnchors(snapshot) {
  const { rateLedgerOperationOrdinal, rateLedgerFirstDenial, ...ordinary } = snapshot;
  return ordinary;
}

test('ledger is explicit, payload-free and excluded from ordinary snapshots', () => {
  const disabled = new DatagramImpairmentQueue(configuration);
  assert.equal(typeof disabled.rateLedgerSnapshot, 'function');
  assert.equal(disabled.rateLedgerSnapshot(), null);
  const q = queue();
  assert.equal(q.rateLedgerSnapshot(), null);
  assert.deepEqual(withoutObserverAnchors(q.snapshot()), disabled.snapshot());
  assert.throws(() => new DatagramImpairmentQueue({ recordRateLedger: 1 }), /ledger selection/);
});

test('records actual token denial and complete advances with same-time phase boundaries', () => {
  const q = queue();
  q.enqueue(packet(1), 0);
  q.setRate(1024, 0);
  const limit = q.snapshot();
  q.enqueue(packet(2), 0);
  q.enqueue(packet(3), 0);
  q.takeReady(0);
  q.nextDelay(0);
  q.takeReady(0);
  q.nextDelay(0);
  assert.equal(q.takeReady(0), null);
  q.setRate(null, 0);
  const restore = q.snapshot();
  const ledger = q.rateLedgerSnapshot();
  assert.equal(ledger.format, 'rate-ledger-v1');
  assert.deepEqual(ledger.header.limit, { ordinal: 2, at: 0 });
  assert.equal(ledger.header.initialTokens, 256);
  assert.deepEqual(ledger.header.initialFIFO, [[1, 128, 0, 0]]);
  assert.deepEqual(ledger.header.initialCounters.received, limit.received);
  assert.deepEqual(
    ledger.operations.map((r) => r[2]),
    [
      'enqueue',
      'enqueue',
      'takeReady',
      'nextDelay',
      'takeReady',
      'nextDelay',
      'takeReady',
      'restore',
    ],
  );
  assert.deepEqual(
    ledger.operations.map((r) => r[0]),
    [3, 4, 5, 6, 7, 8, 9, 10],
  );
  assert.deepEqual(ledger.denial, { ordinal: 9, at: 0, id: 3, wireBytes: 128, tokens: 0 });
  assert.deepEqual(ledger.footer.restoration, { ordinal: 10, at: 0 });
  assert.deepEqual(ledger.footer.finalFIFO, [[3, 128, 0, 0]]);
  assert.deepEqual(ledger.footer.finalCounters.forwarded, restore.forwarded);
  assert.equal(ledger.footer.closed, true);
  assert.equal(ledger.footer.overflow, false);
  assert.deepEqual(ledger.invalidReasons, []);
  q.takeReady(0);
  q.close(0);
  assert.deepEqual(q.rateLedgerSnapshot(), ledger);
  ledger.operations[0][4][0] = 999;
  ledger.header.initialFIFO[0][0] = 999;
  assert.equal(q.rateLedgerSnapshot().operations[0][4][0], 2);
  assert.equal(q.rateLedgerSnapshot().header.initialFIFO[0][0], 1);
});

test('predicted waits, configured delay, underload and replenished delayed timers are not denial', () => {
  const q = queue({ delayMilliseconds: 1.25 });
  q.setRate(1024, 0);
  q.nextDelay(0.1); // empty advances are retained
  q.takeReady(0.2);
  q.enqueue(packet(), 0.25);
  assert.equal(q.takeReady(0.5), null);
  q.nextDelay(0.75);
  q.takeReady(1.5);
  q.enqueue(packet(), 1.5);
  q.takeReady(2.75);
  q.enqueue(packet(), 2.75);
  assert.ok(q.nextDelay(4) > 0); // prediction alone is insufficient
  q.takeReady(2000); // delayed timer replenishes before the ready-head branch
  q.setRate(null, 2000.5);
  assert.equal(q.rateLedgerSnapshot().denial, null);
  assert.equal(q.rateLedgerSnapshot().operations.length, 12);
});

test('all packet dispositions preserve received identity and FIFO including initial backlog', () => {
  const q = queue({ dropEvery: 3, maxQueuePackets: 2 });
  q.enqueue(packet(1), 0);
  q.setRate(1024, 0.5);
  q.enqueue(packet(2), 0.5);
  q.enqueue(packet(3), 0.5);
  q.enqueue(packet(4), 0.5);
  q.enqueue(Buffer.alloc(129), 0.5);
  q.takeReady(0.5);
  q.enqueue(packet(6), 0.5);
  q.enqueue(packet(7), 0.5);
  q.setRate(null, 1);
  assert.deepEqual(
    q
      .rateLedgerSnapshot()
      .operations.filter((r) => r[2] === 'enqueue')
      .map((r) => r[4]),
    [
      [2, 128, 'queued'],
      [3, 128, 'injectedDrop'],
      [4, 128, 'overflowDrop'],
      [5, 157, 'oversizeDrop'],
      [6, 128, 'injectedDrop'],
      [7, 128, 'queued'],
    ],
  );
  assert.deepEqual(q.rateLedgerSnapshot().footer.finalFIFO, [
    [2, 128, 0.5, 0.5],
    [7, 128, 0.5, 0.5],
  ]);
});

test('invalid finite history and close before restoration cannot qualify', () => {
  const initial = queue({ rateBitsPerSecond: 1024 });
  initial.enqueue(packet(), 0);
  initial.takeReady(0);
  initial.setRate(null, 0);
  initial.setRate(1024, 1);
  initial.setRate(null, 1);
  assert.ok(initial.rateLedgerSnapshot().invalidReasons.includes('initial-finite-rate'));
  const q = queue();
  q.setRate(1024, 0);
  q.enqueue(packet(), 0);
  q.close(1);
  assert.equal(q.rateLedgerSnapshot().footer.closed, false);
  assert.equal(q.rateLedgerSnapshot().footer.restoration, null);
  assert.ok(q.rateLedgerSnapshot().invalidReasons.includes('closed-before-restoration'));
  assert.deepEqual(q.rateLedgerSnapshot().footer.finalFIFO, []);
  assert.equal(q.rateLedgerSnapshot().footer.finalCounters.closeDiscard.packets, 1);
});

test('observer preserves queue output, exact counters and validation on fractional times', () => {
  const a = queue({ dropEvery: 5, delayMilliseconds: 0.25 });
  const b = new DatagramImpairmentQueue({
    ...configuration,
    dropEvery: 5,
    delayMilliseconds: 0.25,
  });
  const invoke = (name, ...args) => assert.deepEqual(a[name](...args), b[name](...args));
  invoke('enqueue', packet(1), 0);
  invoke('setRate', 3333, 0.1);
  for (let i = 0; i < 100; i++) {
    const at = 0.125 + i * 0.375;
    invoke('enqueue', packet(i), at);
    invoke('nextDelay', at + 0.125);
    invoke('takeReady', at + 0.25);
  }
  assert.throws(() => a.nextDelay(0), /monotonic/);
  assert.throws(() => b.nextDelay(0), /monotonic/);
  invoke('setRate', null, 100);
  while (a.snapshot().queue.packets) invoke('takeReady', 100);
  invoke('close', 100);
  assert.deepEqual(withoutObserverAnchors(a.snapshot()), b.snapshot());
});

test('fixed row budget is sticky and cannot alter delivery or grow the retained prefix', () => {
  const q = queue();
  q.setRate(1024, 0);
  for (let i = 0; i < 131073; i++) q.nextDelay(0);
  const before = q.rateLedgerSnapshot();
  assert.equal(before.operations.length, 131072);
  assert.equal(before.overflow, true);
  q.enqueue(packet(), 0);
  assert.deepEqual(q.takeReady(0), packet());
  q.setRate(null, 0);
  const after = q.rateLedgerSnapshot();
  assert.deepEqual(after.operations, before.operations);
  assert.equal(after.footer.overflow, true);
  assert.ok(Buffer.byteLength(JSON.stringify(after)) <= 32 * 1024 * 1024);
  q.close(0);
  assert.deepEqual(q.rateLedgerSnapshot(), after);
});

test('completed evidence is immutable while a second finite phase invalidates the envelope', () => {
  const q = queue();
  q.setRate(1024, 0);
  q.enqueue(packet(), 0);
  q.takeReady(0);
  q.setRate(null, 0);
  const before = q.rateLedgerSnapshot();
  q.setRate(1024, 1);
  q.enqueue(packet(), 1);
  q.takeReady(1);
  q.setRate(null, 1);
  const after = q.rateLedgerSnapshot();
  assert.deepEqual(after.header, before.header);
  assert.deepEqual(after.operations, before.operations);
  assert.deepEqual(after.footer, before.footer);
  assert.deepEqual(after.invalidReasons, ['second-finite-phase']);
  assert.deepEqual(before.invalidReasons, []);
});

test('finite rate change invalidates proof without losing its old-rate advance', () => {
  const q = queue();
  q.setRate(1024, 0);
  q.enqueue(packet(), 0);
  q.takeReady(0);
  q.setRate(2048, 0.125);
  q.setRate(null, 0.375);
  const ledger = q.rateLedgerSnapshot();
  assert.deepEqual(ledger.invalidReasons, ['finite-rate-change']);
  assert.deepEqual(ledger.operations.at(-2), [4, 0.125, 'setRate', 128.016, 2048]);
  assert.equal(ledger.footer.finalTokens, 128 + (0.125 * 1024) / 8000 + (0.25 * 2048) / 8000);
});

test('fractional repeated refills and tolerance-edge forwarding retain actual token values', () => {
  const q = queue();
  q.setRate(1024, 0);
  for (let i = 0; i < 3; i++) q.enqueue(packet(), 0);
  q.takeReady(0);
  q.takeReady(0);
  q.nextDelay(0.125);
  q.nextDelay(0.375);
  const justReady = 1000 - 5e-9;
  assert.deepEqual(q.takeReady(justReady), packet());
  q.takeReady(justReady);
  q.setRate(null, justReady);
  const ledger = q.rateLedgerSnapshot();
  assert.equal(ledger.denial, null);
  assert.equal(ledger.operations[5][3], 0.016);
  assert.equal(ledger.operations[6][3], 0.048);
  assert.equal(ledger.footer.finalTokens, 0);
  assert.deepEqual(ledger.operations.at(-2)[4], ['empty', null, null]);
});

function helper(limits) {
  const observer = new RateLedgerObserver(configuration, limits);
  const state = { counters: new DatagramImpairmentQueue(configuration).snapshot(), fifo: [] };
  // Helper boundary state contains precisely the queue's six cumulative counters.
  state.counters = Object.fromEntries(
    ['received', 'forwarded', 'injectedDrop', 'overflowDrop', 'oversizeDrop', 'closeDiscard'].map(
      (key) => [key, state.counters[key]],
    ),
  );
  observer.rateChange(
    null,
    { ...configuration, delayMilliseconds: 0, dropEvery: 0, rateBitsPerSecond: 1024 },
    1,
    0,
    256,
    state,
  );
  return { observer, state };
}

test('exact operation byte accounting and reduced byte exhaustion preserve retained prefix', () => {
  const row = [2, 0.125, 'takeReady', 255.99999999999997, ['delay', 1, 128]];
  const rowSize = Buffer.byteLength(JSON.stringify(row));
  const limits = {
    ...RATE_LEDGER_LIMITS,
    maxBytes: RATE_LEDGER_LIMITS.boundaryReserveBytes + 2 + rowSize,
  };
  const { observer, state } = helper(limits);
  observer.record(row);
  assert.equal(observer.snapshot().overflow, false);
  observer.record([3, 0.125, 'nextDelay', 255.99999999999997, 0.875]);
  const exhausted = observer.snapshot();
  assert.equal(exhausted.overflow, true);
  assert.deepEqual(exhausted.operations, [row]);
  observer.record([4, 1, 'restore', 256, null]);
  observer.finish(4, 1, 256, state, true);
  const closed = observer.snapshot();
  assert.deepEqual(closed.operations, [row]);
  assert.equal(closed.footer.overflow, true);
  assert.equal(closed.footer.operationCount, 1);
  assert.ok(Buffer.byteLength(JSON.stringify(closed)) <= limits.maxBytes);
  observer.record([5, 1, 'nextDelay', 256, null]);
  assert.deepEqual(observer.snapshot(), closed);
});

test('restoration itself exhausts the final row slot without affecting closure', () => {
  const { observer, state } = helper({ ...RATE_LEDGER_LIMITS, maxOperations: 1 });
  observer.record([2, 0, 'nextDelay', 256, null]);
  observer.rateChange(
    1024,
    { ...configuration, delayMilliseconds: 0, dropEvery: 0 },
    3,
    0,
    256,
    state,
  );
  const ledger = observer.snapshot();
  assert.equal(ledger.operations.length, 1);
  assert.equal(ledger.footer.closed, true);
  assert.equal(ledger.footer.overflow, true);
  assert.deepEqual(ledger.footer.restoration, { ordinal: 3, at: 0 });
});

test('observer helper refuses wider or unknown limits', () => {
  assert.throws(() => helper({ ...RATE_LEDGER_LIMITS, maxOperations: 131073 }));
  assert.throws(() => helper({ ...RATE_LEDGER_LIMITS, extra: 1 }));
});

test('export checks the entire serialized envelope and refuses an oversized proof', () => {
  const { observer, state } = helper({
    maxOperations: 1,
    maxBytes: 512,
    boundaryReserveBytes: 256,
  });
  observer.record([2, 0, 'nextDelay', 256, null]);
  observer.finish(3, 0, 256, state, true);
  assert.equal(observer.snapshot(), null);
  observer.record([4, 0, 'nextDelay', 256, null]);
  assert.equal(observer.snapshot(), null);
});

test('largest allowed FIFO boundaries fit the reserved export capacity', () => {
  const q = queue({ maxQueuePackets: 4096, maxQueueBytes: 16777216 });
  const at = 999999999999.125;
  for (let i = 0; i < 4096; i++) q.enqueue(Buffer.alloc(1), at);
  q.setRate(1024, at);
  q.setRate(null, at);
  const ledger = q.rateLedgerSnapshot();
  assert.equal(ledger.header.initialFIFO.length, 4096);
  assert.equal(ledger.footer.finalFIFO.length, 4096);
  assert.equal(ledger.overflow, false);
  assert.ok(Buffer.byteLength(JSON.stringify(ledger)) < RATE_LEDGER_LIMITS.boundaryReserveBytes);
});

test('ordinary finite-phase operations and snapshots never serialize the growing log', () => {
  const q = queue({ recordTimeline: true });
  q.setRate(1024, 0);
  const original = JSON.stringify;
  let calls = 0;
  JSON.stringify = (...args) => {
    calls++;
    return original(...args);
  };
  try {
    for (let i = 0; i < 20; i++) {
      q.enqueue(packet(i), i / 8);
      q.nextDelay(i / 8);
      q.takeReady(i / 8);
      q.snapshot();
    }
  } finally {
    JSON.stringify = original;
  }
  assert.equal(calls, 0);
  q.setRate(null, 3);
  assert.equal(q.rateLedgerSnapshot().footer.closed, true);
});

test('observer-only snapshot ordinal anchors complete phase operation count', () => {
  const disabled = new DatagramImpairmentQueue(configuration);
  assert.equal(Object.hasOwn(disabled.snapshot(), 'rateLedgerOperationOrdinal'), false);
  const q = queue();
  assert.equal(q.snapshot().rateLedgerOperationOrdinal, 0);
  q.nextDelay(0);
  q.setRate(1024, 0);
  const limit = q.snapshot();
  assert.equal(limit.rateLedgerOperationOrdinal, 2);
  q.nextDelay(0); // Empty call still advances the token clock and ordinal.
  q.takeReady(0);
  q.enqueue(packet(), 0);
  assert.equal(q.snapshot().rateLedgerOperationOrdinal, 5);
  assert.equal(q.snapshot().rateLedgerOperationOrdinal, 5);
  assert.throws(() => q.nextDelay(-1), /monotonic/);
  assert.equal(q.snapshot().rateLedgerOperationOrdinal, 5);
  q.setRate(null, 0);
  const restoration = q.snapshot();
  const ledger = q.rateLedgerSnapshot();
  assert.equal(ledger.header.limit.ordinal, limit.rateLedgerOperationOrdinal);
  assert.equal(ledger.footer.restoration.ordinal, restoration.rateLedgerOperationOrdinal);
  assert.equal(
    ledger.operations.length,
    restoration.rateLedgerOperationOrdinal - limit.rateLedgerOperationOrdinal,
  );
  q.takeReady(0);
  q.close(0);
  assert.equal(q.snapshot().rateLedgerOperationOrdinal, 8);
  assert.equal(restoration.rateLedgerOperationOrdinal, 6);
  assert.deepEqual(q.rateLedgerSnapshot(), ledger);
});

test('snapshot first-denial anchor records only actual refusal and owns its small witness', () => {
  const disabled = new DatagramImpairmentQueue(configuration);
  assert.equal(Object.hasOwn(disabled.snapshot(), 'rateLedgerFirstDenial'), false);
  const q = queue();
  assert.equal(q.snapshot().rateLedgerFirstDenial, null);
  q.setRate(1024, 0);
  const limited = q.snapshot();
  for (let i = 0; i < 3; i++) q.enqueue(packet(i), 0);
  q.takeReady(0);
  q.takeReady(0);
  assert.equal(q.nextDelay(0), 1000);
  const predicted = q.snapshot();
  assert.equal(predicted.rateLedgerFirstDenial, null);
  assert.equal(q.takeReady(0), null);
  const denied = q.snapshot();
  assert.deepEqual(denied.rateLedgerFirstDenial, {
    ordinal: 8,
    at: 0,
    id: 3,
    wireBytes: 128,
    tokens: 0,
  });
  assert.deepEqual(denied.rateLedgerFirstDenial, q.rateLedgerSnapshot().denial);
  assert.equal(limited.rateLedgerFirstDenial, null);
  assert.equal(predicted.rateLedgerFirstDenial, null);
  q.takeReady(0.125);
  q.setRate(null, 0.125);
  const restored = q.snapshot();
  assert.deepEqual(restored.rateLedgerFirstDenial, denied.rateLedgerFirstDenial);
  denied.rateLedgerFirstDenial.id = 999;
  assert.equal(q.snapshot().rateLedgerFirstDenial.id, 3);
  q.takeReady(0.125);
  q.close(0.125);
  assert.deepEqual(q.snapshot().rateLedgerFirstDenial, restored.rateLedgerFirstDenial);
});
