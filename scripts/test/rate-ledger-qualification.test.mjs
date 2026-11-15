import test from 'node:test';
import assert from 'node:assert/strict';
import { DatagramImpairmentQueue } from '../udp-impairment.mjs';
const module = await import('../rate-ledger-qualification.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});

function fixture() {
  const q = new DatagramImpairmentQueue({
    delayMilliseconds: 30,
    dropEvery: 5,
    maxDatagramBytes: 100,
    burstBytes: 128,
    maxQueuePackets: 4,
    maxQueueBytes: 256,
    recordTimeline: true,
    recordRateLedger: true,
  });
  q.enqueue(Buffer.alloc(100), 0);
  q.enqueue(Buffer.alloc(100), 1);
  q.setRate(1024, 30);
  const limited = { appliedAt: 30, queue: q.snapshot() };
  q.takeReady(30);
  q.takeReady(30); // configured delay, not token denial
  q.nextDelay(30);
  q.takeReady(31); // first real ready-head denial
  q.enqueue(Buffer.alloc(100), 31);
  q.enqueue(Buffer.alloc(100), 31); // overflow
  q.enqueue(Buffer.alloc(100), 31); // injected loss takes precedence
  q.enqueue(Buffer.alloc(101), 31); // oversize
  q.nextDelay(531);
  q.takeReady(1031);
  q.setRate(null, 1031);
  const restored = { appliedAt: 1031, queue: q.snapshot() };
  q.takeReady(1031); // must not leak into restoration boundary
  q.close(1031);
  return {
    input: { ledger: q.rateLedgerSnapshot(), limited, restored },
    options: { configuration: limited.queue.configuration },
    finalQueue: q.snapshot(),
  };
}
function qualify(f = fixture()) {
  return module.qualifyRateLedger(f.input, f.options);
}

test('reconstructs observed FIFO, exact token advances, dispositions and partial boundary bins', () => {
  assert.equal(typeof module.qualifyRateLedger, 'function');
  const result = qualify();
  assert.equal(result.rateBoundQualified, true);
  assert.equal(result.adaptationQualified, false);
  assert.equal(result.recoveryQualified, false);
  assert.equal(result.productionQualified, false);
  assert.equal(result.operationCount, 11);
  assert.deepEqual(result.firstDenial, fixture().input.ledger.denial);
});

for (const [name, mutate] of Object.entries({
  'omitted operation': (f) => f.input.ledger.operations.splice(2, 1),
  'extra operation': (f) => f.input.ledger.operations.splice(2, 0, f.input.ledger.operations[2]),
  'reordered operations': (f) => f.input.ledger.operations.reverse(),
  'changed floating-point prefix': (f) => {
    f.input.ledger.operations[8][3] += 1e-12;
  },
  'forged denial tokens': (f) => {
    f.input.ledger.denial.tokens += 1;
  },
  'forged denial identity': (f) => {
    f.input.ledger.denial.id++;
  },
  'predicted wait as denial': (f) => {
    f.input.ledger.denial.ordinal--;
  },
  'missing denial': (f) => {
    f.input.ledger.denial = null;
  },
  'missing independent denial anchor': (f) => {
    delete f.input.restored.queue.rateLedgerFirstDenial;
  },
  'changed independent denial anchor': (f) => {
    f.input.restored.queue.rateLedgerFirstDenial.ordinal++;
  },
  'missing independent operation anchor': (f) => {
    delete f.input.limited.queue.rateLedgerOperationOrdinal;
  },
  'wrong forward head': (f) => {
    f.input.ledger.operations[0][4][1]++;
  },
  'wrong receive wire cost': (f) => {
    f.input.ledger.operations[4][4][1]++;
  },
  'wrong drop precedence': (f) => {
    f.input.ledger.operations[6][4][2] = 'overflowDrop';
  },
  'premature initial readiness': (f) => {
    f.input.ledger.header.initialFIFO[1][3] = 30;
  },
  'foreign initial identity': (f) => {
    f.input.ledger.header.initialFIFO[0][0] = 999;
  },
  'missing initial backlog': (f) => {
    f.input.ledger.header.initialFIFO.pop();
  },
  'initial finite construction': (f) => {
    f.input.ledger.header.constructedRate = 1024;
  },
  'prior depleted phase': (f) => {
    f.input.ledger.header.initialFinitePhaseCount = 1;
  },
  'depleted initial tokens': (f) => {
    f.input.ledger.header.initialTokens--;
  },
  'unknown finite history': (f) => {
    f.input.ledger.invalidReasons.push('second-finite-phase');
  },
  'changed configuration': (f) => {
    f.input.ledger.header.configuration.burstBytes++;
  },
  'missing terminal evidence': (f) => {
    f.input.ledger.footer = null;
  },
  'missing restoration': (f) => {
    f.input.ledger.footer.restoration = null;
  },
  'unclosed phase': (f) => {
    f.input.ledger.footer.closed = false;
  },
  'overflow envelope': (f) => {
    f.input.ledger.overflow = true;
  },
  'overflow footer': (f) => {
    f.input.ledger.footer.overflow = true;
  },
  'wrong operation total': (f) => {
    f.input.ledger.footer.operationCount++;
  },
  'forged footer tokens': (f) => {
    f.input.ledger.footer.finalTokens++;
  },
  'forged final FIFO': (f) => {
    f.input.ledger.footer.finalFIFO[0][0]++;
  },
  'forged final counter': (f) => {
    f.input.ledger.footer.finalCounters.received.packets++;
  },
  'wrong phase time': (f) => {
    f.input.restored.appliedAt++;
  },
  'final snapshot instead of restoration': (f) => {
    f.input.restored.queue = f.finalQueue;
  },
  'unknown envelope field': (f) => {
    f.input.ledger.approved = true;
  },
  'altered limits': (f) => {
    f.input.ledger.limits.maxOperations++;
  },
  'extra options': (f) => {
    f.options.allowIncomplete = true;
  },
  'symbol options': (f) => {
    f.options[Symbol('bypass')] = true;
  },
  'hidden options': (f) => {
    Object.defineProperty(f.options, 'bypass', { value: true });
  },
  'invalid configuration range': (f) => {
    for (const c of [
      f.options.configuration,
      f.input.ledger.header.configuration,
      f.input.restored.queue.configuration,
    ])
      c.dropEvery = -1;
  },
  'partial first-bin redistribution': (f) => {
    const windows = f.input.restored.queue.timeline.windows;
    windows[0].forwarded.wireBytes--;
    windows.at(-1).forwarded.wireBytes++;
  },
})) {
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
}

test('requires explicit trusted configuration rather than accepting header self-authorization', () => {
  const f = fixture();
  assert.throws(() => module.qualifyRateLedger(f.input));
  assert.throws(() => module.qualifyRateLedger(f.input, null));
  assert.throws(() => module.qualifyRateLedger(f.input, []));
});

function compactFixture(perform) {
  const q = new DatagramImpairmentQueue({
    maxDatagramBytes: 100,
    burstBytes: 128,
    recordTimeline: true,
    recordRateLedger: true,
  });
  q.setRate(1024, 0);
  const limited = { appliedAt: 0, queue: q.snapshot() };
  const end = perform(q);
  q.setRate(null, end);
  return {
    input: {
      ledger: q.rateLedgerSnapshot(),
      limited,
      restored: { appliedAt: end, queue: q.snapshot() },
    },
    options: { configuration: limited.queue.configuration },
  };
}
test('same-time denial followed immediately by restoration qualifies only rate binding', () => {
  qualify(
    compactFixture((q) => {
      q.enqueue(Buffer.alloc(100), 0);
      q.enqueue(Buffer.alloc(100), 0);
      q.takeReady(0);
      q.takeReady(0);
      return 0;
    }),
  );
});
test('underload and host-delayed refill without actual denial cannot qualify', () => {
  for (const delay of [1000, 2000]) {
    const f = compactFixture((q) => {
      q.enqueue(Buffer.alloc(100), 0);
      q.takeReady(0);
      q.enqueue(Buffer.alloc(100), 0);
      q.nextDelay(0); // predicted deficit alone is not evidence
      q.takeReady(delay);
      return delay;
    });
    assert.throws(() => qualify(f), /denial/i);
  }
});
test('replays empty advances and fractional tolerance-edge forward before later denial', () => {
  const f = compactFixture((q) => {
    q.nextDelay(0.125);
    q.takeReady(0.375);
    q.enqueue(Buffer.alloc(100), 0.5);
    q.enqueue(Buffer.alloc(100), 0.5);
    q.enqueue(Buffer.alloc(100), 0.5);
    q.takeReady(0.5);
    q.nextDelay(0.625);
    q.nextDelay(0.875);
    q.takeReady(1000.5 - 5e-9);
    q.takeReady(1000.5 - 5e-9);
    return 1000.5 - 5e-9;
  });
  qualify(f);
  f.input.ledger.operations.splice(0, 1);
  assert.throws(() => qualify(f));
});

test('immutable boundary ordinals reject removed no-op advances even if the log is renumbered', () => {
  const f = compactFixture((q) => {
    q.nextDelay(0);
    q.enqueue(Buffer.alloc(100), 0);
    q.enqueue(Buffer.alloc(100), 0);
    q.takeReady(0);
    q.takeReady(0);
    return 0;
  });
  qualify(f);
  f.input.ledger.operations.shift();
  for (const row of f.input.ledger.operations) row[0]--;
  f.input.ledger.denial.ordinal--;
  f.input.ledger.footer.restoration.ordinal--;
  f.input.ledger.footer.operationCount--;
  assert.throws(() => qualify(f), /ordinal/i);
});

test('independent denial witness rejects a prediction rewritten as an actual denial', () => {
  const f = compactFixture((q) => {
    q.enqueue(Buffer.alloc(100), 0);
    q.enqueue(Buffer.alloc(100), 0);
    q.takeReady(0);
    q.nextDelay(0); // never actually calls the denying branch
    return 0;
  });
  assert.throws(() => qualify(f), /denial/i);
  const row = f.input.ledger.operations.find((row) => row[2] === 'nextDelay');
  row[2] = 'takeReady';
  row[4] = ['tokenDenied', 2, 128];
  f.input.ledger.denial = { ordinal: row[0], at: row[1], id: 2, wireBytes: 128, tokens: row[3] };
  assert.throws(() => qualify(f), /denial/i);
});
