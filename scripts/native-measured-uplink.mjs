import assert from 'node:assert/strict';
import { qualifyDatagramTimeline } from './datagram-timeline-qualification.mjs';

export const measuredUplinkProfiles = Object.freeze(['passthrough', 'loss0p2-delay30']);
const configuration = Object.freeze({
  rateBitsPerSecond: null,
  delayMilliseconds: 30,
  dropEvery: 500,
  maxDatagramBytes: 2048,
  burstBytes: 16384,
  maxQueuePackets: 256,
  maxQueueBytes: 262144,
});
export function measuredUplinkConfiguration(profile) {
  assert.equal(profile, 'loss0p2-delay30', 'Unknown measured impairment');
  return {
    forward: { ...configuration, recordTimeline: true },
    reverse: { ...configuration, recordTimeline: true },
  };
}
const safe = (value, max = Number.MAX_SAFE_INTEGER) =>
  Number.isSafeInteger(value) && value >= 0 && value <= max;
/** Applied UDP send-attempt accounting only; media and native policy qualify separately. */
export function qualifyMeasuredUplink(snapshot) {
  assert.equal(snapshot.formatVersion, 1);
  assert.equal(snapshot.closed, true);
  assert.equal(snapshot.foreignPeerPackets, 0);
  assert.deepEqual(snapshot.errors, []);
  assert.equal(snapshot.forwardRateSchedule, undefined);
  const result = {
    profile: 'loss0p2-delay30',
    nativeAdaptationQualified: false,
    scope:
      'Static bidirectional UDP loss/delay accounting, not causal outage recovery or remote receipt.',
  };
  for (const direction of ['forward', 'reverse']) {
    const d = snapshot[direction],
      q = d.queue;
    assert.deepEqual(q.configuration, configuration);
    assert.equal(q.closed, true);
    assert.equal(d.pendingPackets, 0);
    assert.equal(d.pendingPayloadBytes, 0);
    assert(safe(d.peakPendingPackets, 16) && safe(d.peakPendingPayloadBytes, 16 * 2048));
    assert(d.peakPendingPayloadBytes <= d.peakPendingPackets * 2048);
    assert.equal(q.queue.packets, 0);
    assert.equal(q.queue.wireBytes, 0);
    assert(safe(q.queue.peakPackets, 256) && safe(q.queue.peakWireBytes, 262144));
    qualifyDatagramTimeline(q);
    assert.equal(q.timeline.omittedEvents, 0, 'Complete impairment timeline required');
    assert(
      q.timeline.lastObservedAt - q.timeline.firstObservedAt >= 90000,
      'At least ninety seconds of observed link coverage required',
    );
    for (const key of [
      'received',
      'forwarded',
      'injectedDrop',
      'overflowDrop',
      'oversizeDrop',
      'closeDiscard',
    ]) {
      assert(safe(q[key].packets) && safe(q[key].wireBytes));
      assert(q[key].wireBytes >= q[key].packets * 28 && q[key].wireBytes <= q[key].packets * 2076);
    }
    for (const key of ['overflowDrop', 'oversizeDrop', 'closeDiscard'])
      assert.deepEqual(q[key], { packets: 0, wireBytes: 0 }, 'Unintended loss');
    assert(
      q.injectedDrop.packets > 0 && q.forwarded.packets > 0,
      'Actual impairment and forwarding required',
    );
    assert.equal(q.injectedDrop.packets, Math.floor(q.received.packets / 500));
    for (const unit of ['packets', 'wireBytes'])
      assert.equal(q.received[unit], q.forwarded[unit] + q.injectedDrop[unit]);
    for (const window of q.timeline.windows)
      if (window.forwarded.packets > 0)
        assert(
          window.maximumForwardResidenceMilliseconds >= 30,
          'Forwarded bin lacks configured residence',
        );
    assert(
      Number.isFinite(q.firstForwardedAt) && q.firstForwardedAt >= q.timeline.firstObservedAt + 30,
    );
    assert(
      Number.isFinite(q.lastForwardedAt) &&
        q.lastForwardedAt >= q.firstForwardedAt &&
        q.lastForwardedAt <= q.timeline.lastObservedAt,
    );
    result[direction] = {
      receivedPackets: q.received.packets,
      forwardedPackets: q.forwarded.packets,
      injectedPackets: q.injectedDrop.packets,
      injectedWireBytes: q.injectedDrop.wireBytes,
      maximumForwardResidenceMilliseconds: Math.max(
        ...q.timeline.windows.map((w) => w.maximumForwardResidenceMilliseconds),
      ),
      observedSpanMilliseconds: q.timeline.lastObservedAt - q.timeline.firstObservedAt,
    };
  }
  return result;
}
