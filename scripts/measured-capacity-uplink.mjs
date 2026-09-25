import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { measuredUplinkConfiguration } from './native-measured-uplink.mjs';
import { qualifyDatagramTimeline } from './datagram-timeline-qualification.mjs';

const rate = 550000;
const burst = 16384;
const counters = [
  'received',
  'forwarded',
  'injectedDrop',
  'overflowDrop',
  'oversizeDrop',
  'closeDiscard',
];
const safe = (n, maximum = Number.MAX_SAFE_INTEGER) =>
  Number.isSafeInteger(n) && n >= 0 && n <= maximum;
const time = (n) => Number.isFinite(n) && n >= 0 && n <= 1e12;

/** Transport fixture only. Deliberately not an enabled native trial profile. */
export function measuredCapacityUplinkConfiguration(profile) {
  assert.equal(profile, 'capacity550k', 'Unknown measured capacity profile');
  return {
    ...measuredUplinkConfiguration('loss0p2-delay30'),
    forwardRateSchedule: [
      { atMilliseconds: 0, rateBitsPerSecond: null },
      { atMilliseconds: 60000, rateBitsPerSecond: rate },
      { atMilliseconds: 120000, rateBitsPerSecond: null },
    ],
  };
}

function timelinePrefix(previous, current) {
  if (previous.firstObservedAt !== null) {
    assert.equal(current.firstObservedAt, previous.firstObservedAt, 'Timeline origin changed');
    assert(current.lastObservedAt >= previous.lastObservedAt, 'Timeline time reversed');
  }
  assert(current.windows.length >= previous.windows.length, 'Timeline prefix shortened');
  for (const [i, old] of previous.windows.entries()) {
    const next = current.windows[i];
    if (old.end <= previous.lastObservedAt)
      assert(isDeepStrictEqual(next, old), 'Completed timeline prefix changed');
    else {
      assert.equal(next.start, old.start, 'Active timeline bin replaced');
      assert.equal(next.end, old.end);
      for (const k of counters)
        for (const unit of ['packets', 'wireBytes'])
          assert(next[k][unit] >= old[k][unit], 'Active bin counters reversed');
      for (const key of [
        'peakQueuePackets',
        'peakQueueBytes',
        'maximumForwardResidenceMilliseconds',
      ])
        assert(next[key] >= old[key], 'Active bin observation reversed');
    }
  }
}

