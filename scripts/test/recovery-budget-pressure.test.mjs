import assert from 'node:assert/strict';
import test from 'node:test';
import { replayNativePressure, replayNativeLocalPressure } from '../native-quality-pressure.mjs';

const policy = 'recovery-budget-v1';
function fixture({
  retries = 850,
  delay = 400,
  rtt = 65,
  buffer = 67,
  drops = 0,
  pressure = 'nominal',
} = {}) {
  const receipt = { generation: '7', acceptedAt: 0 };
  const snapshot = { scope: { publishingAttemptID: 'attempt' } };
  const row = {
    receipt,
    acknowledgedAt: 1,
    evaluatedAt: 10.25,
    window: {
      start: 10,
      end: 10.25,
      thermal: 'nominal',
      worker: 'unknown',
      transport: pressure,
      queue: 0,
      captured: null,
      encoded: null,
      received: null,
      observedAt: null,
      expected: null,
      lost: null,
      capacity: null,
      connectivity: 'unknown',
    },
    evidence: {
      local: { isPublishing: true, ingressClosed: false, clockGeneration: '7', receipt },
      thermal: {
        isClosed: false,
        isQuarantined: false,
        samples: [
          { sampledAt: 10, state: 0 },
          { sampledAt: 10.25, state: 0 },
        ],
      },
      transport: {
        isClosed: false,
        isQuarantined: false,
        samples: [10, 10.25].map((sampledAt, i) => ({
          sampledAt,
          generation: '7',
          elapsedMilliseconds: String(sampledAt * 1000),
          sentBytes: String(10000 + i * 10000),
          retransmittedBytes: String(1000 + i * retries),
          droppedPackets: i * drops,
          senderBufferMilliseconds: buffer,
          rttMilliseconds: rtt,
          senderDeliveryDelayMilliseconds: delay,
        })),
      },
      queue: {
        isClosed: false,
        isQuarantined: false,
        scope: snapshot.scope,
        coveredThrough: 10.25,
        states: [{ at: 10, itemFraction: 0, byteFraction: 0, phase: 'admitting' }],
      },
      processing: null,
    },
  };
  return { row, snapshot };
}
function source(f, transportPolicy = policy) {
  return replayNativePressure(f.row, f.snapshot, undefined, { transportPolicy });
}
function local(f, transportPolicy = policy) {
  return replayNativeLocalPressure(f.row, f.snapshot, { duration: 0.25, transportPolicy });
}
for (const retries of [101, 850, 10000])
  test(`recovered retry delta ${retries} is not failed delivery`, () => {
    const f = fixture({ retries });
    assert.equal(source(f).transport, 'nominal');
    assert.throws(() => local(f), /lacks independently qualified unhealthy pressure/);
    f.row.window.transport = 'elevated';
    assert.equal(source(f, 'sender-delay-v1').transport, 'elevated');
    assert.equal(local(f, 'sender-delay-v1').transport, 'elevated');
    assert.equal(source(f, 'legacy-threshold-v1').transport, 'elevated');
    assert.throws(() => source(f), /disagrees with raw evidence/);
  });
for (const values of [
  { buffer: 201 },
  { rtt: 100.01 },
  { drops: 1 },
  { buffer: 501, delay: 10000 },
  { rtt: 501, delay: 10000 },
])
  test(`recovery budget retains independent pressure ${JSON.stringify(values)}`, () => {
    const f = fixture({ ...values, retries: 0, pressure: 'elevated' });
    assert.equal(source(f).transport, 'elevated');
    assert.equal(local(f).transport, 'elevated');
  });
for (const values of [
  { buffer: 200, rtt: 100 },
  { buffer: 500, rtt: 500, delay: 2000 },
])
  test(`recovery budget exact boundary ${JSON.stringify(values)}`, () =>
    assert.equal(source(fixture(values)).transport, 'nominal'));
for (const delay of [null, 0])
  test(`unknown delay ${delay} never converts recovered retries into delivery evidence`, () => {
    const f = fixture({ delay, pressure: 'unknown' });
    assert.equal(source(f).transport, 'unknown');
    assert.throws(() => local(f), /lacks independently qualified unhealthy pressure/);
    const dropped = fixture({ delay, drops: 1, pressure: 'elevated' });
    assert.equal(source(dropped).transport, 'elevated');
    assert.equal(local(dropped).transport, 'elevated');
  });
test('unknown, stale and quarantined histories cannot establish health', () => {
  for (const mutate of [
    (f) => (f.row.evaluatedAt = 13),
    (f) => (f.row.evidence.transport.isQuarantined = true),
    (f) => (f.row.evidence.transport.isClosed = true),
  ]) {
    const f = fixture();
    mutate(f);
    assert.throws(() => source(f), /disagrees with raw evidence/);
    f.row.window.transport = 'unknown';
    if (f.row.evaluatedAt === 13) {
      f.row.window.thermal = 'unknown';
      f.row.window.queue = null;
    }
    assert.equal(source(f).transport, 'unknown');
  }
});
test('invalid policies and obsolete option names are rejected', () => {
  const f = fixture();
  for (const value of ['', 'new', null, false]) {
    assert.throws(() => source(f, value), /Unknown transport pressure policy/);
    assert.throws(() => local(f, value), /Unknown transport pressure policy/);
  }
  assert.throws(
    () => replayNativePressure(f.row, f.snapshot, undefined, { recoveryBudget: true }),
    /Unknown pressure replay option/,
  );
});
for (const mutate of [
  (s) => (s[1].sentBytes = '1'),
  (s) => (s[1].retransmittedBytes = '999999'),
  (s) => (s[1].retransmittedBytes = '11001'),
  (s) => (s[1].sampledAt = 9),
])
  test('malformed counter or time evidence cannot establish recovery health', () => {
    const f = fixture();
    mutate(f.row.evidence.transport.samples);
    assert.throws(() => source(f));
  });

test('growing native retention warns before half-delay and requires corroborating bytes', () => {
  const f = fixture({ retries: 0, delay: 700, rtt: 10, buffer: 200, pressure: 'elevated' });
  const samples = f.row.evidence.transport.samples;
  samples[0].senderBufferMilliseconds = 50;
  samples[0].senderBufferedBytes = 10000;
  samples[1].senderBufferedBytes = 40000;
  assert.equal(local(f).transport, 'elevated');
  for (const change of [
    (s) => {
      s[0].senderBufferMilliseconds = 101;
    },
    (s) => {
      s[0].senderBufferedBytes = 40000;
    },
    (s) => {
      delete s[0].senderBufferedBytes;
    },
    (s) => {
      s[0].senderDeliveryDelayMilliseconds = 800;
    },
  ]) {
    const stable = structuredClone(f);
    change(stable.row.evidence.transport.samples);
    stable.row.window.transport = 'nominal';
    assert.equal(source(stable).transport, 'nominal');
  }
});
