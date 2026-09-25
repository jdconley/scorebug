import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  assertRecoveryProbeObservation,
  assertRecoveryProbeHistory,
  assertRecoveryProbeAcceptanceHistory,
} from '../recovery-probe-observation.mjs';

const policy = 'recovery-budget-v1';
function entry(at = 101) {
  return {
    observedAt: at + 1,
    sample: {
      id: 'aabbccdd-1234-1234-1234-123456789abc',
      publishingGeneration: '7',
      stage: 3,
      startedAt: 100,
      policy,
      recoveryObservation: {
        checkedAt: at,
        sampledAt: at,
        elapsedMilliseconds: String(at * 1000),
        sentBytes: String(at * 1000),
        retransmittedBytes: String(at * 10),
        droppedPackets: 2,
        rttMilliseconds: 65,
        senderBufferMilliseconds: 67,
        senderDeliveryDelayMilliseconds: 400,
      },
    },
  };
}
const validate = (e) =>
  assertRecoveryProbeObservation(e.sample, { observedAt: e.observedAt, policy });

test('recovery raw check allows recovered bytes and historical successful observations without changing inputs', () => {
  const e = entry(),
    before = structuredClone(e);
  validate(e);
  assert.deepEqual(e, before);
  for (const delay of [120, 400, 4000]) {
    const next = entry(),
      r = next.sample.recoveryObservation;
    r.senderDeliveryDelayMilliseconds = delay;
    r.rttMilliseconds = Math.min(500, delay / 4);
    r.senderBufferMilliseconds = Math.min(500, delay / 2);
    validate(next);
    r.rttMilliseconds += 0.01;
    assert.throws(() => validate(next));
    r.rttMilliseconds -= 0.01;
    r.senderBufferMilliseconds += 1;
    assert.throws(() => validate(next));
  }
});

test('legacy policy rejects recovery fields and unknown policies fail closed', () => {
  const e = entry();
  delete e.sample.policy;
  delete e.sample.recoveryObservation;
  assertRecoveryProbeObservation(e.sample, { observedAt: e.observedAt });
  for (const key of ['policy', 'recoveryObservation']) {
    const changed = structuredClone(e);
    changed.sample[key] = null;
    assert.throws(() =>
      assertRecoveryProbeObservation(changed.sample, { observedAt: e.observedAt }),
    );
  }
  assert.throws(() =>
    assertRecoveryProbeObservation(e.sample, { observedAt: e.observedAt, policy: 'future-v1' }),
  );
  assert.throws(() => validate(e));
});

const invalid = {
  missing: (e) => delete e.sample.recoveryObservation,
  null: (e) => (e.sample.recoveryObservation = null),
  wrongPolicy: (e) => (e.sample.policy = 'local-zero-loss-v1'),
  missingStage: (e) => delete e.sample.stage,
  wrongStage: (e) => (e.sample.stage = 0),
  futureCheck: (e) => (e.sample.recoveryObservation.checkedAt = e.observedAt + 1),
  checkBeforeStage: (e) => (e.sample.startedAt = 101.1),
  stale: (e) => (e.sample.recoveryObservation.sampledAt -= 0.101),
  futureCollection: (e) => (e.sample.recoveryObservation.sampledAt += 0.01),
  unknownField: (e) => (e.sample.recoveryObservation.extra = 1),
};
for (const [field, values] of Object.entries({
  checkedAt: [NaN, Infinity, -1, '101'],
  sampledAt: [NaN, Infinity, -1, '101'],
  elapsedMilliseconds: ['-1', '01', 101000, '9223372036854775808', '1e5'],
  sentBytes: ['-1', '01', 101000, '18446744073709551616', '1'.repeat(100)],
  retransmittedBytes: ['-1', '01', 1010, '101001'],
  droppedPackets: [-1, 1.5, 2147483648, '0', null],
  rttMilliseconds: [-1, NaN, Infinity, 100.001, '65', null],
  senderBufferMilliseconds: [-1, 1.5, 201, 2147483648, '67', null],
  senderDeliveryDelayMilliseconds: [0, -1, 1.5, 2147483648, '400', null],
})) {
  for (const [index, value] of values.entries())
    invalid[`${field}-${index}`] = (e) => (e.sample.recoveryObservation[field] = value);
  invalid[`missing-${field}`] = (e) => delete e.sample.recoveryObservation[field];
}
for (const [name, change] of Object.entries(invalid))
  test(`reject malformed recovery observation: ${name}`, () => {
    const e = entry();
    change(e);
    assert.throws(() => validate(e));
  });

test('history orders successful check times independently of async read completion', () => {
  const a = entry(101),
    b = entry(102),
    c = structuredClone(b);
  a.observedAt = 104;
  b.observedAt = 103;
  c.observedAt = 105;
  c.sample.recoveryObservation.checkedAt += 0.05; // Same native collection checked again.
  const entries = [c, a, b],
    before = structuredClone(entries);
  assertRecoveryProbeHistory(entries, { policy });
  assert.deepEqual(entries, before);
  const nextOwner = entry(103);
  nextOwner.sample.id = 'bbbbcccc-1234-1234-1234-123456789abc';
  nextOwner.sample.stage = 4;
  nextOwner.sample.recoveryObservation.droppedPackets = 3;
  assertRecoveryProbeHistory([...entries, nextOwner], { policy });
});

