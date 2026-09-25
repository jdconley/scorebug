import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyCapacityClockBrackets } from '../capacity-clock-brackets.mjs';
const implementation = await import('../capacity-clock-schedule.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
function fixture(profile = 'capacity550k') {
  let time = 1000,
    latest;
  const scope = {
    recordingID: 'recording',
    matchID: 'match',
    broadcastGeneration: 1,
    publishingAttemptID: '11111111-1111-4111-8111-111111111111',
    appliedProfileRevision: '1',
  };
  const requested = [
    { atMilliseconds: 0, rateBitsPerSecond: null },
    {
      atMilliseconds: profile === 'capacity750k' ? 90000 : 60000,
      rateBitsPerSecond: profile === 'capacity750k' ? 750000 : 550000,
    },
    { atMilliseconds: profile === 'capacity750k' ? 150000 : 120000, rateBitsPerSecond: null },
  ];
  const phases = requested.map((phase, index) => ({
    ...phase,
    appliedAt: 1000 + phase.atMilliseconds + (index ? 20 : 0),
  }));
  const audit = {
    formatVersion: 1,
    scope,
    maximumSamples: 4,
    closed: true,
    invalid: false,
    overflow: false,
    samples: [],
  };
  const abort = new AbortController();
  const options = {
    profile,
    scope,
    signal: abort.signal,
    now: () => time,
    snapshot: () => ({
      forwardRateSchedule: {
        requested: structuredClone(requested),
        startedAt: 1000,
        stoppedAt: null,
        phases: phases
          .filter((p) => p.appliedAt <= time)
          .map((p) => ({ ...p, forward: {}, reverse: {} })),
      },
    }),
    wait: async (ms) => {
      time += ms;
    },
    write: async (request) => {
      time += 5;
      latest = {
        formatVersion: 1,
        scope: structuredClone(scope),
        sample: {
          sequence: request.sequence,
          nonce: request.nonce,
          nativeAt: 900000 + time / 1000,
        },
      };
      audit.samples.push(structuredClone(latest.sample));
    },
    read: async () => {
      time += 5;
      return structuredClone(latest);
    },
  };
  return {
    options,
    abort,
    audit,
    requested,
    phases,
    setTime: (n) => (time = n),
    advance: (n) => (time += n),
    time: () => time,
  };
}
async function collect(options) {
  assert.equal(typeof implementation.collectCapacityClockExchanges, 'function');
  return implementation.collectCapacityClockExchanges(options);
}
test('scheduler brackets both actual proxy changes and composes with independent native replay', async () => {
  const f = fixture(),
    result = await collect(f.options);
  assert.equal(result.exchanges.length, 4);
  assert.equal(result.nativeAdaptationQualified, false);
  assert.equal(result.clockBracketsQualified, false);
  const replay = qualifyCapacityClockBrackets({
    scope: f.options.scope,
    exchanges: result.exchanges,
    schedule: { requested: f.requested, startedAt: 1000, stoppedAt: 181000, phases: f.phases },
    nativeAudit: f.audit,
  });
  assert.equal(replay.clockBracketsQualified, true);
  assert.equal(replay.nativeAdaptationQualified, false);
  assert.equal(result.exchanges[0].requestAt, 60500);
  assert(result.exchanges[1].requestAt >= 61020);
  assert.equal(result.exchanges[2].requestAt, 120500);
  assert(result.exchanges[3].requestAt >= 121020);
});
test('scheduler never changes the independently running proxy rate schedule', async () => {
  const f = fixture(),
    before = structuredClone(f.requested),
    phases = structuredClone(f.phases);
  await collect(f.options);
  assert.deepEqual(f.requested, before);
  assert.deepEqual(f.phases, phases);
});
for (const [name, change] of Object.entries({
  'missing origin': (s) => (s.startedAt = null),
  'closed proxy': (s) => (s.stoppedAt = 2000),
  'wrong requested rate': (s) => (s.requested[1].rateBitsPerSecond = 1),
  'missing initial phase': (s) => (s.phases = []),
  'future initial phase': (s) => (s.phases[0].appliedAt = 1001),
}))
  test(`scheduler rejects ${name} before sending challenges`, async () => {
    const f = fixture(),
      snapshot = f.options.snapshot;
    f.options.snapshot = () => {
      const value = snapshot();
      change(value.forwardRateSchedule);
      return value;
    };
    await assert.rejects(collect(f.options));
    assert.equal(f.audit.samples.length, 0);
  });
test('a late observer cannot manufacture the missing before sample', async () => {
  const f = fixture();
  f.setTime(60751);
  await assert.rejects(collect(f.options));
  assert.equal(f.audit.samples.length, 0);
});
test('late pre-fault response fails instead of renewing a challenge deadline', async () => {
  const f = fixture(),
    read = f.options.read;
  f.options.read = async () => {
    f.advance(251);
    return read();
  };
  await assert.rejects(collect(f.options));
  assert.equal(f.audit.samples.length, 1);
});
test('missing applied phase fails within the bracket without sending the after request', async () => {
  const f = fixture();
  f.phases[1].appliedAt = Infinity;
  await assert.rejects(collect(f.options));
  assert.equal(f.audit.samples.length, 1);
  assert(f.time() <= 62020);
});
test('a phase later than the bracket budget cannot be accepted merely because its schedule tolerance allows it', async () => {
  const f = fixture();
  f.phases[1].appliedAt = 62800;
  await assert.rejects(collect(f.options));
  assert.equal(f.audit.samples.length, 1);
});
test('changed original start or already observed phase fails closed', async () => {
  for (const mutate of [(s) => s.startedAt++, (s) => s.phases[0].appliedAt++]) {
    const f = fixture(),
      snapshot = f.options.snapshot;
    f.options.snapshot = () => {
      const value = snapshot();
      if (f.time() > 61020) mutate(value.forwardRateSchedule);
      return value;
    };
    await assert.rejects(collect(f.options));
  }
});
test(
  'cancellation during an awaited request joins the write and sends no later request',
  { timeout: 2000 },
  async () => {
    const f = fixture(),
      write = f.options.write;
    let release,
      started,
      joined = false;
    const began = new Promise((resolve) => (started = resolve));
    f.options.write = async (request) => {
      started();
      await new Promise((resolve) => (release = resolve));
      await write(request);
      joined = true;
    };
    let ended = false;
    const result = collect(f.options).finally(() => (ended = true));
    const rejected = assert.rejects(result);
    await Promise.race([began, result]);
    f.abort.abort();
    await Promise.resolve();
    assert.equal(ended, false);
    assert.equal(joined, false);
    release();
    await rejected;
    assert.equal(joined, true);
    assert.equal(f.audit.samples.length, 1);
  },
);
test('stationary or regressing host clocks cannot create unbounded waits', async () => {
  for (const shift of [0, -1]) {
    const f = fixture();
    let waits = 0;
    f.options.wait = async () => {
      waits++;
      f.advance(shift);
    };
    await assert.rejects(collect(f.options));
    assert(waits <= 256);
    assert.equal(f.audit.samples.length, 0);
  }
});

test('explicit750k clock scheduler and independent replay bracket90/150s changes', async () => {
  const f = fixture('capacity750k'),
    result = await collect(f.options);
  assert.equal(result.exchanges[0].requestAt, 90500);
  assert.equal(result.exchanges[2].requestAt, 150500);
  const args = {
    profile: 'capacity750k',
    scope: f.options.scope,
    exchanges: result.exchanges,
    nativeAudit: f.audit,
    schedule: { requested: f.requested, startedAt: 1000, stoppedAt: 211100, phases: f.phases },
  };
  assert.equal(qualifyCapacityClockBrackets(args).clockBracketsQualified, true);
  assert.throws(() => qualifyCapacityClockBrackets({ ...args, profile: undefined }));
  assert.throws(() =>
    qualifyCapacityClockBrackets({ ...args, schedule: { ...args.schedule, stoppedAt: 181000 } }),
  );
  await assert.rejects(() => collect({ ...fixture('capacity750k').options, profile: undefined }));
});
