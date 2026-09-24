import assert from 'node:assert/strict';
import test from 'node:test';
import { DatagramImpairmentQueue } from '../udp-impairment.mjs';
import { measuredUplinkConfiguration, qualifyMeasuredUplink } from '../native-measured-uplink.mjs';

const expected = {
  rateBitsPerSecond: null,
  delayMilliseconds: 30,
  dropEvery: 500,
  maxDatagramBytes: 2048,
  burstBytes: 16384,
  maxQueuePackets: 256,
  maxQueueBytes: 262144,
  recordTimeline: true,
};
function direction() {
  const queue = new DatagramImpairmentQueue(expected);
  for (let i = 0; i < 1000; i++) {
    queue.enqueue(Buffer.alloc(100), i * 100);
    queue.takeReady(i * 100 + 30);
  }
  queue.close(100100);
  return {
    queue: queue.snapshot(),
    pendingPackets: 0,
    pendingPayloadBytes: 0,
    peakPendingPackets: 1,
    peakPendingPayloadBytes: 100,
  };
}
function fixture() {
  return {
    formatVersion: 1,
    closed: true,
    foreignPeerPackets: 0,
    errors: [],
    forward: direction(),
    reverse: direction(),
  };
}
test('static measured uplink uses exact bounded bidirectional loss/delay configuration', () => {
  assert.deepEqual(measuredUplinkConfiguration('loss0p2-delay30'), {
    forward: expected,
    reverse: expected,
  });
  for (const profile of ['', 'rate4m', 'unknown', null])
    assert.throws(() => measuredUplinkConfiguration(profile));
});
test('independent packet accounting qualifies actual injected loss and complete timelines', () => {
  const q = qualifyMeasuredUplink(fixture());
  assert.equal(q.profile, 'loss0p2-delay30');
  assert.equal(q.forward.injectedPackets, 2);
  assert.equal(q.reverse.forwardedPackets, 998);
  assert.equal(q.forward.maximumForwardResidenceMilliseconds, 30);
  assert.equal(q.nativeAdaptationQualified, false);
});
for (const [name, mutate] of Object.entries({
  open: (p) => (p.closed = false),
  peer: (p) => (p.foreignPeerPackets = 1),
  error: (p) => p.errors.push('failed'),
  schedule: (p) => (p.forwardRateSchedule = {}),
  pending: (p) => (p.forward.pendingPackets = 1),
  missingTimeline: (p) => delete p.reverse.queue.timeline,
  missingDrops: (p) => (p.forward.queue.injectedDrop.packets = 0),
  alteredDelay: (p) => (p.forward.queue.configuration.delayMilliseconds = 0),
  alteredLoss: (p) => (p.reverse.queue.configuration.dropEvery = 100),
  overflow: (p) => (p.forward.queue.overflowDrop.packets = 1),
  discard: (p) => (p.reverse.queue.closeDiscard.packets = 1),
  conservation: (p) => p.forward.queue.forwarded.wireBytes++,
  omitted: (p) => p.reverse.queue.timeline.omittedEvents++,
  prematureForward: (p) =>
    (p.forward.queue.timeline.windows[0].maximumForwardResidenceMilliseconds = 29),
  invalidCounter: (p) => (p.forward.queue.received.packets = NaN),
}))
  test(`rejects ${name}`, () => {
    const p = fixture();
    mutate(p);
    assert.throws(() => qualifyMeasuredUplink(p));
  });
