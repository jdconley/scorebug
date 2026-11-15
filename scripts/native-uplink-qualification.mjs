import assert from 'node:assert/strict';
import { qualifyDatagramTimeline } from './datagram-timeline-qualification.mjs';

/** Send attempts prove fixture accounting only. Native media and receiver gates
 * independently establish delivered frame continuity and timing. */
export function qualifyNativeUplinkProxy(snapshot) {
  assert.equal(
    snapshot.forwardRateSchedule,
    undefined,
    'Pass-through cannot include a rate schedule',
  );
  assert.equal(snapshot.formatVersion, 1);
  assert.equal(snapshot.closed, true, 'Uplink closure must be joined');
  assert.equal(snapshot.foreignPeerPackets, 0, 'Uplink peer changed or received foreign traffic');
  assert.deepEqual(snapshot.errors, [], 'Uplink socket error');
  const result = { profile: 'passthrough' };
  for (const direction of ['forward', 'reverse']) {
    const d = snapshot[direction],
      q = d.queue,
      c = q.configuration;
    if (q.timeline !== undefined) qualifyDatagramTimeline(q);
    assert.equal(d.pendingPackets, 0);
    assert.equal(d.pendingPayloadBytes, 0);
    assert.equal(q.closed, true);
    assert.deepEqual(
      c,
      {
        rateBitsPerSecond: null,
        delayMilliseconds: 0,
        dropEvery: 0,
        maxDatagramBytes: 2048,
        burstBytes: 16384,
        maxQueuePackets: 256,
        maxQueueBytes: 262144,
      },
      'Unexpected pass-through configuration',
    );
    for (const unit of ['packets', 'wireBytes']) {
      for (const counter of [
        'received',
        'forwarded',
        'injectedDrop',
        'overflowDrop',
        'oversizeDrop',
        'closeDiscard',
        'queue',
      ])
        assert.ok(
          Number.isSafeInteger(q[counter][unit]) && q[counter][unit] >= 0,
          'Invalid uplink counter',
        );
      assert.ok(q.forwarded[unit] > 0, 'Missing bidirectional uplink traffic');
      for (const counter of [
        'injectedDrop',
        'overflowDrop',
        'oversizeDrop',
        'closeDiscard',
        'queue',
      ])
        assert.equal(q[counter][unit], 0, 'Pass-through dropped or retained packets');
      assert.equal(q.received[unit], q.forwarded[unit], 'Uplink conservation mismatch');
    }
    assert.ok(q.forwarded.wireBytes >= q.forwarded.packets * 28);
    result[direction + 'Packets'] = q.forwarded.packets;
    result[direction + 'WireBytes'] = q.forwarded.wireBytes;
  }
  return result;
}

const cumulative = [
  'received',
  'forwarded',
  'injectedDrop',
  'overflowDrop',
  'oversizeDrop',
  'closeDiscard',
];
const safe = (n, maximum = Number.MAX_SAFE_INTEGER) =>
  Number.isSafeInteger(n) && n >= 0 && n <= maximum;
function validateScheduledDirection(d, { rate, closed, at, previous, allowOverflow }) {
  const q = d.queue;
  if (q.timeline !== undefined) qualifyDatagramTimeline(q);
  assert.equal(q.closed, closed);
  assert.deepEqual(q.configuration, {
    rateBitsPerSecond: rate,
    delayMilliseconds: 0,
    dropEvery: 0,
    maxDatagramBytes: 2048,
    burstBytes: 16384,
    maxQueuePackets: 256,
    maxQueueBytes: 262144,
  });
  for (const field of ['pendingPackets', 'peakPendingPackets']) assert.ok(safe(d[field], 16));
  for (const field of ['pendingPayloadBytes', 'peakPendingPayloadBytes'])
    assert.ok(safe(d[field], 16 * 2048));
  assert.ok(
    d.pendingPackets <= d.peakPendingPackets && d.pendingPayloadBytes <= d.peakPendingPayloadBytes,
  );
  assert.ok(d.pendingPayloadBytes <= d.pendingPackets * 2048);
  if (closed) {
    assert.equal(d.pendingPackets, 0);
    assert.equal(d.pendingPayloadBytes, 0);
  }
  assert.ok(safe(q.queue.packets, 256) && safe(q.queue.peakPackets, 256));
  assert.ok(safe(q.queue.wireBytes, 262144) && safe(q.queue.peakWireBytes, 262144));
  assert.ok(q.queue.packets <= q.queue.peakPackets && q.queue.wireBytes <= q.queue.peakWireBytes);
  for (const counter of [...cumulative, 'queue']) {
    for (const unit of ['packets', 'wireBytes']) {
      assert.ok(safe(q[counter][unit]), 'Invalid scheduled uplink counter');
      if (previous && counter !== 'queue')
        assert.ok(q[counter][unit] >= previous.queue[counter][unit], 'Reversed cumulative counter');
    }
    assert.ok(q[counter].wireBytes >= q[counter].packets * 28);
    assert.ok(q[counter].wireBytes <= q[counter].packets * 2076);
  }
  for (const unit of ['packets', 'wireBytes']) {
    assert.equal(
      q.received[unit],
      q.queue[unit] + cumulative.slice(1).reduce((n, k) => n + q[k][unit], 0),
      'Scheduled uplink conservation mismatch',
    );
    for (const k of ['injectedDrop', 'oversizeDrop', 'closeDiscard']) assert.equal(q[k][unit], 0);
    if (!allowOverflow) assert.equal(q.overflowDrop[unit], 0);
    if (closed) assert.equal(q.queue[unit], 0);
  }
  if (q.forwarded.packets) {
    assert.ok(Number.isFinite(q.firstForwardedAt) && q.firstForwardedAt >= 0);
    assert.ok(
      Number.isFinite(q.lastForwardedAt) &&
        q.lastForwardedAt >= q.firstForwardedAt &&
        q.lastForwardedAt <= at,
    );
  } else {
    assert.equal(q.firstForwardedAt, null);
    assert.equal(q.lastForwardedAt, null);
  }
  if (previous?.queue.forwarded.packets) {
    assert.equal(q.firstForwardedAt, previous.queue.firstForwardedAt);
    assert.ok(q.lastForwardedAt >= previous.queue.lastForwardedAt);
  }
}

