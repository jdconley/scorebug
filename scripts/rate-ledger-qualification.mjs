import assert from 'node:assert/strict';
import { qualifyDatagramTimeline } from './datagram-timeline-qualification.mjs';

const kinds = [
  'received',
  'forwarded',
  'injectedDrop',
  'overflowDrop',
  'oversizeDrop',
  'closeDiscard',
];
const configKeys = [
  'rateBitsPerSecond',
  'delayMilliseconds',
  'dropEvery',
  'maxDatagramBytes',
  'burstBytes',
  'maxQueuePackets',
  'maxQueueBytes',
];
const limits = { maxOperations: 131072, maxBytes: 33554432, boundaryReserveBytes: 2097152 };
const safe = (n) => Number.isSafeInteger(n) && n >= 0;
const time = (n) => Number.isFinite(n) && n >= 0 && n <= 1e12;
const emptyCounters = () =>
  Object.fromEntries(kinds.map((kind) => [kind, { packets: 0, wireBytes: 0 }]));
function keys(value, expected, label) {
  assert(value && typeof value === 'object' && !Array.isArray(value), `Invalid ${label}`);
  assert.deepEqual(
    Reflect.ownKeys(value).sort((a, b) => String(a).localeCompare(String(b))),
    [...expected].sort((a, b) => a.localeCompare(b)),
    `Unknown/missing ${label} fields`,
  );
}
function tuple(value, length) {
  assert(Array.isArray(value) && value.length === length, 'Invalid operation tuple');
  assert.deepEqual(Reflect.ownKeys(value), [...Array(length).keys()].map(String).concat('length'));
}
function configuration(c) {
  keys(c, configKeys, 'configuration');
  assert(
    Number.isFinite(c.rateBitsPerSecond) && c.rateBitsPerSecond >= 1 && c.rateBitsPerSecond <= 1e12,
  );
  assert(
    Number.isFinite(c.delayMilliseconds) &&
      c.delayMilliseconds >= 0 &&
      c.delayMilliseconds <= 60000,
  );
  for (const [key, min, max] of [
    ['dropEvery', 0, 1e9],
    ['maxDatagramBytes', 1, 65507],
    ['burstBytes', c.maxDatagramBytes + 28, 1048576],
    ['maxQueuePackets', 1, 4096],
    ['maxQueueBytes', c.maxDatagramBytes + 28, 16777216],
  ])
    assert(safe(c[key]) && c[key] >= min && c[key] <= max, `Invalid ${key}`);
}
function counters(value) {
  keys(value, kinds, 'counters');
  for (const kind of kinds) {
    keys(value[kind], ['packets', 'wireBytes'], 'counter');
    assert(safe(value[kind].packets) && safe(value[kind].wireBytes));
    assert.equal(value[kind].packets === 0, value[kind].wireBytes === 0);
    assert(value[kind].wireBytes >= value[kind].packets * 28);
  }
}
function boundary(value) {
  keys(value, ['ordinal', 'at'], 'boundary');
  assert(safe(value.ordinal) && value.ordinal > 0 && time(value.at));
}
function checkFIFO(fifo, counts, c, at) {
  assert(Array.isArray(fifo) && fifo.length <= c.maxQueuePackets);
  let id = 0,
    enqueuedAt = 0,
    wireBytes = 0;
  for (const row of fifo) {
    tuple(row, 4);
    assert(
      safe(row[0]) && row[0] > id && row[0] <= counts.received.packets,
      'Invalid FIFO identity',
    );
    assert(safe(row[1]) && row[1] >= 28 && row[1] <= c.maxDatagramBytes + 28);
    assert(time(row[2]) && row[2] >= enqueuedAt && row[2] <= at);
    assert.equal(row[3], row[2] + c.delayMilliseconds, 'Invalid FIFO readiness');
    assert(!c.dropEvery || row[0] % c.dropEvery !== 0, 'Injected drop cannot remain queued');
    id = row[0];
    enqueuedAt = row[2];
    wireBytes += row[1];
  }
  assert(wireBytes <= c.maxQueueBytes);
  for (const [unit, actual] of [
    ['packets', fifo.length],
    ['wireBytes', wireBytes],
  ]) {
    const balance = kinds.reduce(
      (n, kind) => n + (kind === 'received' ? 1 : -1) * counts[kind][unit],
      0,
    );
    assert.equal(balance, actual, 'FIFO/counter conservation mismatch');
  }
  return wireBytes;
}
function checkPhase(phase, at, c, count, fifo) {
  keys(phase, ['appliedAt', 'queue'], 'phase');
  assert.equal(phase.appliedAt, at);
  assert.deepEqual(phase.queue.configuration, c, 'Phase configuration mismatch');
  assert.equal(phase.queue.closed, false);
  assert.equal(phase.queue.timeline?.lastObservedAt, at, 'Phase snapshot is not at boundary');
  assert.equal(qualifyDatagramTimeline(phase.queue).complete, true, 'Incomplete phase timeline');
  for (const kind of kinds)
    assert.deepEqual(phase.queue[kind], count[kind], 'Phase counter mismatch');
  assert.equal(phase.queue.queue.packets, fifo.length);
  assert.equal(
    phase.queue.queue.wireBytes,
    fifo.reduce((n, row) => n + row[1], 0),
  );
}

