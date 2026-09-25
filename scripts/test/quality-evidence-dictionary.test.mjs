import assert from 'node:assert/strict';
import test from 'node:test';
import { expandQualityEvidence } from '../quality-evidence-dictionary.mjs';
const fixture = () => ({
  formatVersion: 6,
  transportPolicy: 'recovery-budget-v1',
  overflow: false,
  events: [
    {
      kind: 'localPressure',
      evidence: {
        thermal: { sampleCount: 2, sampleRanges: [[0, 2]], isClosed: false },
        transport: { sampleCount: 1, sampleRanges: [[0, 1]] },
        queue: { stateCount: 1, stateRanges: [[0, 1]], coveredThrough: 12 },
      },
    },
    {
      kind: 'localPressure',
      evidence: {
        thermal: { sampleCount: 1, sampleRanges: [[1, 1]] },
        transport: { sampleCount: 1, sampleRanges: [[0, 1]] },
        queue: null,
      },
    },
  ],
  evidenceDictionary: {
    formatVersion: 1,
    thermal: [
      { sampledAt: 10, state: 0 },
      { sampledAt: 11, state: 2 },
    ],
    transport: [{ sampledAt: 11, sentBytes: '42' }],
    queue: [{ at: 10, itemFraction: 0, byteFraction: 0, phase: 'open' }],
  },
});
test('dictionary restores exact histories and shares only immutable copies', () => {
  const input = fixture(),
    before = structuredClone(input),
    out = expandQualityEvidence(input);
  assert.equal(out.formatVersion, 5);
  assert.equal(out.evidenceDictionary, undefined);
  assert.deepEqual(out.events[0].evidence.thermal.samples, input.evidenceDictionary.thermal);
  assert.deepEqual(out.events[1].evidence.thermal.samples, [input.evidenceDictionary.thermal[1]]);
  assert.deepEqual(out.events[0].evidence.queue.states, input.evidenceDictionary.queue);
  assert.equal(out.events[1].evidence.queue, null);
  assert.throws(() => {
    out.events[0].evidence.thermal.samples[1].state = 0;
  }, TypeError);
  assert.deepEqual(input, before);
});
test('historical inline exports remain unchanged', () => {
  for (const formatVersion of [4, 5]) {
    const q = { formatVersion, events: [] };
    assert.equal(expandQualityEvidence(q), q);
  }
});
for (const [name, mutate] of Object.entries({
  wrongPolicy: (q) => (q.transportPolicy = 'sender-delay-v1'),
  overflow: (q) => (q.overflow = true),
  futureDictionary: (q) => (q.evidenceDictionary.formatVersion = 2),
  extraTable: (q) => (q.evidenceDictionary.extra = []),
  unsafeNumeric: (q) => (q.evidenceDictionary.transport[0].sampledAt = Number.MAX_SAFE_INTEGER + 1),
  negative: (q) => (q.events[0].evidence.thermal.sampleRanges = [[-1, 1]]),
  zero: (q) => (q.events[0].evidence.thermal.sampleRanges = [[0, 0]]),
  outside: (q) => (q.events[0].evidence.thermal.sampleRanges = [[0, 3]]),
  fractional: (q) => (q.events[0].evidence.thermal.sampleRanges = [[0, 1.5]]),
  noncanonical: (q) =>
    (q.events[0].evidence.thermal.sampleRanges = [
      [0, 1],
      [1, 1],
    ]),
  changedFirstUse: (q) =>
    (q.events[0].evidence.thermal.sampleRanges = [
      [1, 1],
      [0, 1],
    ]),
  omitted: (q) => (q.events[0].evidence.thermal.sampleRanges = [[0, 1]]),
  mixed: (q) => (q.events[0].evidence.thermal.samples = []),
  unused: (q) => q.evidenceDictionary.queue.push({ at: 20 }),
  duplicate: (q) => (q.evidenceDictionary.thermal[1] = { ...q.evidenceDictionary.thermal[0] }),
  oversizedHistory: (q) => (q.events[0].evidence.thermal.sampleRanges = [[0, 65]]),
  nestedEntry: (q) => (q.evidenceDictionary.thermal[0].nested = {}),
  oversizedString: (q) => (q.evidenceDictionary.transport[0].sentBytes = '0'.repeat(513)),
  missingRanges: (q) => delete q.events[0].evidence.queue.stateRanges,
  invalidEvent: (q) => (q.events[0] = null),
}))
  test(`dictionary rejects ${name}`, () => {
    const q = fixture();
    mutate(q);
    assert.throws(() => expandQualityEvidence(q));
  });
