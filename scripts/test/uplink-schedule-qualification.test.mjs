import test from 'node:test';
import assert from 'node:assert/strict';
import { DatagramImpairmentQueue } from '../udp-impairment.mjs';
import { qualifyNativeUplinkSchedule } from '../native-uplink-qualification.mjs';
import { nativeUplinkOptions } from '../native-streaming-options.mjs';
function fixture(rate = 4000000) {
  const forward = new DatagramImpairmentQueue(),
    reverse = new DatagramImpairmentQueue();
  const direction = (q) => ({
    queue: q.snapshot(),
    pendingPackets: 0,
    pendingPayloadBytes: 0,
    peakPendingPackets: q.snapshot().forwarded.packets ? 1 : 0,
    peakPendingPayloadBytes: q.snapshot().forwarded.packets ? 100 : 0,
  });
  const requested = [
    { atMilliseconds: 0, rateBitsPerSecond: null },
    { atMilliseconds: 60000, rateBitsPerSecond: rate },
    { atMilliseconds: 120000, rateBitsPerSecond: null },
  ];
  const phases = [];
  for (const p of requested) {
    const now = 1000 + p.atMilliseconds;
    forward.setRate(p.rateBitsPerSecond, now);
    phases.push({ ...p, appliedAt: now, forward: direction(forward), reverse: direction(reverse) });
    for (const q of [forward, reverse]) {
      q.enqueue(Buffer.alloc(100), now + 1);
      q.takeReady(now + 1);
    }
  }
  for (const q of [forward, reverse]) {
    q.enqueue(Buffer.alloc(100), 181001);
    q.takeReady(181001);
    q.close();
  }
  return {
    formatVersion: 1,
    closed: true,
    foreignPeerPackets: 0,
    errors: [],
    forward: direction(forward),
    reverse: direction(reverse),
    forwardRateSchedule: { requested, startedAt: 1000, stoppedAt: 182000, phases },
  };
}
test('schedule qualifier proves actual complete phases with conserved bounded traffic', () => {
  const r = qualifyNativeUplinkSchedule(fixture());
  assert.equal(r.profile, 'rate4m');
  assert.equal(r.limitedDurationMilliseconds, 60000);
  assert.equal(r.limitedForwardWireBytes, 128);
  assert.equal(r.forwardPackets, 4);
  assert.match(r.scope, /not.*adaptation/i);
});
test('rejects partial, late, collapsed, corrupt, reordered or unbounded schedule proof', () => {
  const mutations = [
    (s) => (s.closed = false),
    (s) => (s.foreignPeerPackets = 1),
    (s) => s.errors.push('EIO'),
    (s) => (s.forwardRateSchedule.startedAt = null),
    (s) => s.forwardRateSchedule.phases.pop(),
    (s) => (s.forwardRateSchedule.phases[1].appliedAt += 5000),
    (s) => (s.forwardRateSchedule.phases[2].appliedAt = s.forwardRateSchedule.phases[1].appliedAt),
    (s) => (s.forwardRateSchedule.phases[1].atMilliseconds = 50000),
    (s) => (s.forwardRateSchedule.requested[1].rateBitsPerSecond = 5000000),
    (s) => (s.forwardRateSchedule.stoppedAt = 120999),
    (s) => (s.forward.queue.lastForwardedAt = 150000),
    (s) => s.forward.queue.received.packets++,
    (s) => s.forwardRateSchedule.phases[2].forward.queue.received.wireBytes++,
    (s) => (s.forward.pendingPackets = 1),
    (s) => (s.forward.queue.configuration.rateBitsPerSecond = 4000000),
    (s) => s.reverse.queue.overflowDrop.packets++,
    (s) => (s.forwardRateSchedule.phases[1].forward.queue.closed = true),
    (s) => (s.forwardRateSchedule.phases[1].forward.queue.queue.peakPackets = 257),
    (s) => (s.forwardRateSchedule.phases[1].forward.peakPendingPackets = 17),
    (s) => (s.forwardRateSchedule.phases[1].forward.queue.forwarded.wireBytes = NaN),
    (s) => (s.forwardRateSchedule.phases[2].forward.queue.firstForwardedAt = -1),
  ];
  for (const mutate of mutations) {
    const s = fixture();
    mutate(s);
    assert.throws(() => qualifyNativeUplinkSchedule(s));
  }
});
test('rate ceiling rejects conserved counters above the actual limited phase budget', () => {
  const s = fixture();
  for (const d of [s.forwardRateSchedule.phases[2].forward, s.forward]) {
    for (const k of ['received', 'forwarded']) {
      d.queue[k].packets += 400000;
      d.queue[k].wireBytes += 400000 * 128;
    }
  }
  assert.throws(() => qualifyNativeUplinkSchedule(s), /ceiling/);
});
test('rate4m requires 180s coverage and all existing native prerequisites', () => {
  const o = {
    environment: {
      SCOREBUG_TEST_UPLINK_PROFILE: 'rate4m',
      SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
    },
    streaming: true,
    requireQuality: true,
    requireConfirmation: true,
    requireProcessing: true,
    requirePublication: true,
    fixtureWorkload: 'motion-blocks16',
    holdSeconds: 180,
  };
  assert.equal(nativeUplinkOptions(o), 'rate4m');
  for (const holdSeconds of [undefined, 90, 179, 180.5, 601])
    assert.throws(() => nativeUplinkOptions({ ...o, holdSeconds }));
  assert.throws(() => nativeUplinkOptions({ ...o, requireConfirmation: false }));
});