function direction(value, { appliedRate, at, closed, previous, allowOverflow }) {
  const q = value.queue;
  const { recordTimeline, ...expected } = measuredUplinkConfiguration('loss0p2-delay30').forward;
  assert.deepEqual(q.configuration, { ...expected, rateBitsPerSecond: appliedRate });
  assert.equal(q.closed, closed);
  for (const key of ['pendingPackets', 'peakPendingPackets']) assert(safe(value[key], 16));
  for (const key of ['pendingPayloadBytes', 'peakPendingPayloadBytes'])
    assert(safe(value[key], 16 * 2048));
  assert(
    value.pendingPackets <= value.peakPendingPackets &&
      value.pendingPayloadBytes <= value.peakPendingPayloadBytes,
  );
  assert(
    value.pendingPayloadBytes <= value.pendingPackets * 2048 &&
      value.peakPendingPayloadBytes <= value.peakPendingPackets * 2048,
  );
  for (const [field, max] of [
    ['packets', 256],
    ['peakPackets', 256],
    ['wireBytes', 262144],
    ['peakWireBytes', 262144],
  ])
    assert(safe(q.queue[field], max));
  assert(q.queue.packets <= q.queue.peakPackets && q.queue.wireBytes <= q.queue.peakWireBytes);
  for (const k of [...counters, 'queue']) {
    assert(safe(q[k].packets) && safe(q[k].wireBytes));
    assert.equal(q[k].packets === 0, q[k].wireBytes === 0);
    assert(q[k].wireBytes >= q[k].packets * 28 && q[k].wireBytes <= q[k].packets * 2076);
  }
  for (const unit of ['packets', 'wireBytes']) {
    const total = q.queue[unit] + counters.slice(1).reduce((n, k) => n + q[k][unit], 0);
    assert(safe(total));
    assert.equal(q.received[unit], total, 'Capacity conservation mismatch');
    for (const k of ['oversizeDrop', 'closeDiscard', ...(!allowOverflow ? ['overflowDrop'] : [])])
      assert.equal(q[k][unit], 0, 'Unexpected loss');
    if (closed) assert.equal(q.queue[unit], 0, 'Unjoined queue');
  }
  assert.equal(
    q.injectedDrop.packets,
    Math.floor(q.received.packets / 500),
    'Configured loss differs',
  );
  if (closed)
    assert(value.pendingPackets === 0 && value.pendingPayloadBytes === 0, 'Unjoined sends');
  const proof = qualifyDatagramTimeline(q),
    t = q.timeline;
  for (const w of t.windows)
    if (w.forwarded.packets > 0)
      assert(
        w.maximumForwardResidenceMilliseconds >= 30,
        'Forwarding bin violates configured delay',
      );
  assert(proof.complete, 'Incomplete capacity timeline');
  if (t.lastObservedAt !== null) {
    assert(t.lastObservedAt <= at + (closed ? 250 : 0), 'Future timeline');
    if (closed) assert(t.lastObservedAt >= at, 'Queue closed before schedule stop');
  }
  for (const w of t.windows)
    assert(w.peakQueuePackets <= q.queue.peakPackets && w.peakQueueBytes <= q.queue.peakWireBytes);
  if (q.forwarded.packets) {
    assert(time(q.firstForwardedAt) && time(q.lastForwardedAt));
    assert(
      q.firstForwardedAt >= t.firstObservedAt + 30 &&
        q.lastForwardedAt >= q.firstForwardedAt &&
        q.lastForwardedAt <= at,
    );
    const rows = t.windows.filter((w) => w.forwarded.packets);
    assert(q.firstForwardedAt >= rows[0].start && q.firstForwardedAt < rows[0].end);
    assert(q.lastForwardedAt >= rows.at(-1).start && q.lastForwardedAt < rows.at(-1).end);
  } else assert(q.firstForwardedAt === null && q.lastForwardedAt === null);
  if (previous) {
    for (const k of counters)
      for (const unit of ['packets', 'wireBytes'])
        assert(q[k][unit] >= previous.queue[k][unit], 'Capacity counters reversed');
    for (const key of ['peakPendingPackets', 'peakPendingPayloadBytes'])
      assert(value[key] >= previous[key]);
    for (const key of ['peakPackets', 'peakWireBytes'])
      assert(q.queue[key] >= previous.queue.queue[key]);
    if (previous.queue.forwarded.packets) {
      assert.equal(
        q.firstForwardedAt,
        previous.queue.firstForwardedAt,
        'First forwarding time changed',
      );
      assert(q.lastForwardedAt >= previous.queue.lastForwardedAt);
    }
    timelinePrefix(previous.queue.timeline, t);
  }
}

function bins(queue, start, end) {
  return queue.timeline.windows.filter((w) => w.start >= start && w.end <= end);
}
function trafficCoverage(queue, start, end) {
  let count = 0;
  for (let at = Math.ceil(start / 5000) * 5000; at + 5000 <= end; at += 5000) {
    assert(
      bins(queue, at, at + 5000).some((w) => w.forwarded.packets > 0),
      'Missing phase traffic coverage',
    );
    count++;
  }
  assert(count >= 10, 'Insufficient baseline/restored coverage');
}

/** Applied packet fault only: no receiver receipt, native clock, media quality,
 * archive or adaptation/recovery claim follows from this accounting. */