/** Independently replay an explicit laboratory rate audit. This proves only that
 * a ready FIFO head was actually denied by the finite token bucket. Callers must
 * separately qualify transport closure, native causal pressure, media and recovery.
 * The trusted configuration must come from the selected experiment, not the log.
 */
export function qualifyRateLedger(input, options) {
  keys(options, ['configuration'], 'options');
  const c = options.configuration;
  configuration(c);
  keys(input, ['ledger', 'limited', 'restored'], 'input');
  const { ledger: l, limited, restored } = input;
  keys(
    l,
    ['format', 'limits', 'header', 'operations', 'denial', 'footer', 'overflow', 'invalidReasons'],
    'ledger',
  );
  assert.equal(l.format, 'rate-ledger-v1');
  assert.deepEqual(l.limits, limits);
  assert.equal(l.overflow, false);
  assert.deepEqual(l.invalidReasons, []);
  assert(
    Array.isArray(l.operations) &&
      l.operations.length > 0 &&
      l.operations.length <= limits.maxOperations,
  );
  assert(Buffer.byteLength(JSON.stringify(l)) <= limits.maxBytes, 'Ledger byte limit exceeded');
  const h = l.header,
    f = l.footer;
  keys(
    h,
    [
      'configuration',
      'constructedRate',
      'initialFinitePhaseCount',
      'limit',
      'initialTokens',
      'initialCounters',
      'initialFIFO',
    ],
    'header',
  );
  keys(
    f,
    [
      'restoration',
      'finalFIFO',
      'finalCounters',
      'finalTokens',
      'operationCount',
      'closed',
      'overflow',
    ],
    'footer',
  );
  assert.deepEqual(h.configuration, c);
  assert.equal(h.constructedRate, null, 'Initially finite queue cannot qualify');
  assert.equal(h.initialFinitePhaseCount, 0, 'Prior finite phase cannot qualify');
  assert.equal(h.initialTokens, c.burstBytes);
  boundary(h.limit);
  boundary(f.restoration);
  assert.equal(
    limited?.queue?.rateLedgerOperationOrdinal,
    h.limit.ordinal,
    'Limit boundary operation ordinal mismatch',
  );
  assert.equal(
    restored?.queue?.rateLedgerOperationOrdinal,
    f.restoration.ordinal,
    'Restoration boundary operation ordinal mismatch',
  );
  assert.equal(f.closed, true);
  assert.equal(f.overflow, false);
  assert.equal(f.operationCount, l.operations.length);
  assert.equal(f.restoration.ordinal, h.limit.ordinal + l.operations.length);
  assert(f.restoration.at >= h.limit.at);
  counters(h.initialCounters);
  counters(f.finalCounters);
  let bytes = checkFIFO(h.initialFIFO, h.initialCounters, c, h.limit.at);
  checkFIFO(f.finalFIFO, f.finalCounters, c, f.restoration.at);
  checkPhase(limited, h.limit.at, c, h.initialCounters, h.initialFIFO);
  checkPhase(
    restored,
    f.restoration.at,
    { ...c, rateBitsPerSecond: null },
    f.finalCounters,
    f.finalFIFO,
  );
  assert.equal(limited.queue.timeline.firstObservedAt, restored.queue.timeline.firstObservedAt);
  const fifo = structuredClone(h.initialFIFO),
    count = structuredClone(h.initialCounters),
    bins = new Map();
  let tokens = h.initialTokens,
    previousTime = h.limit.at,
    denial = null;
  function account(kind, wireBytes, at) {
    const start = Math.floor(at / 100) * 100;
    if (!bins.has(start)) bins.set(start, emptyCounters());
    for (const target of [count, bins.get(start)]) {
      target[kind].packets++;
      target[kind].wireBytes += wireBytes;
      assert(safe(target[kind].packets) && safe(target[kind].wireBytes));
    }
  }
  for (let i = 0; i < l.operations.length; i++) {
    const row = l.operations[i];
    tuple(row, 5);
    const [ordinal, at, kind, balance, detail] = row;
    assert.equal(ordinal, h.limit.ordinal + i + 1, 'Missing/reordered operation');
    assert(time(at) && at >= previousTime && at <= f.restoration.at, 'Invalid operation time');
    tokens = Math.min(c.burstBytes, tokens + ((at - previousTime) * c.rateBitsPerSecond) / 8000);
    previousTime = at;
    assert.equal(balance, tokens, 'Token advance mismatch');
    const head = fifo[0];
    if (kind === 'enqueue') {
      tuple(detail, 3);
      const [id, wireBytes, disposition] = detail;
      assert.equal(id, count.received.packets + 1, 'Received identity mismatch');
      assert(safe(wireBytes) && wireBytes >= 28);
      account('received', wireBytes, at);
      const expected =
        wireBytes > c.maxDatagramBytes + 28
          ? 'oversizeDrop'
          : c.dropEvery && id % c.dropEvery === 0
            ? 'injectedDrop'
            : fifo.length === c.maxQueuePackets || bytes + wireBytes > c.maxQueueBytes
              ? 'overflowDrop'
              : 'queued';
      assert.equal(disposition, expected, 'Receive disposition mismatch');
      if (expected === 'queued') {
        fifo.push([id, wireBytes, at, at + c.delayMilliseconds]);
        bytes += wireBytes;
      } else account(expected, wireBytes, at);
    } else if (kind === 'takeReady') {
      tuple(detail, 3);
      const expected = !head
        ? 'empty'
        : head[3] > at
          ? 'delay'
          : tokens + 1e-9 < head[1]
            ? 'tokenDenied'
            : 'forwarded';
      assert.deepEqual(
        detail,
        [expected, head?.[0] ?? null, head?.[1] ?? null],
        'FIFO head disposition mismatch',
      );
      if (expected === 'tokenDenied')
        denial ??= { ordinal, at, id: head[0], wireBytes: head[1], tokens };
      if (expected === 'forwarded') {
        tokens = Math.max(0, tokens - head[1]);
        bytes -= head[1];
        fifo.shift();
        account('forwarded', head[1], at);
      }
    } else if (kind === 'nextDelay') {
      assert.equal(
        detail,
        head ? Math.max(0, head[3] - at, ((head[1] - tokens) * 8000) / c.rateBitsPerSecond) : null,
        'Predicted wait mismatch',
      );
    } else {
      assert.equal(kind, 'restore', 'Unsupported phase operation');
      assert.equal(detail, null);
      assert.equal(i, l.operations.length - 1, 'Restoration must close the phase');
      assert.deepEqual({ ordinal, at }, f.restoration);
    }
  }
  assert.equal(l.operations.at(-1)[2], 'restore', 'Missing terminal restoration');
  assert.deepEqual(fifo, f.finalFIFO, 'Final FIFO mismatch');
  assert.deepEqual(count, f.finalCounters, 'Final counters mismatch');
  assert.equal(tokens, f.finalTokens, 'Final tokens mismatch');
  assert(denial !== null, 'No actual ready-head token denial');
  assert.deepEqual(l.denial, denial, 'First actual denial mismatch');
  assert.equal(limited.queue.rateLedgerFirstDenial, null, 'Unexpected pre-limit denial');
  assert.deepEqual(
    restored.queue.rateLedgerFirstDenial,
    denial,
    'Independent phase snapshot denial mismatch',
  );
  const before = new Map(limited.queue.timeline.windows.map((w) => [w.start, w]));
  const after = new Map(restored.queue.timeline.windows.map((w) => [w.start, w]));
  for (const start of new Set([...before.keys(), ...after.keys(), ...bins.keys()])) {
    if (start + 100 <= h.limit.at && before.has(start))
      assert.deepEqual(after.get(start), before.get(start), 'Changed pre-limit timeline prefix');
    for (const kind of kinds)
      for (const unit of ['packets', 'wireBytes']) {
        const delta =
          (after.get(start)?.[kind][unit] ?? 0) - (before.get(start)?.[kind][unit] ?? 0);
        assert.equal(
          delta,
          bins.get(start)?.[kind][unit] ?? 0,
          'Phase timeline disposition mismatch',
        );
      }
  }
  return {
    rateBoundQualified: true,
    adaptationQualified: false,
    recoveryQualified: false,
    productionQualified: false,
    operationCount: l.operations.length,
    firstDenial: structuredClone(denial),
    scope:
      'Observed finite-phase FIFO/token replay only; no native adaptation, media, recovery or production authority.',
  };
}