for (const [name, change] of Object.entries({
  elapsedRegression: (e) => (e.sample.recoveryObservation.elapsedMilliseconds = '100999'),
  sentRegression: (e) => (e.sample.recoveryObservation.sentBytes = '100999'),
  retryRegression: (e) => (e.sample.recoveryObservation.retransmittedBytes = '1009'),
  dropGrowth: (e) => (e.sample.recoveryObservation.droppedPackets = 3),
  dropRegression: (e) => (e.sample.recoveryObservation.droppedPackets = 1),
  excessRetryDelta: (e) => (e.sample.recoveryObservation.retransmittedBytes = '2011'),
  samplingRegression: (e) => {
    e.sample.recoveryObservation.sampledAt = 100.99;
    e.sample.recoveryObservation.checkedAt = 101.05;
  },
  cachedMutation: (e) => {
    e.sample.recoveryObservation.sampledAt = 101;
    e.sample.recoveryObservation.checkedAt = 101.05;
  },
  equalCheckMutation: (e) => {
    e.sample.recoveryObservation.sampledAt = 101;
    e.sample.recoveryObservation.checkedAt = 101;
  },
  stageMutation: (e) => (e.sample.stage = 2),
  startMutation: (e) => (e.sample.startedAt = 99),
  generationMutation: (e) => (e.sample.publishingGeneration = '8'),
}))
  test(`history rejects incompatible successful checks: ${name}`, () => {
    const a = entry(101),
      b = entry(102);
    change(b);
    assert.throws(() => assertRecoveryProbeHistory([b, a], { policy }));
  });

test('bounded history accepts exact duplicate checks and rejects missing history', () => {
  assertRecoveryProbeHistory([entry(), entry()], { policy });
  assert.throws(() => assertRecoveryProbeHistory([], { policy }));
  assert.throws(() => assertRecoveryProbeHistory(Array(4097).fill(entry()), { policy }));
  const e = entry();
  e.sample.id = 'not-an-id';
  assert.throws(() => assertRecoveryProbeHistory([e], { policy }));
});

for (const field of [
  'rttMilliseconds',
  'senderBufferMilliseconds',
  'senderDeliveryDelayMilliseconds',
])
  test(`cached collection rejects an independently valid changed ${field}`, () => {
    const a = entry(),
      b = structuredClone(a);
    b.sample.recoveryObservation.checkedAt += 0.05;
    b.sample.recoveryObservation[field] += 1;
    validate(b); // Each check is valid in isolation; the cached collection is inconsistent.
    assert.throws(() => assertRecoveryProbeHistory([a, b], { policy }));
  });

function acceptedEntry(at = 101, bytes = '1316') {
  const e = entry(at);
  Object.assign(e.sample, {
    acceptedPayloadBytes: bytes,
    lastAcceptedAt: bytes === '0' ? null : at + 0.01,
    bitRate: 500000,
    reason: null,
  });
  return e;
}
test('acceptance history joins unordered intermediate reads and allows unchanged terminal snapshots', () => {
  const initial = acceptedEntry(100, '0'),
    first = acceptedEntry(),
    second = acceptedEntry(102, '2632');
  const terminal = structuredClone(second);
  terminal.sample.reason = 'cancelled';
  terminal.observedAt += 10;
  const entries = [terminal, first, second, initial],
    before = structuredClone(entries);
  assertRecoveryProbeAcceptanceHistory(entries, { policy });
  assert.deepEqual(entries, before);
});
for (const [name, mutate] of Object.entries({
  frozenCheck: (a, b) =>
    (b.sample.recoveryObservation = structuredClone(a.sample.recoveryObservation)),
  checkAfterAcceptance: (a, b) => (b.sample.lastAcceptedAt = 101.999),
  sameBytesNewCheck: (a, b) => {
    b.sample.acceptedPayloadBytes = a.sample.acceptedPayloadBytes;
    b.sample.lastAcceptedAt = a.sample.lastAcceptedAt;
  },
  counterTooLarge: (a, b) => (b.sample.acceptedPayloadBytes = '18446744073709551615'),
  counterUnaligned: (a, b) => (b.sample.acceptedPayloadBytes = '2633'),
  counterNoncanonical: (a, b) => (b.sample.acceptedPayloadBytes = '02632'),
  missingAcceptanceTime: (a, b) => (b.sample.lastAcceptedAt = null),
  futureAcceptanceTime: (a, b) => (b.sample.lastAcceptedAt = b.observedAt + 1),
  unsupportedReason: (a, b) => (b.sample.reason = 'transportFailed'),
  changedRate: (a, b) => (b.sample.bitRate = 1000000),
  impossiblePacing: (a, b) => {
    a.sample.bitRate = 1;
    b.sample.bitRate = 1;
  },
  previousSendUnfinished: (a, b) => (a.sample.lastAcceptedAt = 102.001),
  emptyCheckRefreshed: (a, b) => {
    a.sample.acceptedPayloadBytes = '0';
    a.sample.lastAcceptedAt = null;
  },
}))
  test(`acceptance history rejects ${name}`, () => {
    const a = acceptedEntry(),
      b = acceptedEntry(102, '2632');
    mutate(a, b);
    assert.throws(() => assertRecoveryProbeAcceptanceHistory([b, a], { policy }));
  });