export function qualifyMeasuredCapacityUplink(snapshot) {
  assert.equal(snapshot.formatVersion, 1);
  assert.equal(snapshot.closed, true);
  assert.equal(snapshot.foreignPeerPackets, 0);
  assert.deepEqual(snapshot.errors, []);
  const expected = measuredCapacityUplinkConfiguration('capacity550k').forwardRateSchedule;
  const schedule = snapshot.forwardRateSchedule;
  assert.deepEqual(schedule?.requested, expected);
  assert(
    time(schedule.startedAt) &&
      time(schedule.stoppedAt) &&
      schedule.stoppedAt >= schedule.startedAt + 180000,
  );
  assert.equal(schedule.phases.length, 3, 'Incomplete capacity schedule');
  let previous;
  for (const [i, phase] of schedule.phases.entries()) {
    assert.equal(phase.atMilliseconds, expected[i].atMilliseconds);
    assert.equal(phase.rateBitsPerSecond, expected[i].rateBitsPerSecond);
    const due = schedule.startedAt + expected[i].atMilliseconds;
    assert(
      time(phase.appliedAt) && phase.appliedAt >= due && phase.appliedAt <= due + 2000,
      'Early/late capacity phase',
    );
    for (const name of ['forward', 'reverse']) {
      direction(phase[name], {
        appliedRate: name === 'forward' ? phase.rateBitsPerSecond : null,
        at: phase.appliedAt,
        closed: false,
        previous: previous?.[name],
        allowOverflow: name === 'forward' && i === 2,
      });
      if (i === 0)
        assert.equal(phase[name].queue.received.packets, 0, 'Traffic before initial phase');
    }
    previous = phase;
  }
  const [baseline, limited, restored] = schedule.phases;
  for (const name of ['forward', 'reverse']) {
    direction(snapshot[name], {
      appliedRate: null,
      at: schedule.stoppedAt,
      closed: true,
      previous: restored[name],
      allowOverflow: name === 'forward',
    });
    assert.equal(
      snapshot[name].queue.overflowDrop.packets,
      restored[name].queue.overflowDrop.packets,
      'Overflow after restoration',
    );
    assert.equal(
      snapshot[name].queue.overflowDrop.wireBytes,
      restored[name].queue.overflowDrop.wireBytes,
    );
    trafficCoverage(snapshot[name].queue, baseline.appliedAt, limited.appliedAt);
    trafficCoverage(snapshot[name].queue, restored.appliedAt, schedule.stoppedAt);
    assert(
      snapshot[name].queue.lastForwardedAt >= restored.appliedAt + 60000,
      'Missing restored traffic span',
    );
  }
  const limitedDurationMilliseconds = restored.appliedAt - limited.appliedAt;
  assert(limitedDurationMilliseconds >= 58000 && limitedDurationMilliseconds <= 62000);
  const limitedForwardWireBytes =
    restored.forward.queue.forwarded.wireBytes - limited.forward.queue.forwarded.wireBytes;
  assert(
    limitedForwardWireBytes > 0 &&
      limitedForwardWireBytes <= burst + (limitedDurationMilliseconds * rate) / 8000 + 1,
    'Limited rate ceiling exceeded',
  );
  const limitedBins = bins(snapshot.forward.queue, limited.appliedAt, restored.appliedAt);
  let tokens = burst,
    at = limitedBins[0]?.start;
  for (const w of limitedBins) {
    tokens = Math.min(burst, tokens + ((w.start - at) * rate) / 8000);
    const available = tokens + ((w.end - w.start) * rate) / 8000;
    assert(w.forwarded.wireBytes <= available + 1, 'Limited bin token budget exceeded');
    tokens = Math.min(burst, Math.max(0, available - w.forwarded.wireBytes));
    at = w.end;
  }
  let maximumOfferedBitsPerSecond = 0;
  for (
    let at = Math.ceil(limited.appliedAt / 1000) * 1000;
    at + 1000 <= restored.appliedAt;
    at += 1000
  )
    maximumOfferedBitsPerSecond = Math.max(
      maximumOfferedBitsPerSecond,
      bins(snapshot.forward.queue, at, at + 1000).reduce((n, w) => n + w.received.wireBytes * 8, 0),
    );
  assert(maximumOfferedBitsPerSecond > rate, 'Insufficient offered load');
  const limitedOverflowPackets =
    restored.forward.queue.overflowDrop.packets - limited.forward.queue.overflowDrop.packets;
  const maximumLimitedResidenceMilliseconds = Math.max(
    0,
    ...limitedBins.map((w) => w.maximumForwardResidenceMilliseconds),
  );
  assert(
    limitedOverflowPackets > 0 || maximumLimitedResidenceMilliseconds >= 500,
    'No observed congestion',
  );
  for (const name of ['forward', 'reverse']) {
    const q = snapshot[name].queue;
    for (const w of [
      ...bins(q, baseline.appliedAt, limited.appliedAt),
      ...bins(q, schedule.stoppedAt - 20000, schedule.stoppedAt),
    ])
      assert(
        w.maximumForwardResidenceMilliseconds <= 250,
        'Baseline/restored queue remains delayed',
      );
  }
  return {
    profile: 'capacity550k',
    limitedDurationMilliseconds,
    limitedForwardWireBytes,
    maximumOfferedBitsPerSecond,
    limitedOverflowPackets,
    maximumLimitedResidenceMilliseconds,
    appliedAt: schedule.phases.map((p) => p.appliedAt),
    forwardPackets: snapshot.forward.queue.forwarded.packets,
    reversePackets: snapshot.reverse.queue.forwarded.packets,
    nativeAdaptationQualified: false,
    networkLossRecoveryQualified: false,
    scope:
      'Applied upload capacity drop/restoration and local UDP send-attempt accounting only; no native or remote recovery qualification.',
  };
}