/** This proves applied transport phases, never native adaptation or recovery. */
export function qualifyNativeUplinkSchedule(snapshot, profile = 'rate4m') {
  assert.ok(['rate4m', 'rate3m'].includes(profile), 'Unsupported expected uplink schedule');
  const rateBitsPerSecond = profile === 'rate3m' ? 3000000 : 4000000;
  assert.equal(snapshot.formatVersion, 1);
  assert.equal(snapshot.closed, true);
  assert.equal(snapshot.foreignPeerPackets, 0);
  assert.deepEqual(snapshot.errors, []);
  const s = snapshot.forwardRateSchedule;
  const expected = [
    { atMilliseconds: 0, rateBitsPerSecond: null },
    { atMilliseconds: 60000, rateBitsPerSecond },
    { atMilliseconds: 120000, rateBitsPerSecond: null },
  ];
  assert.deepEqual(s.requested, expected);
  assert.ok(Number.isFinite(s.startedAt) && s.startedAt >= 0);
  assert.ok(Number.isFinite(s.stoppedAt) && s.stoppedAt >= s.startedAt + 180000);
  assert.equal(s.phases.length, 3, 'Incomplete rate schedule');
  let previous;
  for (const [i, phase] of s.phases.entries()) {
    assert.equal(phase.atMilliseconds, expected[i].atMilliseconds);
    assert.equal(phase.rateBitsPerSecond, expected[i].rateBitsPerSecond);
    const due = s.startedAt + expected[i].atMilliseconds;
    assert.ok(
      Number.isFinite(phase.appliedAt) && phase.appliedAt >= due && phase.appliedAt <= due + 2000,
      'Late or early rate phase',
    );
    for (const direction of ['forward', 'reverse']) {
      validateScheduledDirection(phase[direction], {
        rate: direction === 'forward' ? expected[i].rateBitsPerSecond : null,
        closed: false,
        at: phase.appliedAt,
        previous: previous?.[direction],
        allowOverflow: direction === 'forward' && i >= 2,
      });
      if (i === 0) assert.equal(phase[direction].queue.received.packets, 0);
    }
    previous = phase;
  }
  for (const direction of ['forward', 'reverse']) {
    validateScheduledDirection(snapshot[direction], {
      rate: null,
      closed: true,
      at: s.stoppedAt,
      previous: previous[direction],
      allowOverflow: direction === 'forward',
    });
    assert.ok(snapshot[direction].queue.forwarded.packets > 0);
  }
  const [baseline, limited, recovery] = s.phases;
  const limitedDurationMilliseconds = recovery.appliedAt - limited.appliedAt;
  assert.ok(
    limitedDurationMilliseconds >= 58000 && limitedDurationMilliseconds <= 62000,
    'Missing sustained limited-rate duration',
  );
  assert.ok(limited.appliedAt - baseline.appliedAt >= 58000);
  const limitedForwardWireBytes =
    recovery.forward.queue.forwarded.wireBytes - limited.forward.queue.forwarded.wireBytes;
  assert.ok(limitedForwardWireBytes > 0, 'No traffic during limited phase');
  assert.ok(
    limitedForwardWireBytes <= 16384 + (limitedDurationMilliseconds * rateBitsPerSecond) / 8000 + 1,
    'Limited phase exceeded wire-rate ceiling',
  );
  assert.ok(
    snapshot.forward.queue.lastForwardedAt >= recovery.appliedAt + 60000,
    'Missing recovery traffic coverage',
  );
  return {
    profile,
    limitedDurationMilliseconds,
    limitedForwardWireBytes,
    forwardPackets: snapshot.forward.queue.forwarded.packets,
    reversePackets: snapshot.reverse.queue.forwarded.packets,
    overflowPackets: snapshot.forward.queue.overflowDrop.packets,
    scope:
      'Applied transport phases and conservation; not native adaptation or recovery qualification.',
  };
}
