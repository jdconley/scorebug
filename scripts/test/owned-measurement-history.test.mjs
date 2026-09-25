import assert from 'node:assert/strict';
import test from 'node:test';

const implementation = await import('../owned-measurement-history.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const scope = {
  matchID: 'owned-history',
  broadcastGeneration: 1,
  publishingAttemptID: '10000000-0000-0000-0000-000000000001',
};
function fixture() {
  const events = [];
  for (let attempt = 1; attempt <= 3; attempt++) {
    const ownerID = `20000000-0000-0000-0000-${String(attempt).padStart(12, '0')}`;
    const coreRegisteredAt = attempt * 20;
    for (const kind of [
      'registered',
      'contextRequested',
      'failed',
      'candidateRetired',
      'cleanupJoined',
      'settledFailure',
    ]) {
      events.push({
        ordinal: String(events.length + 1),
        kind,
        ownerID,
        coreRegisteredAt,
        appliedRevision: '2',
        at: coreRegisteredAt + events.length / 100,
        ...(kind === 'failed' ? { reason: 'unavailable' } : {}),
      });
    }
  }
  return {
    formatVersion: 1,
    scope,
    isClosed: true,
    closedAt: 70,
    overflow: false,
    maximumAttempts: 16,
    maximumEvents: 4096,
    events,
  };
}
function index(input = fixture(), expected = scope) {
  assert.equal(
    typeof implementation.indexOwnedMeasurementHistory,
    'function',
    'whole-history owned event indexing must be implemented',
  );
  return implementation.indexOwnedMeasurementHistory(input, { scope: expected });
}
test('indexes all failed same-revision attempts without inventing media or retry permission', () => {
  const raw = fixture(),
    before = structuredClone(raw),
    result = index(raw);
  assert.deepEqual(raw, before);
  assert.equal(result.eventCount, 18);
  assert.deepEqual(
    result.attempts.map((a) => a.eventIndices),
    [
      Array.from({ length: 6 }, (_, i) => i),
      Array.from({ length: 6 }, (_, i) => i + 6),
      Array.from({ length: 6 }, (_, i) => i + 12),
    ],
  );
  assert.deepEqual(
    result.attempts.map((a) => a.appliedRevision),
    ['2', '2', '2'],
  );
  assert.equal(result.nativeProbeQualified, false);
  assert.equal(result.retryPolicyQualified, false);
  assert.equal(result.mediaQualified, false);
});
test('a final stopped owner can join without settling discarded policy', () => {
  const raw = fixture();
  raw.events.pop();
  assert.equal(index(raw).attempts.at(-1).terminal, 'stopped');
});
for (const cleanupFirst of [false, true])
  test(`indexes rejected application with cleanup ${cleanupFirst ? 'before' : 'after'} rejection`, () => {
    const raw = fixture();
    raw.events = raw.events.slice(0, 1);
    const kinds = ['applicationTransferred',
      ...(cleanupFirst ? ['cleanupJoined', 'applicationRejected'] : ['applicationRejected', 'cleanupJoined']),
      'settledApplicationRejection'];
    for (const kind of kinds)
      raw.events.push({ ...raw.events[0], kind, ordinal: String(raw.events.length + 1),
        at: 21 + raw.events.length,
        applicationID: '30000000-0000-0000-0000-000000000001' });
    const result = index(raw);
    assert.equal(result.attempts[0].terminal, 'settledApplicationRejection');
    assert.equal(result.retryPolicyQualified, false);
  });
