import test from 'node:test';
import assert from 'node:assert/strict';
import { CapacityProbePolicy } from '../capacity-probe-policy.mjs';
const make = (options = {}) =>
  new CapacityProbePolicy({
    baselineBps: 3_500_000,
    targetBps: 4_000_000,
    stepBps: 250_000,
    startedAt: 0,
    ...options,
  });
function evidence(p, now, changes = {}) {
  const stage = p.command.stage,
    duration = Math.max(0, now - p.stageStartedAt);
  return {
    now,
    sender: {
      at: now,
      stage,
      rttMs: 1,
      bufferMs: 1,
      retransmittedBytes: 0,
      droppedPackets: 0,
      probePayloadBytes: 0,
      ...changes.sender,
    },
    receiver: {
      at: now,
      stage,
      basePackets: Math.floor((duration * 3_500_000) / 10880),
      probePackets: Math.floor((duration * p.command.probeBps) / 10880),
      missing: 0,
      duplicates: 0,
      totalMissing: changes.receiver?.missing ?? 0,
      totalDuplicates: changes.receiver?.duplicates ?? 0,
      ...changes.receiver,
    },
  };
}
function step(p, start = p.stageStartedAt) {
  for (let i = 1; i <= 22; i++) {
    const result = p.observe(evidence(p, start + i / 10));
    if (result) return result;
  }
  assert.fail('No bounded stage decision');
}
test('requires sustained actual baseline and extra delivery before each bounded step', () => {
  const p = make();
  assert.deepEqual(p.command, { stage: 1, baseBps: 3500000, probeBps: 250000 });
  const first = step(p);
  assert.equal(first.kind, 'set');
  assert.equal(first.command.probeBps, 500000);
  const last = step(p);
  assert.equal(last.kind, 'qualified');
  assert.equal(last.offeredAccountedBps, 4000000);
  assert.equal(p.observe(evidence(p, 5)), last);
});
for (const [name, changes, reason] of [
  ['stale sender', { sender: { at: 0 } }, 'stale-feedback'],
  ['future receiver', { receiver: { at: 2 } }, 'invalid-feedback'],
  ['queue pressure', { sender: { bufferMs: 51 } }, 'transport-pressure'],
  ['RTT pressure', { sender: { rttMs: 51 } }, 'transport-pressure'],
  ['retransmission', { sender: { retransmittedBytes: 1 } }, 'transport-pressure'],
  ['sender drop', { sender: { droppedPackets: 1 } }, 'transport-pressure'],
  ['receiver gap', { receiver: { missing: 1 } }, 'receiver-discontinuity'],
  ['duplicate receiver', { receiver: { duplicates: 1 } }, 'receiver-discontinuity'],
  ['future stage', { receiver: { stage: 9 } }, 'invalid-feedback'],
  ['NaN RTT', { sender: { rttMs: NaN } }, 'invalid-feedback'],
  ['native probe budget', { sender: { probeBudgetExhausted: true } }, 'byte-budget'],
  ['native lease expiry', { sender: { probeLeaseExpired: true } }, 'probe-lease-expired'],
  ['malformed lease flag', { sender: { probeLeaseExpired: 'false' } }, 'invalid-feedback'],
  ['probe bytes exhausted', { sender: { probePayloadBytes: 16 * 1024 * 1024 } }, 'byte-budget'],
])
  test(name, () => {
    const p = make();
    assert.equal(p.observe(evidence(p, 1, changes)).reason, reason);
  });
