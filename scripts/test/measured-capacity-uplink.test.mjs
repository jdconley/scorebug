import assert from 'node:assert/strict';
import test from 'node:test';
import { DatagramImpairmentQueue } from '../udp-impairment.mjs';
const module = await import('../measured-capacity-uplink.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const configuration = {
  rateBitsPerSecond: null,
  delayMilliseconds: 30,
  dropEvery: 500,
  maxDatagramBytes: 2048,
  burstBytes: 16384,
  maxQueuePackets: 256,
  maxQueueBytes: 262144,
  recordTimeline: true,
};
const requested = [
  { atMilliseconds: 0, rateBitsPerSecond: null },
  { atMilliseconds: 60000, rateBitsPerSecond: 550000 },
  { atMilliseconds: 120000, rateBitsPerSecond: null },
];
function simulation({ rate = 550000, forwardEvery = 10 } = {}) {
  const forward = new DatagramImpairmentQueue(configuration),
    reverse = new DatagramImpairmentQueue(configuration);
  const direction = (q) => ({
    queue: q.snapshot(),
    pendingPackets: 0,
    pendingPayloadBytes: 0,
    peakPendingPackets: q.snapshot().forwarded.packets ? 1 : 0,
    peakPendingPayloadBytes: q.snapshot().forwarded.packets ? (q === forward ? 1316 : 100) : 0,
  });
  const phases = [];
  for (let elapsed = 0; elapsed <= 180100; elapsed += 10) {
    const now = 1000 + elapsed;
    const phase = requested.find((p) => p.atMilliseconds === elapsed);
    if (phase) {
      forward.setRate(phase.rateBitsPerSecond === null ? null : rate, now);
      phases.push({
        ...phase,
        appliedAt: now,
        forward: direction(forward),
        reverse: direction(reverse),
      });
    }
    if (elapsed <= 180000) {
      if (elapsed % forwardEvery === 0) forward.enqueue(Buffer.alloc(1316), now);
      if (elapsed % 50 === 0) reverse.enqueue(Buffer.alloc(100), now);
    }
    for (const q of [forward, reverse]) while (q.takeReady(now) !== null) {}
  }
  forward.close(181100);
  reverse.close(181100);
  return {
    formatVersion: 1,
    closed: true,
    foreignPeerPackets: 0,
    errors: [],
    forward: direction(forward),
    reverse: direction(reverse),
    forwardRateSchedule: {
      requested: structuredClone(requested),
      startedAt: 1000,
      stoppedAt: 181100,
      phases,
    },
  };
}
const original = simulation();
function qualify(value = original) {
  assert.equal(typeof module.qualifyMeasuredCapacityUplink, 'function');
  return module.qualifyMeasuredCapacityUplink(value);
}
test('capacity factory retains fixed impairment and independent returned schedules', () => {
  assert.equal(typeof module.measuredCapacityUplinkConfiguration, 'function');
  const c = module.measuredCapacityUplinkConfiguration('capacity550k');
  assert.deepEqual(c, {
    forward: configuration,
    reverse: configuration,
    forwardRateSchedule: requested,
  });
  c.forwardRateSchedule[1].rateBitsPerSecond = 1;
  c.forward.delayMilliseconds = 0;
  assert.deepEqual(module.measuredCapacityUplinkConfiguration('capacity550k'), {
    forward: configuration,
    reverse: configuration,
    forwardRateSchedule: requested,
  });
  for (const name of [undefined, null, 'rate550k', 'capacity550K', 'loss0p2-delay30'])
    assert.throws(() => module.measuredCapacityUplinkConfiguration(name));
});
test('real queue simulation qualifies sustained congestion and restored transport only', () => {
  const before = JSON.stringify(original),
    r = qualify();
  assert.equal(r.profile, 'capacity550k');
  assert.equal(r.limitedDurationMilliseconds, 60000);
  assert(r.maximumOfferedBitsPerSecond > 550000);
  assert(r.limitedOverflowPackets > 0);
  assert(r.maximumLimitedResidenceMilliseconds > 500);
  assert.equal(r.nativeAdaptationQualified, false);
  assert.equal(r.networkLossRecoveryQualified, false);
  assert.equal(JSON.stringify(original), before);
});
test('weak offered traffic cannot claim a capacity fault', () => {
  assert.throws(() => qualify(simulation({ forwardEvery: 50 })), /offered|congestion/);
});
test('actual uncapped forwarding cannot claim the requested rate ceiling', () => {
  const f = simulation({ rate: 1100000 });
  f.forwardRateSchedule.phases[1].forward.queue.configuration.rateBitsPerSecond = 550000;
  assert.throws(() => qualify(f), /ceiling|budget/);
});
const mutations = {
  open: (f) => (f.closed = false),
  pending: (f) => (f.forward.pendingPackets = 1),
  foreign: (f) => (f.foreignPeerPackets = 1),
  socket: (f) => f.errors.push('EIO'),
  omittedPhase: (f) => f.forwardRateSchedule.phases.pop(),
  request: (f) => (f.forwardRateSchedule.requested[1].rateBitsPerSecond = 600000),
  applied: (f) => (f.forwardRateSchedule.phases[1].rateBitsPerSecond = 600000),
  early: (f) => (f.forwardRateSchedule.phases[1].appliedAt -= 1),
  late: (f) => (f.forwardRateSchedule.phases[1].appliedAt += 2001),
  short: (f) => (f.forwardRateSchedule.stoppedAt = 150000),
  alteredDelay: (f) =>
    (f.forwardRateSchedule.phases[1].forward.queue.configuration.delayMilliseconds = 0),
  alteredLoss: (f) => (f.reverse.queue.configuration.dropEvery = 0),
  reverseLimit: (f) =>
    (f.forwardRateSchedule.phases[1].reverse.queue.configuration.rateBitsPerSecond = 550000),
  missingTimeline: (f) => delete f.forward.queue.timeline,
  omittedEvents: (f) => f.forward.queue.timeline.omittedEvents++,
  peak: (f) => (f.forward.peakPendingPackets = 17),
  queued: (f) => (f.forward.queue.queue.packets = 1),
  discard: (f) => f.reverse.queue.closeDiscard.packets++,
  counter: (f) => f.forward.queue.forwarded.wireBytes++,
  reversedCounters: (f) => (f.forwardRateSchedule.phases[2].forward.queue.received.packets = 1),
  phaseOverflow: (f) => f.forwardRateSchedule.phases[1].reverse.queue.overflowDrop.packets++,
  missingDrop: (f) => f.forwardRateSchedule.phases[2].forward.queue.injectedDrop.packets--,
  futureTimeline: (f) =>
    (f.forwardRateSchedule.phases[1].reverse.queue.timeline.lastObservedAt = 61001),
  alteredPrefix: (f) => f.forward.queue.timeline.windows[0].maximumForwardResidenceMilliseconds++,
  alteredFirstTime: (f) => f.forward.queue.firstForwardedAt++,
};
for (const [name, mutate] of Object.entries(mutations))
  test(`capacity evidence rejects ${name}`, () => {
    const f = structuredClone(original);
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('transport profile cannot select an already qualified static native trial', async () => {
  const { measuredUplinkProfiles, measuredUplinkConfiguration } =
    await import('../native-measured-uplink.mjs');
  assert(!measuredUplinkProfiles.includes('capacity550k'));
  assert.throws(() => measuredUplinkConfiguration('capacity550k'));
  const { nativeFileFixtureOptions } = await import('../native-file-fixture.mjs');
  assert.throws(() =>
    nativeFileFixtureOptions({
      streaming: true,
      holdSeconds: 180,
      environment: {
        SCOREBUG_TEST_FILE_INPUT: '/local/input.mov',
        SCOREBUG_TEST_STREAM_HOLD_SECONDS: '180',
        SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
        SCOREBUG_TEST_RELAY_PUBLICATION: '1',
        SCOREBUG_TEST_WORKER_PROCESSING: '1',
        SCOREBUG_TEST_LIVE_PROFILE: '240p30',
        SCOREBUG_TEST_CANDIDATE_PROFILE: '360p30',
        SCOREBUG_TEST_CANDIDATE_HEADROOM: '1',
        SCOREBUG_TEST_MEASURED_TRIAL: '1',
        SCOREBUG_TEST_BANDWIDTH_PROBE: 'staged',
        SCOREBUG_TEST_DELIVERY_DEADLINE_MS: '1500',
        SCOREBUG_TEST_PROBE_POLICY: 'recovery-budget-v1',
        SCOREBUG_TEST_UPLINK_PROFILE: 'capacity550k',
        SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS: '400',
      },
    }),
  );
});

test('every forwarding bin retains the configured30ms delay after restoration', () => {
  const f = structuredClone(original),
    restored = f.forwardRateSchedule.phases[2].appliedAt;
  const w = f.forward.queue.timeline.windows.find(
    (w) => w.start > restored + 1000 && w.forwarded.packets > 0,
  );
  w.maximumForwardResidenceMilliseconds = 0;
  assert.throws(() => qualify(f), /delay|residence/i);
});