test('preserves native operation and candidate events at original global indices', () => {
  const raw = fixture();
  const row = raw.events[2];
  raw.events.splice(
    2,
    0,
    ...[
      'contextCaptured',
      'allocationRequested',
      'allocated',
      'renewed',
      'retirementRequested',
      'retired',
      'candidateBound',
      'candidateStartRequested',
      'candidateStarted',
      'candidateJoined',
    ].map((kind) => ({ ...row, kind })),
  );
  raw.events.forEach((e, i) => {
    e.ordinal = String(i + 1);
  });
  assert.deepEqual(
    index(raw).attempts[0].eventIndices,
    Array.from({ length: 16 }, (_, i) => i),
  );
});
const mutations = {
  version: (r) => {
    r.formatVersion = 2;
  },
  scope: (r) => {
    r.scope = { ...r.scope, broadcastGeneration: 2 };
  },
  open: (r) => {
    r.isClosed = false;
  },
  overflow: (r) => {
    r.overflow = true;
  },
  eventBudget: (r) => {
    r.maximumEvents = 8192;
  },
  attemptBudget: (r) => {
    r.maximumAttempts = 32;
  },
  empty: (r) => {
    r.events = [];
  },
  missingOrdinal: (r) => {
    delete r.events[2].ordinal;
  },
  ordinalGap: (r) => {
    r.events[2].ordinal = '4';
  },
  ordinalAlias: (r) => {
    r.events[2].ordinal = '03';
  },
  clockReversal: (r) => {
    r.events[2].at = 1;
  },
  futureEvent: (r) => {
    r.events.at(-1).at = 71;
  },
  invalidClose: (r) => {
    r.closedAt = NaN;
  },
  futureRegistration: (r) => {
    r.events[0].coreRegisteredAt = 99;
  },
  changedRegistration: (r) => {
    r.events[1].coreRegisteredAt += 0.01;
  },
  changedRevision: (r) => {
    r.events[1].appliedRevision = '3';
  },
  numericRevision: (r) => {
    r.events[0].appliedRevision = 2;
  },
  changedOwner: (r) => {
    r.events[1].ownerID = r.events[6].ownerID;
  },
  unknownKind: (r) => {
    r.events[1].kind = 'qualified';
  },
  missingRegistration: (r) => {
    r.events[0].kind = 'contextRequested';
  },
  duplicateRegistration: (r) => {
    r.events[1].kind = 'registered';
  },
  missingJoin: (r) => {
    r.events[4].kind = 'failed';
  },
  repeatedJoin: (r) => {
    r.events[3].kind = 'cleanupJoined';
  },
  settlementBeforeJoin: (r) => {
    r.events[3].kind = 'settledFailure';
  },
  missingSettlementBeforeSuccessor: (r) => {
    r.events[5].kind = 'failed';
  },
  cleanupFailure: (r) => {
    r.events[3].kind = 'cleanupFailed';
  },
  ownerReused: (r) => {
    for (let i = 6; i < 12; i++) r.events[i].ownerID = r.events[0].ownerID;
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const raw = fixture();
    mutate(raw);
    assert.throws(() => index(raw));
  });
test('does not permit caller-selected evidence bounds or modes', () => {
  assert.throws(() =>
    implementation.indexOwnedMeasurementHistory(fixture(), { scope, maximumEvents: 9000 }),
  );
});

test('rejects a dropped or reordered raw event without renumbering history', () => {
  for (const reorder of [false, true]) {
    const raw = fixture();
    if (reorder) [raw.events[1], raw.events[2]] = [raw.events[2], raw.events[1]];
    else raw.events.splice(2, 1);
    assert.throws(() => index(raw), /event ordinal/);
  }
});
test('rejects a seventeenth owner even when every prior attempt settled', () => {
  const raw = fixture(),
    first = raw.events.slice(0, 6);
  raw.events = Array.from({ length: 17 }, (_, attempt) =>
    first.map((event, offset) => ({
      ...event,
      ownerID: `20000000-0000-0000-0000-${String(attempt + 1).padStart(12, '0')}`,
      coreRegisteredAt: (attempt + 1) * 20,
      at: (attempt + 1) * 20 + offset / 100,
      ordinal: String(attempt * 6 + offset + 1),
    })),
  ).flat();
  raw.closedAt = 400;
  assert.throws(() => index(raw), /attempt budget/);
});
test('rejects an oversized event list regardless of its declared bounds', () => {
  const raw = fixture();
  raw.events = Array.from({ length: 4097 }, (_, i) => ({
    ...raw.events[0],
    ordinal: String(i + 1),
  }));
  assert.throws(() => index(raw), /event count outside bounds/);
});
test('new owner cannot backdate Core registration across the preceding settlement', () => {
  const raw = fixture();
  for (let i = 6; i < 12; i++) raw.events[i].coreRegisteredAt = raw.events[4].at;
  assert.throws(() => index(raw), /registration overlaps/);
});