test('old stage cannot confirm new load; short coverage cannot advance', () => {
  const p = make();
  step(p);
  const start = p.stageStartedAt;
  assert.equal(
    p.observe(
      evidence(p, start + 0.1, { receiver: { stage: 1, basePackets: 900, probePackets: 65 } }),
    ),
    null,
  );
  assert.equal(p.observe(evidence(p, start + 0.2)), null);
  assert.equal(p.observe(evidence(p, start + 0.4)), null);
  assert.equal(p.command.stage, 2);
});
test('high packet-pair estimate cannot replace missing delivery', () => {
  const p = make();
  let result;
  for (let i = 1; i <= 41; i++)
    result = p.observe(
      evidence(p, i / 10, {
        sender: { estimatedBandwidthMbps: 6000 },
        receiver: { probePackets: 0 },
      }),
    );
  assert.equal(result.reason, 'delivery-shortfall');
});
test('combined delivery cannot hide baseline starvation', () => {
  const p = make();
  let result;
  for (let i = 1; i <= 41; i++)
    result = p.observe(
      evidence(p, i / 10, {
        receiver: { basePackets: 0, probePackets: Math.floor(((i / 10) * 4_000_000) / 10880) },
      }),
    );
  assert.equal(result.reason, 'delivery-shortfall');
});
test('a gap in observed feedback cannot masquerade as sustained coverage', () => {
  const p = make();
  p.observe(evidence(p, 0.5));
  assert.equal(p.observe(evidence(p, 1)).reason, 'feedback-gap');
});
test('counter reversal and a reversed observation clock refuse', () => {
  const p = make();
  p.observe(evidence(p, 0.5));
  assert.equal(
    p.observe(evidence(p, 0.6, { receiver: { basePackets: 0 } })).reason,
    'invalid-feedback',
  );
  const q = make();
  q.observe(evidence(q, 0.5));
  assert.equal(q.observe(evidence(q, 0.4)).reason, 'invalid-feedback');
});
test('timeout and cancellation are terminal and withdraw extra load', () => {
  const p = make();
  const r = p.observe(evidence(p, 61));
  assert.equal(r.reason, 'time-budget');
  assert.equal(r.command.probeBps, 0);
  const q = make();
  const c = q.cancel(0.1);
  assert.equal(c.kind, 'cancelled');
  assert.equal(c.command.probeBps, 0);
  assert.equal(q.cancel(0.2), c);
});
test('invalid settings fail before any traffic', () => {
  for (const options of [
    { baselineBps: 0 },
    { targetBps: 3500000 },
    { stepBps: 0 },
    { targetBps: 13000000 },
    { startedAt: -1 },
  ])
    assert.throws(() => make(options));
});

test('a new attempt can retain historical transport counters without accepting new retransmissions', () => {
  const p = make({ baselineTransport: { retransmittedBytes: 100, droppedPackets: 2 } });
  assert.equal(
    p.observe(evidence(p, 0.1, { sender: { retransmittedBytes: 100, droppedPackets: 2 } })),
    null,
  );
  assert.equal(
    p.observe(evidence(p, 0.2, { sender: { retransmittedBytes: 101, droppedPackets: 2 } })).reason,
    'transport-pressure',
  );
});
test('changing stage cannot reset cumulative sender byte accounting', () => {
  const p = make();
  let r;
  for (let i = 1; i <= 22; i++) {
    r = p.observe(evidence(p, i / 10, { sender: { probePayloadBytes: 100 } }));
    if (r) break;
  }
  assert.equal(r.kind, 'set');
  assert.equal(
    p.observe(evidence(p, p.stageStartedAt + 0.1, { sender: { probePayloadBytes: 0 } })).reason,
    'invalid-feedback',
  );
});
test('initial missing feedback cannot leave an unbounded active probe', () => {
  const p = make();
  assert.equal(p.observe({ now: 0.1, sender: null, receiver: null }), null);
  assert.equal(p.observe({ now: 2.1, sender: null, receiver: null }).reason, 'missing-feedback');
});
for (const key of ['missing', 'duplicates'])
  test(`late prior-stage ${key} withdraws the current probe`, () => {
    const p = make();
    step(p);
    const r = p.observe(
      evidence(p, p.stageStartedAt + 0.1, {
        receiver: { stage: 1, basePackets: 900, probePackets: 65, [key]: 1 },
      }),
    );
    assert.equal(r.reason, 'receiver-discontinuity');
    assert.equal(r.command.probeBps, 0);
  });
for (const key of ['totalMissing', 'totalDuplicates'])
  test(`${key} survives an unobserved per-stage reset`, () => {
    const p = make();
    step(p);
    assert.equal(
      p.observe(evidence(p, p.stageStartedAt + 0.1, { receiver: { [key]: 1 } })).reason,
      'receiver-discontinuity',
    );
  });
test('mandatory cumulative counters cannot disappear', () => {
  const p = make();
  assert.equal(
    p.observe(evidence(p, 0.1, { receiver: { totalMissing: undefined } })).reason,
    'invalid-feedback',
  );
});
test('a fresh attempt retains history but withdraws on a new discontinuity', () => {
  const p = make({ baselineReceiver: { totalMissing: 2, totalDuplicates: 1 } });
  assert.equal(
    p.observe(evidence(p, 0.1, { receiver: { totalMissing: 2, totalDuplicates: 1 } })),
    null,
  );
  assert.equal(
    p.observe(evidence(p, 0.2, { receiver: { totalMissing: 3, totalDuplicates: 1 } })).reason,
    'receiver-discontinuity',
  );
});