test('rate3m must match the caller-selected profile and every applied rate', () => {
  const s = fixture(3000000);
  assert.equal(qualifyNativeUplinkSchedule(s, 'rate3m').profile, 'rate3m');
  assert.throws(() => qualifyNativeUplinkSchedule(s));
  assert.throws(() => qualifyNativeUplinkSchedule(fixture(), 'rate3m'));
  for (const invalid of ['passthrough', 'rate3M', 3000000, null])
    assert.throws(() => qualifyNativeUplinkSchedule(s, invalid));
  for (const mutate of [
    (x) => {
      x.forwardRateSchedule.requested[1].rateBitsPerSecond = 4000000;
    },
    (x) => {
      x.forwardRateSchedule.phases[1].rateBitsPerSecond = 4000000;
    },
    (x) => {
      x.forwardRateSchedule.phases[1].forward.queue.configuration.rateBitsPerSecond = 4000000;
    },
    (x) => {
      x.forwardRateSchedule.phases[2].appliedAt += 5000;
    },
    (x) => {
      x.forwardRateSchedule.stoppedAt = 120999;
    },
  ]) {
    const value = fixture(3000000);
    mutate(value);
    assert.throws(() => qualifyNativeUplinkSchedule(value, 'rate3m'));
  }
});

test('rate3m rejects conserved traffic below the old4m ceiling but above its own budget', () => {
  const s = fixture(3000000);
  for (const d of [s.forwardRateSchedule.phases[2].forward, s.forward]) {
    for (const k of ['received', 'forwarded']) {
      d.queue[k].packets += 200000;
      d.queue[k].wireBytes += 200000 * 128;
    }
  }
  assert.throws(() => qualifyNativeUplinkSchedule(s, 'rate3m'), /ceiling/);
});

test('rate3m requires the explicit fixed240 full-pipeline qualification', () => {
  const o = {
    environment: {
      SCOREBUG_TEST_UPLINK_PROFILE: 'rate3m',
      SCOREBUG_TEST_LIVE_PROFILE: '240p30',
      SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
    },
    streaming: true,
    requireQuality: false,
    requireConfirmation: false,
    requireProcessing: true,
    requirePublication: true,
    fixtureWorkload: 'motion-blocks16',
    holdSeconds: 180,
    liveProfile: '240p30',
  };
  assert.equal(nativeUplinkOptions(o), 'rate3m');
  for (const patch of [
    { holdSeconds: 179 },
    { holdSeconds: 601 },
    { requirePublication: false },
    { requireProcessing: false },
    { streaming: false },
    { requireQuality: true },
    { requireConfirmation: true },
    { liveProfile: '360p30' },
    { fixtureWorkload: 'motion' },
  ])
    assert.throws(() => nativeUplinkOptions({ ...o, ...patch }));
  for (const profile of ['1080p30', '540p30', '360p30'])
    assert.throws(() =>
      nativeUplinkOptions({
        ...o,
        liveProfile: profile,
        environment: { ...o.environment, SCOREBUG_TEST_LIVE_PROFILE: profile },
      }),
    );
  for (const key of ['SCOREBUG_TEST_DIRECT_RTMP_RECORDER', 'SCOREBUG_TEST_LIVE_PROFILE']) {
    const env = { ...o.environment };
    delete env[key];
    assert.throws(() => nativeUplinkOptions({ ...o, environment: env }));
  }
});
