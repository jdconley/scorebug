import assert from 'node:assert/strict';
import test from 'node:test';
const implementation = await import('../native-probe-read-interval.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
const value = (bytes, acceptedAt, renewedAt) => ({
  acceptedPayloadBytes: String(bytes),
  lastAcceptedAt: acceptedAt,
  leaseDeadline: renewedAt + 0.3,
  startedAt: 9,
  reason: null,
});
const event = (sample, observedAt) => ({ sample, observedAt });
const fixture = () => ({
  sample: value(1316, 10.01, 10),
  readStartedAt: 10.02,
  readFinishedAt: 10.025,
  usedAt: 10.06,
  events: [event(value(0, null, 10), 10.001), event(value(2632, 10.04, 10.05), 10.051)],
});
function qualify(f) {
  assert.equal(typeof implementation.qualifyNativeProbeReadInterval, 'function');
  return implementation.qualifyNativeProbeReadInterval(f.sample, f);
}
test('allows same-owner renewal after read completion but before use', () => {
  const f = fixture(),
    before = structuredClone(f);
  const result = qualify(f);
  assert.deepEqual(f, before);
  assert.ok(result.earliestSnapshotAt >= f.readStartedAt);
  assert.ok(result.latestSnapshotAt <= f.readFinishedAt);
});
test('allows renewal during an overlapping read when one native state fits', () => {
  const f = fixture();
  f.readFinishedAt = 10.055;
  assert.ok(qualify(f).latestSnapshotAt <= 10.04);
});
test('equal counters may span a renewal without changing acceptance time', () => {
  const f = fixture();
  f.events[1].sample = value(1316, 10.01, 10.05);
  qualify(f);
});
const faults = {
  'missing start': (f) => delete f.readStartedAt,
  'missing finish': (f) => delete f.readFinishedAt,
  'nonfinite start': (f) => (f.readStartedAt = NaN),
  'reversed read': (f) => (f.readStartedAt = 10.03),
  'read finishes after use': (f) => (f.readFinishedAt = 10.07),
  'expired at use': (f) => (f.usedAt = f.sample.leaseDeadline),
  'future acceptance before binding': (f) => (f.sample.lastAcceptedAt = 10.03),
  'future renewal before binding': (f) => {
    f.sample.leaseDeadline = 10.03 + 0.3;
    f.events.unshift(event(value(0, null, 10.03), 10.031));
  },
  'native progress completed before read': (f) => {
    f.readStartedAt = 10.052;
    f.readFinishedAt = 10.055;
  },
  'cannot borrow later counter with earlier lease': (f) => {
    f.sample = value(3948, 10.052, 10);
    f.readStartedAt = 10.053;
    f.readFinishedAt = 10.055;
  },
  'cannot borrow later lease with earlier counter': (f) => {
    f.sample = value(1316, 10.01, 10.05);
    f.readFinishedAt = 10.055;
  },
  'equal bytes cannot change acceptance timestamp': (f) => {
    f.events[1].sample = value(1316, 10.04, 10.05);
  },
  'withdrawal after read before use': (f) => {
    f.events[1].sample.reason = 'cancelled';
  },
  'retirement request after read before use': (f) => {
    f.events[1].sample.reason = 'cancelled';
    f.events[1].observedAt = 10.07;
    f.events[1].retirementRequestedAt = 10.05;
  },
  'unobserved lease': (f) => (f.sample.leaseDeadline = 10.02 + 0.3),
  'malformed count': (f) => (f.sample.acceptedPayloadBytes = '1316.0'),
};
for (const [name, mutate] of Object.entries(faults))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
test('does not combine independently plausible counter and lease instants', () => {
  const f = fixture();
  f.readStartedAt = 9.99;
  f.readFinishedAt = 10.055;
  f.sample = value(1316, 10.045, 10);
  // The larger count was already accepted at10.04. The invented smaller count
  // cannot first become true at10.045, even within a broad overlapping read.
  assert.throws(() => qualify(f));
});
