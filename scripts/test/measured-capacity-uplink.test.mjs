import assert from 'node:assert/strict';
import test from 'node:test';
import { DatagramImpairmentQueue } from '../udp-impairment.mjs';
import { qualifyRateLedger } from '../rate-ledger-qualification.mjs';
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
function simulation({
  rate = 550000,
  forwardEvery = 10,
  schedule = requested,
  duration = 180000,
  trafficUntil = duration,
  trafficGaps = {},
  sendPauses = {},
  appliedOffsets = [0, 0, 0],
  recordRateLedger = false,
  forwardBursts = [],
  forwardInjections = [],
} = {}) {
  const forward = new DatagramImpairmentQueue({ ...configuration, recordRateLedger }),
    reverse = new DatagramImpairmentQueue(configuration);
  const direction = (q) => ({
    queue: q.snapshot(),
    pendingPackets: 0,
    pendingPayloadBytes: 0,
    peakPendingPackets: q.snapshot().forwarded.packets ? 1 : 0,
    peakPendingPayloadBytes: q.snapshot().forwarded.packets ? (q === forward ? 1316 : 100) : 0,
  });
  const phases = [];
  for (let elapsed = 0; elapsed <= duration + 100; elapsed += 10) {
    const now = 1000 + elapsed;
    const phase = schedule.find((p, i) => p.atMilliseconds + appliedOffsets[i] === elapsed);
    if (phase) {
      forward.setRate(phase.rateBitsPerSecond === null ? null : rate, now);
      phases.push({
        ...phase,
        appliedAt: now,
        forward: direction(forward),
        reverse: direction(reverse),
      });
      for (const q of [forward, reverse]) while (q.takeReady(now) !== null) {}
    }
    for (const [name, q, every, bytes] of [
      ['forward', forward, forwardEvery, 1316],
      ['reverse', reverse, 50, 100],
    ]) {
      const within = (ranges) => ranges?.some(([start, end]) => elapsed >= start && elapsed < end);
      const interval = name === 'forward' && within(forwardBursts) ? 10 : every;
      if (elapsed <= trafficUntil && elapsed % interval === 0 && !within(trafficGaps[name]))
        q.enqueue(Buffer.alloc(bytes), now);
      if (name === 'forward')
        for (const [at, count] of forwardInjections)
          if (elapsed === at) for (let i = 0; i < count; i++) q.enqueue(Buffer.alloc(bytes), now);
      if (!within(sendPauses[name])) while (q.takeReady(now) !== null) {}
    }
  }
  forward.close(1000 + duration + 100);
  reverse.close(1000 + duration + 100);
  return {
    ...(recordRateLedger ? { rateLedger: forward.rateLedgerSnapshot() } : {}),
    formatVersion: 1,
    closed: true,
    foreignPeerPackets: 0,
    errors: [],
    forward: direction(forward),
    reverse: direction(reverse),
    forwardRateSchedule: {
      requested: structuredClone(schedule),
      startedAt: 1000,
      stoppedAt: 1000 + duration + 100,
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

const delayed750Schedule = [
  { atMilliseconds: 0, rateBitsPerSecond: null },
  { atMilliseconds: 90000, rateBitsPerSecond: 750000 },
  { atMilliseconds: 150000, rateBitsPerSecond: null },
];
const delayed750 = simulation({ rate: 750000, schedule: delayed750Schedule, duration: 210000 });
test('explicit750k profile preserves impairment and extends baseline and total observation', () => {
  assert.deepEqual(module.measuredCapacityUplinkConfiguration('capacity750k'), {
    forward: configuration,
    reverse: configuration,
    forwardRateSchedule: delayed750Schedule,
  });
  assert.deepEqual(module.measuredCapacityProfile('capacity750k'), {
    rateBitsPerSecond: 750000,
    limitedAtMilliseconds: 90000,
    restoredAtMilliseconds: 150000,
    holdSeconds: 210,
  });
  const before = structuredClone(delayed750);
  const r = module.qualifyMeasuredCapacityUplink(delayed750, { profile: 'capacity750k' });
  assert.equal(r.profile, 'capacity750k');
  assert.equal(r.limitedDurationMilliseconds, 60000);
  assert.equal(r.nativeAdaptationQualified, false);
  assert.equal(r.networkLossRecoveryQualified, false);
  assert.deepEqual(delayed750, before);
  assert.throws(() => module.qualifyMeasuredCapacityUplink(delayed750));
  assert.throws(() => module.qualifyMeasuredCapacityUplink(original, { profile: 'capacity750k' }));
});
for (const [name, mutate] of Object.entries(mutations))
  test(`750k evidence rejects ${name}`, () => {
    const f = structuredClone(delayed750);
    mutate(f);
    assert.throws(() => module.qualifyMeasuredCapacityUplink(f, { profile: 'capacity750k' }));
  });
test('750k profile cannot inherit obsolete180s duration or weak offered traffic', () => {
  assert.throws(() =>
    module.qualifyMeasuredCapacityUplink(
      simulation({ rate: 750000, schedule: delayed750Schedule, duration: 180000 }),
      { profile: 'capacity750k' },
    ),
  );
  assert.throws(() =>
    module.qualifyMeasuredCapacityUplink(
      simulation({
        rate: 750000,
        forwardEvery: 50,
        schedule: delayed750Schedule,
        duration: 210000,
      }),
      { profile: 'capacity750k' },
    ),
  );
});
for (const profile of [null, false, 'capacity750K', 'capacity800k'])
  test(`capacity replay rejects unsupported profile ${profile}`, () => {
    assert.throws(() => module.qualifyMeasuredCapacityUplink(original, { profile }));
  });

for (const [profile, rate, schedule, hold] of [
  ['capacity550k', 550000, requested, 180000],
  ['capacity750k', 750000, delayed750Schedule, 210000],
]) {
  const options = { profile, coveragePolicy: 'scheduled-hold-v1' };
  const simulate = (extra = {}) => simulation({ rate, schedule, duration: hold + 40000, ...extra });
  const cleanup = simulate({ trafficUntil: hold });
  test(`${profile} scheduled coverage permits silent cleanup without changing raw evidence`, () => {
    const before = structuredClone(cleanup);
    const r = module.qualifyMeasuredCapacityUplink(cleanup, options);
    assert.equal(r.coveragePolicy, 'scheduled-hold-v1');
    assert.deepEqual(r.trafficCoverageWindows, {
      baseline: { start: 1000, end: 1000 + schedule[1].atMilliseconds },
      restored: { start: 1000 + schedule[2].atMilliseconds, end: 1000 + hold },
    });
    assert.equal(r.nativeAdaptationQualified, false);
    assert.equal(r.networkLossRecoveryQualified, false);
    assert.deepEqual(cleanup, before);
    assert.throws(() => module.qualifyMeasuredCapacityUplink(cleanup, { profile }), /coverage/);
    assert.throws(
      () =>
        module.qualifyMeasuredCapacityUplink(cleanup, {
          profile,
          coveragePolicy: 'through-close-v1',
        }),
      /coverage/,
    );
    cleanup.coveragePolicy = 'scheduled-hold-v1';
    assert.throws(() => module.qualifyMeasuredCapacityUplink(cleanup, { profile }), /coverage/);
    delete cleanup.coveragePolicy;
  });
  test(`${profile} default coverage explicitly reports the original through-close scope`, () => {
    const f = simulate();
    const result = module.qualifyMeasuredCapacityUplink(f, { profile });
    assert.equal(result.coveragePolicy, 'through-close-v1');
    assert.equal(result.trafficCoverageWindows.restored.end, f.forwardRateSchedule.stoppedAt);
    assert.deepEqual(
      result,
      module.qualifyMeasuredCapacityUplink(f, { profile, coveragePolicy: 'through-close-v1' }),
    );
  });
  test(`${profile} scheduled endpoint follows actual restoration and cannot exceed closure`, () => {
    const f = simulate({ appliedOffsets: [0, 1000, 1000], trafficUntil: hold + 1000 });
    const result = module.qualifyMeasuredCapacityUplink(f, options);
    assert.equal(result.trafficCoverageWindows.restored.end, 1000 + hold + 1000);
    assert.throws(
      () =>
        module.qualifyMeasuredCapacityUplink(
          simulate({
            appliedOffsets: [0, 1000, 1000],
            duration: hold,
          }),
          options,
        ),
      /observation.*clos|restored.*span/i,
    );
  });
  for (const name of ['forward', 'reverse']) {
    test(`${profile} scheduled coverage rejects ${name} gaps inside the restored minute`, () => {
      const f = simulate({
        trafficUntil: hold,
        trafficGaps: { [name]: [[hold - 30000, hold - 15000]] },
      });
      assert.throws(() => module.qualifyMeasuredCapacityUplink(f, options), /coverage/);
    });
    test(`${profile} scheduled final20s rejects real ${name} queue delay even after healthy cleanup`, () => {
      const f = simulate({ sendPauses: { [name]: [[hold - 10000, hold - 9400]] } });
      assert.throws(
        () => module.qualifyMeasuredCapacityUplink(f, options),
        /queue remains delayed/,
      );
    });
    test(`${profile} scheduled coverage retains closure final20s ${name} queue checks`, () => {
      const f = simulate({ sendPauses: { [name]: [[hold + 30000, hold + 30600]] } });
      assert.throws(
        () => module.qualifyMeasuredCapacityUplink(f, options),
        /queue remains delayed/,
      );
    });
  }
  test(`${profile} scheduled coverage retains the last-forwarded endpoint requirement`, () => {
    const f = simulate({ trafficUntil: hold - 100 });
    assert.throws(() => module.qualifyMeasuredCapacityUplink(f, options), /restored traffic span/);
  });
  test(`${profile} scheduled coverage retains minimum profile hold`, () => {
    assert.throws(() =>
      module.qualifyMeasuredCapacityUplink(simulate({ duration: hold - 1000 }), options),
    );
  });
  test(`${profile} scheduled coverage rejects real cleanup overflow`, () => {
    const f = simulate({ sendPauses: { forward: [[hold + 10000, hold + 14000]] } });
    assert.throws(
      () => module.qualifyMeasuredCapacityUplink(f, options),
      /Overflow after restoration/,
    );
  });
  for (const [name, mutate] of Object.entries(mutations))
    test(`${profile} scheduled coverage retains full-lifetime ${name} validation`, () => {
      const f = structuredClone(cleanup);
      mutate(f);
      assert.throws(() => module.qualifyMeasuredCapacityUplink(f, options));
    });
  for (const [name, mutate] of Object.entries({
    lateCounter: (f) => f.forward.queue.timeline.windows.at(-1).received.wireBytes++,
    lateResidence: (f) => {
      const row = f.forward.queue.timeline.windows.find(
        (w) => w.start > hold + 10000 && w.forwarded.packets,
      );
      row.maximumForwardResidenceMilliseconds = 0;
    },
    lateErrors: (f) => f.errors.push('cleanup send failure'),
    latePending: (f) => {
      f.reverse.pendingPackets = 1;
      f.reverse.pendingPayloadBytes = 100;
    },
  }))
    test(`${profile} scheduled coverage rejects ${name} after the observation endpoint`, () => {
      const f = simulate();
      mutate(f);
      assert.throws(() => module.qualifyMeasuredCapacityUplink(f, options));
    });
}

for (const options of [
  { coveragePolicy: 'scheduled' },
  { coveragePolicy: null },
  { coveragePolicy: false },
  { coveragePolicy: 'scheduled-hold-v1', restoredUntil: 180000 },
  { coveragePolciy: 'scheduled-hold-v1' },
])
  test(`capacity qualifier rejects unknown options ${JSON.stringify(options)}`, () => {
    assert.throws(
      () => module.qualifyMeasuredCapacityUplink(original, options),
      /coverage policy|option/i,
    );
  });

function ledgerSimulation(extra = {}) {
  const { rateLedger, ...snapshot } = simulation({
    rate: 750000,
    schedule: delayed750Schedule,
    duration: 210000,
    forwardEvery: 20,
    forwardBursts: [[91000, 92000]],
    recordRateLedger: true,
    ...extra,
  });
  return { snapshot, rateLedger };
}
const boundLedger = ledgerSimulation();
const ledgerOptions = { profile: 'capacity750k', stimulusPolicy: 'rate-ledger-v1' };
function qualifyLedger({ snapshot, rateLedger } = boundLedger, options = {}) {
  return module.qualifyMeasuredCapacityUplink(snapshot, {
    ...ledgerOptions,
    rateLedger,
    ...options,
  });
}

test('explicit ledger stimulus qualifies a real token denial below historical congestion severity', () => {
  const before = structuredClone(boundLedger);
  const [, limited, restored] = boundLedger.snapshot.forwardRateSchedule.phases;
  const { recordTimeline, ...finiteConfiguration } = configuration;
  const expectedProof = qualifyRateLedger(
    {
      ledger: boundLedger.rateLedger,
      limited: { appliedAt: limited.appliedAt, queue: limited.forward.queue },
      restored: { appliedAt: restored.appliedAt, queue: restored.forward.queue },
    },
    { configuration: { ...finiteConfiguration, rateBitsPerSecond: 750000 } },
  );
  assert.throws(
    () =>
      module.qualifyMeasuredCapacityUplink(boundLedger.snapshot, {
        profile: 'capacity750k',
      }),
    /No observed congestion/,
  );
  const result = qualifyLedger();
  assert.equal(result.stimulusPolicy, 'rate-ledger-v1');
  assert.deepEqual(result.rateLedgerProof, expectedProof);
  assert.equal(result.limitedOverflowPackets, 0);
  assert(result.maximumLimitedResidenceMilliseconds < 500);
  assert(result.maximumOfferedBitsPerSecond > 750000);
  assert.equal(result.nativeAdaptationQualified, false);
  assert.equal(result.networkLossRecoveryQualified, false);
  assert.deepEqual(boundLedger, before);
});

test('explicit historical stimulus keeps the exact default result', () => {
  const result = qualify();
  assert.deepEqual(
    module.qualifyMeasuredCapacityUplink(original, {
      stimulusPolicy: 'congestion-v1',
    }),
    result,
  );
  assert(!Object.hasOwn(result, 'stimulusPolicy'));
  assert(!Object.hasOwn(result, 'rateLedgerProof'));
});
for (const stimulusPolicy of [null, false, 'rate-ledger', 'unknown'])
  test(`rejects unsupported stimulus policy ${stimulusPolicy}`, () => {
    assert.throws(() => qualifyLedger(boundLedger, { stimulusPolicy }), /stimulus policy/i);
  });
for (const options of [
  { rateLedger: boundLedger.rateLedger },
  { stimulusPolicy: 'congestion-v1', rateLedger: boundLedger.rateLedger },
  { rateLedger: undefined },
])
  test(`ledger cannot select or accompany default stimulus ${Object.keys(options)}`, () => {
    assert.throws(() => module.qualifyMeasuredCapacityUplink(original, options), /ledger.*policy/i);
  });
test('raw snapshot policy and ledger cannot authorize new qualification', () => {
  assert.throws(
    () =>
      module.qualifyMeasuredCapacityUplink(
        {
          ...boundLedger.snapshot,
          stimulusPolicy: 'rate-ledger-v1',
          rateLedger: boundLedger.rateLedger,
        },
        { profile: 'capacity750k' },
      ),
    /No observed congestion/,
  );
});
for (const rateLedger of [undefined, null, {}])
  test(`explicit ledger policy rejects absent/incomplete evidence ${JSON.stringify(rateLedger)}`, () => {
    assert.throws(() => qualifyLedger(boundLedger, { rateLedger }), /ledger/i);
  });
for (const [name, mutate] of Object.entries({
  limitOrdinal: (f) =>
    f.snapshot.forwardRateSchedule.phases[1].forward.queue.rateLedgerOperationOrdinal++,
  restoredOrdinal: (f) =>
    f.snapshot.forwardRateSchedule.phases[2].forward.queue.rateLedgerOperationOrdinal++,
  firstDenial: (f) =>
    f.snapshot.forwardRateSchedule.phases[2].forward.queue.rateLedgerFirstDenial.ordinal++,
  limitTime: (f) => f.rateLedger.header.limit.at++,
  restorationTime: (f) => f.rateLedger.footer.restoration.at++,
  ledgerConfiguration: (f) => f.rateLedger.header.configuration.burstBytes++,
  missingOperation: (f) => f.rateLedger.operations.splice(10, 1),
  missingClosure: (f) => (f.rateLedger.footer.closed = false),
  overflow: (f) => (f.rateLedger.overflow = true),
}))
  test(`explicit ledger stimulus rejects ${name}`, () => {
    const f = structuredClone(boundLedger);
    mutate(f);
    assert.throws(() => qualifyLedger(f));
  });
for (const [name, mutate] of Object.entries(mutations))
  test(`explicit ledger stimulus retains ${name} transport gate`, () => {
    const f = structuredClone(boundLedger);
    mutate(f.snapshot);
    assert.throws(() => qualifyLedger(f));
  });
test('ledger stimulus still requires offered traffic above selected rate', () => {
  assert.throws(() => qualifyLedger(ledgerSimulation({ forwardBursts: [] })), /offered load/);
});
test('ledger stimulus retains baseline and restored traffic coverage', () => {
  for (const name of ['forward', 'reverse'])
    assert.throws(
      () =>
        qualifyLedger(
          ledgerSimulation({
            trafficGaps: { [name]: [[180000, 195000]] },
          }),
        ),
      /coverage/,
    );
});
test('ledger stimulus retains baseline and restored queue delay ceilings', () => {
  for (const name of ['forward', 'reverse'])
    assert.throws(
      () =>
        qualifyLedger(
          ledgerSimulation({
            sendPauses: { [name]: [[200000, 200600]] },
          }),
        ),
      /queue remains delayed/,
    );
});

test('an offered-load peak absorbed by the burst cannot qualify without an actual denial', () => {
  const f = ledgerSimulation({
    forwardBursts: [
      [91000, 91200],
      [91600, 91800],
    ],
  });
  assert.equal(f.rateLedger.denial, null);
  assert.throws(() => qualifyLedger(f), /denial/i);
});
test('ledger stimulus retains the per-bin finite rate budget', () => {
  const f = ledgerSimulation({ rate: 1100000 });
  f.snapshot.forwardRateSchedule.phases[1].forward.queue.configuration.rateBitsPerSecond = 750000;
  assert.throws(() => qualifyLedger(f), /ceiling|budget/i);
});
test('ledger stimulus derives its finite rate from either selected capacity profile', () => {
  const f = ledgerSimulation({
    rate: 550000,
    schedule: requested,
    duration: 180000,
    forwardBursts: [[61000, 61600]],
  });
  const result = qualifyLedger(f, { profile: 'capacity550k' });
  assert.equal(result.rateLedgerProof.rateBoundQualified, true);
  assert.equal(result.limitedOverflowPackets, 0);
  assert(result.maximumLimitedResidenceMilliseconds < 500);
  assert.throws(() => module.qualifyMeasuredCapacityUplink(f.snapshot), /No observed congestion/);
});
test('ledger stimulus composes with scheduled coverage during silent cleanup', () => {
  const f = ledgerSimulation({ duration: 250000, trafficUntil: 210000 });
  assert.equal(
    qualifyLedger(f, { coveragePolicy: 'scheduled-hold-v1' }).rateLedgerProof.rateBoundQualified,
    true,
  );
  assert.throws(() => qualifyLedger(f), /coverage/);
});

const carryInLedgerOptions = { forwardBursts: [], forwardInjections: [[89990, 30]] };
const carryInLedger = ledgerSimulation(carryInLedgerOptions);
function qualifyTokenBudget(f = carryInLedger, options = {}) {
  return qualifyLedger(f, { stimulusPolicy: 'token-budget-v1', ...options });
}
test('token budget proves a real carry-in denial despite all limited-phase new input below rate', () => {
  const before = structuredClone(carryInLedger);
  const [, limited, restored] = carryInLedger.snapshot.forwardRateSchedule.phases;
  assert(carryInLedger.rateLedger.header.initialFIFO.length >= 30);
  assert(carryInLedger.rateLedger.denial.at >= limited.appliedAt);
  for (const bin of restored.forward.queue.timeline.windows)
    if (bin.start >= limited.appliedAt && bin.end <= restored.appliedAt)
      assert((bin.received.wireBytes * 8000) / (bin.end - bin.start) < 750000);
  const result = qualifyTokenBudget();
  assert.equal(result.stimulusPolicy, 'token-budget-v1');
  assert.equal(result.offeredLoadRequired, false);
  assert.equal(result.maximumOfferedBitsPerSecond, 537600);
  assert.equal(result.limitedOverflowPackets, 0);
  assert(result.maximumLimitedResidenceMilliseconds < 500);
  const { recordTimeline, ...finiteConfiguration } = configuration;
  assert.deepEqual(
    result.rateLedgerProof,
    qualifyRateLedger(
      {
        ledger: carryInLedger.rateLedger,
        limited: { appliedAt: limited.appliedAt, queue: limited.forward.queue },
        restored: { appliedAt: restored.appliedAt, queue: restored.forward.queue },
      },
      { configuration: { ...finiteConfiguration, rateBitsPerSecond: 750000 } },
    ),
  );
  assert.equal(result.nativeAdaptationQualified, false);
  assert.equal(result.networkLossRecoveryQualified, false);
  assert.deepEqual(carryInLedger, before);
});
test('carry-in proof does not relax either earlier policy or attach new fields to its result', () => {
  assert.throws(() => qualifyLedger(carryInLedger), /offered load/);
  assert.throws(
    () =>
      module.qualifyMeasuredCapacityUplink(carryInLedger.snapshot, {
        profile: 'capacity750k',
      }),
    /offered load/,
  );
  for (const result of [qualify(), qualifyLedger()])
    assert(!Object.hasOwn(result, 'offeredLoadRequired'));
  assert.equal(qualifyTokenBudget(boundLedger).rateLedgerProof.rateBoundQualified, true);
});
test('raw token policy cannot bypass historical offered-load requirement', () => {
  assert.throws(
    () =>
      module.qualifyMeasuredCapacityUplink(
        {
          ...carryInLedger.snapshot,
          stimulusPolicy: 'token-budget-v1',
          offeredLoadRequired: false,
          rateLedger: carryInLedger.rateLedger,
        },
        { profile: 'capacity750k' },
      ),
    /offered load/,
  );
});
test('token budget rejects an underload with no actual ready-head denial', () => {
  const f = ledgerSimulation({ forwardBursts: [] });
  assert.equal(f.rateLedger.denial, null);
  assert.throws(() => qualifyTokenBudget(f), /denial/i);
});
for (const rateLedger of [undefined, null, {}])
  test(`token budget requires complete ledger ${JSON.stringify(rateLedger)}`, () => {
    assert.throws(() => qualifyTokenBudget(carryInLedger, { rateLedger }), /ledger/i);
  });
for (const [name, mutate] of Object.entries({
  limitOrdinal: (f) =>
    f.snapshot.forwardRateSchedule.phases[1].forward.queue.rateLedgerOperationOrdinal++,
  restoredOrdinal: (f) =>
    f.snapshot.forwardRateSchedule.phases[2].forward.queue.rateLedgerOperationOrdinal++,
  independentDenial: (f) =>
    f.snapshot.forwardRateSchedule.phases[2].forward.queue.rateLedgerFirstDenial.ordinal++,
  forgedDenial: (f) => f.rateLedger.denial.tokens++,
  limitTime: (f) => f.rateLedger.header.limit.at++,
  restorationTime: (f) => f.rateLedger.footer.restoration.at++,
  configuration: (f) => f.rateLedger.header.configuration.burstBytes++,
  omittedOperation: (f) => f.rateLedger.operations.splice(10, 1),
  incomplete: (f) => (f.rateLedger.footer.closed = false),
  overflow: (f) => (f.rateLedger.overflow = true),
}))
  test(`token budget rejects ${name}`, () => {
    const f = structuredClone(carryInLedger);
    mutate(f);
    assert.throws(() => qualifyTokenBudget(f));
  });
for (const [name, mutate] of Object.entries(mutations))
  test(`token budget retains ${name} transport gate`, () => {
    const f = structuredClone(carryInLedger);
    mutate(f.snapshot);
    assert.throws(() => qualifyTokenBudget(f));
  });
test('token budget retains traffic coverage and baseline/restored delay limits', () => {
  for (const name of ['forward', 'reverse']) {
    assert.throws(
      () =>
        qualifyTokenBudget(
          ledgerSimulation({
            ...carryInLedgerOptions,
            trafficGaps: { [name]: [[180000, 195000]] },
          }),
        ),
      /coverage/,
    );
    assert.throws(
      () =>
        qualifyTokenBudget(
          ledgerSimulation({
            ...carryInLedgerOptions,
            sendPauses: { [name]: [[200000, 200600]] },
          }),
        ),
      /queue remains delayed/,
    );
  }
});
test('token budget retains the finite rate ceiling despite its offered-load diagnostic', () => {
  const f = ledgerSimulation({ ...carryInLedgerOptions, rate: 1100000 });
  f.snapshot.forwardRateSchedule.phases[1].forward.queue.configuration.rateBitsPerSecond = 750000;
  assert.throws(() => qualifyTokenBudget(f), /ceiling|budget/i);
});
test('token budget applies the selected 550k profile to carry-in work', () => {
  const f = ledgerSimulation({
    rate: 550000,
    schedule: requested,
    duration: 180000,
    forwardBursts: [],
    forwardInjections: [[59990, 20]],
  });
  const result = qualifyTokenBudget(f, { profile: 'capacity550k' });
  assert.equal(result.rateLedgerProof.rateBoundQualified, true);
  assert(result.maximumOfferedBitsPerSecond < 550000);
  assert.equal(result.offeredLoadRequired, false);
});
test('token budget composes with scheduled coverage and still rejects silent early termination', () => {
  const f = ledgerSimulation({ ...carryInLedgerOptions, duration: 250000, trafficUntil: 210000 });
  assert.equal(
    qualifyTokenBudget(f, { coveragePolicy: 'scheduled-hold-v1' }).rateLedgerProof
      .rateBoundQualified,
    true,
  );
  assert.throws(() => qualifyTokenBudget(f), /coverage/);
});
test('caller cannot replace the token policy with an offered-load override', () => {
  assert.throws(
    () =>
      module.qualifyMeasuredCapacityUplink(original, {
        offeredLoadRequired: false,
      }),
    /Unknown capacity qualifier option/,
  );
});
