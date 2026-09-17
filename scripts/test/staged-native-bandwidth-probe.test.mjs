import assert from 'node:assert/strict';
import test from 'node:test';
import { nativeBandwidthProbe, qualifyNativeBandwidthProbe } from '../native-bandwidth-probe.mjs';

const scope = {
  recordingID: 'r',
  matchID: 'm',
  broadcastGeneration: 1,
  publishingAttemptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  appliedProfileRevision: '1',
};
const ids = [
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
];
const rates = [500_000, 1_000_000, 2_000_000];
function fixture(renewals = 2, step = 0.09) {
  const events = [];
  for (let index = 0; index < 3; index++) {
    const startedAt = 10 + index * (renewals * step + 0.03);
    const first = {
      id: ids[index],
      publishingGeneration: '7',
      stage: index + 1,
      bitRate: rates[index],
      startedAt,
      campaignStartedAt: 10,
      leaseDeadline: startedAt + 0.3,
      acceptedPayloadBytes: '0',
      totalAcceptedPayloadBytes: String(index * renewals * 1316),
      lastAcceptedAt: null,
      reason: null,
    };
    events.push({
      phase: index === 0 ? 'began' : 'replaced',
      observedAt: startedAt + 0.001,
      sample: first,
    });
    for (let n = 1; n <= renewals; n++)
      events.push({
        phase: 'renewed',
        observedAt: startedAt + n * step + 0.001,
        sample: {
          ...first,
          leaseDeadline: startedAt + n * step + 0.3,
          acceptedPayloadBytes: String(n * 1316),
          totalAcceptedPayloadBytes: String((index * renewals + n) * 1316),
          lastAcceptedAt: startedAt + n * step - 0.01,
        },
      });
    events.push({
      phase: 'retired',
      observedAt: startedAt + renewals * step + 0.02,
      retirementRequestedAt: startedAt + renewals * step + 0.01,
      sample: { ...events.at(-1).sample, reason: 'cancelled' },
    });
  }
  events.push({ phase: 'final', observedAt: 100, sample: { ...events.at(-1).sample } });
  return {
    formatVersion: 2,
    isClosed: true,
    invalid: false,
    mode: 'staged',
    result: 'completed',
    scope: { ...scope },
    publishingGeneration: '7',
    events,
  };
}
const qualify = (value) =>
  qualifyNativeBandwidthProbe(value, { mode: 'staged', scope, publishingGeneration: '7' });
const stageEvents = (value, stage) => value.events.filter((event) => event.sample.stage === stage);
const mutateStage = (value, stage, change) => {
  for (const event of stageEvents(value, stage)) change(event.sample, event);
};

test('combined headroom schedule is explicit and cannot replace the historical schedule implicitly', () => {
  const value = fixture();
  for (const event of value.events)
    event.sample.bitRate = [500_000, 2_000_000, 12_000_000][event.sample.stage - 1];
  const result = qualifyNativeBandwidthProbe(value, {
    mode: 'staged',
    scope,
    publishingGeneration: '7',
    candidateHeadroom: true,
  });
  assert.equal(result.schedule, 'candidate-headroom-v1');
  assert.deepEqual(
    result.stages.map((s) => s.bitRate),
    [500_000, 2_000_000, 12_000_000],
  );
  assert.throws(() => qualify(value));
  assert.throws(() =>
    qualifyNativeBandwidthProbe(fixture(), {
      mode: 'staged',
      scope,
      publishingGeneration: '7',
      candidateHeadroom: true,
    }),
  );
});

test('staged mode retains every exclusive fixed540 full-pipeline admission condition', () => {
  const input = {
    environment: {
      SCOREBUG_TEST_BANDWIDTH_PROBE: 'staged',
      SCOREBUG_TEST_LIVE_PROFILE: '540p30',
      SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
      SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
    },
    streaming: true,
    requireProcessing: true,
    requirePublication: true,
    holdSeconds: 90,
    liveProfile: '540p30',
  };
  assert.equal(nativeBandwidthProbe(input), 'staged');
  for (const key of ['streaming', 'requireProcessing', 'requirePublication'])
    assert.throws(() => nativeBandwidthProbe({ ...input, [key]: false }));
  for (const holdSeconds of [89, 601, 90.5, NaN])
    assert.throws(() => nativeBandwidthProbe({ ...input, holdSeconds }));
  for (const key of [
    'SCOREBUG_TEST_NATIVE_QUALITY',
    'SCOREBUG_TEST_NATIVE_CONFIRMATION',
    'SCOREBUG_TEST_ADAPTIVE_PROFILES',
    'SCOREBUG_TEST_PROFILE_TRANSITIONS',
    'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
  ])
    assert.throws(() =>
      nativeBandwidthProbe({ ...input, environment: { ...input.environment, [key]: '1' } }),
    );
  for (const [key, value] of [
    ['SCOREBUG_TEST_LIVE_PROFILE', '360p30'],
    ['SCOREBUG_TEST_MOTION_FIXTURE', 'other'],
    ['SCOREBUG_TEST_DIRECT_RTMP_RECORDER', '0'],
  ])
    assert.throws(() =>
      nativeBandwidthProbe({ ...input, environment: { ...input.environment, [key]: value } }),
    );
  assert.throws(() => nativeBandwidthProbe({ ...input, liveProfile: '360p30' }));
});

test('completed three-stage v2 proof produces the exact local-only summary', () => {
  const value = fixture();
  assert.deepEqual(qualify(value), {
    mode: 'staged',
    publishingGeneration: '7',
    acceptedPayloadBytes: 7896,
    totalAcceptedPayloadBytes: 7896,
    stages: value.events
      .filter((event) => event.phase === 'retired')
      .map((event) => ({
        stage: event.sample.stage,
        id: event.sample.id,
        publishingGeneration: '7',
        bitRate: event.sample.bitRate,
        startedAt: event.sample.startedAt,
        campaignStartedAt: 10,
        acceptedPayloadBytes: 2632,
        totalAcceptedPayloadBytes: event.sample.stage * 2632,
        lastAcceptedAt: event.sample.lastAcceptedAt,
        retirementRequestedAt: event.retirementRequestedAt,
        retiredObservedAt: event.observedAt,
        reason: 'cancelled',
      })),
    eventCount: 13,
    receiverCapacityQualified: false,
  });
});
test('607 events are bounded and valid across a single campaign', () => {
  assert.equal(qualify(fixture(200)).eventCount, 607);
});
test('one renewal per stage suffices and retired proof may be exported after campaign expiry', () => {
  assert.equal(qualify(fixture(1)).stages.length, 3);
});
test('UUID identity is case-insensitive and historical reuse at a new ordinal is legal', () => {
  const value = fixture();
  mutateStage(value, 3, (sample) => {
    sample.id = ids[0];
  });
  value.events[1].sample.id = ids[0].toUpperCase();
  assert.equal(qualify(value).stages[2].id, ids[0]);
});

function idleThenBurst(messages) {
  const value = fixture(12),
    difference = (messages - 12) * 1316;
  for (let index = 1; index <= 13; index++) {
    const sample = value.events[index].sample,
      accepted = index >= 12 ? messages * 1316 : 0;
    sample.acceptedPayloadBytes = sample.totalAcceptedPayloadBytes = String(accepted);
    if (accepted === 0) sample.lastAcceptedAt = null;
  }
  for (const event of value.events.filter((event) => event.sample.stage > 1))
    event.sample.totalAcceptedPayloadBytes = String(
      Number(event.sample.totalAcceptedPayloadBytes) + difference,
    );
  return value;
}
test('token bucket cannot accumulate a 44-message burst across idle renewals', () => {
  assert.throws(() => qualify(idleThenBurst(44)), /Staged probe.*token/);
});
test('token bucket permits one buffered message plus elapsed offered-rate credit', () => {
  assert.equal(qualify(idleThenBurst(4)).stages[0].acceptedPayloadBytes, 4 * 1316);
  assert.throws(() => qualify(idleThenBurst(5)), /Staged probe.*token/);
});
test('token window uses the native instant when observation is delayed after the snapshot', () => {
  const value = idleThenBurst(4);
  value.events[11].observedAt = value.events[12].sample.lastAcceptedAt + 0.005;
  assert.equal(qualify(value).stages[0].acceptedPayloadBytes, 4 * 1316);
});
test('repeated observations cannot replenish the one-message token allowance', () => {
  const repeatedBurst = (messagesPerRenewal) => {
    const value = fixture(24, 0.1),
      total = messagesPerRenewal * 10 * 1316;
    let lastAcceptedAt = null;
    for (let index = 1; index <= 25; index++) {
      const sample = value.events[index].sample;
      const accepted = Math.min(10, Math.max(0, index - 10)) * messagesPerRenewal * 1316;
      if (index > 10 && index <= 20) lastAcceptedAt = sample.lastAcceptedAt;
      sample.acceptedPayloadBytes = sample.totalAcceptedPayloadBytes = String(accepted);
      sample.lastAcceptedAt = lastAcceptedAt;
    }
    for (const event of value.events.filter((event) => event.sample.stage > 1))
      event.sample.totalAcceptedPayloadBytes = String(
        Number(event.sample.totalAcceptedPayloadBytes) + total - 24 * 1316,
      );
    return value;
  };
  assert.equal(qualify(repeatedBurst(4)).stages[0].acceptedPayloadBytes, 40 * 1316);
  // Each 100-ms delta can fit five messages plus a token, and the initial
  // idle second makes the start-average plausible. The complete window from
  // the empty snapshot at t=11 to last acceptance at t=11.99 allows only 46.
  assert.throws(() => qualify(repeatedBurst(5)), /Staged probe.*token/);
});
test('cancelled stage cannot report new acceptance exactly at its lease deadline', () => {
  const value = fixture(),
    retired = value.events.at(-2);
  retired.sample.acceptedPayloadBytes = String(Number(retired.sample.acceptedPayloadBytes) + 1316);
  retired.sample.totalAcceptedPayloadBytes = String(
    Number(retired.sample.totalAcceptedPayloadBytes) + 1316,
  );
  retired.sample.lastAcceptedAt = retired.sample.leaseDeadline;
  retired.retirementRequestedAt = retired.sample.leaseDeadline + 0.001;
  retired.observedAt = retired.sample.leaseDeadline + 0.002;
  value.events.at(-1).sample = { ...retired.sample };
  assert.throws(() => qualify(value), /Staged probe.*acceptance outside/);
});

const mutations = {
  version1: (x) => {
    x.formatVersion = 1;
  },
  version3: (x) => {
    x.formatVersion = 3;
  },
  stringVersion: (x) => {
    x.formatVersion = '2';
  },
  open: (x) => {
    x.isClosed = false;
  },
  invalid: (x) => {
    x.invalid = true;
  },
  withdrawn: (x) => {
    x.result = 'withdrawn';
  },
  wrongMode: (x) => {
    x.mode = 'renew';
  },
  wrongScope: (x) => {
    x.scope.recordingID = 'other';
  },
  wrongGeneration: (x) => {
    x.publishingGeneration = '8';
  },
  sampleGeneration: (x) => {
    x.events[1].sample.publishingGeneration = '8';
  },
  missingStage: (x) => {
    x.events = x.events.filter((e) => e.sample.stage !== 2);
  },
  wrongOrdinal: (x) => {
    mutateStage(x, 2, (s) => {
      s.stage = 4;
    });
  },
  stringOrdinal: (x) => {
    mutateStage(x, 2, (s) => {
      s.stage = '2';
    });
  },
  wrongRate: (x) => {
    mutateStage(x, 2, (s) => {
      s.bitRate = 500_000;
    });
  },
  changedCurrentID: (x) => {
    x.events[1].sample.id = ids[1];
  },
  reusedPreviousID: (x) => {
    mutateStage(x, 2, (s) => {
      s.id = ids[0];
    });
  },
  malformedID: (x) => {
    mutateStage(x, 1, (s) => {
      s.id = 'invalid';
    });
  },
  changedStartedAt: (x) => {
    x.events[1].sample.startedAt += 0.01;
  },
  changedCampaign: (x) => {
    mutateStage(x, 2, (s) => {
      s.campaignStartedAt += 0.1;
    });
  },
  wrongFirstOrigin: (x) => {
    for (const e of x.events) e.sample.campaignStartedAt = 9;
  },
  futureStartedAt: (x) => {
    x.events[0].sample.startedAt = 11;
  },
  overlappingStage: (x) => {
    mutateStage(x, 2, (s) => {
      s.startedAt = x.events[3].observedAt - 0.01;
    });
  },
  campaignReset: (x) => {
    mutateStage(x, 3, (s) => {
      s.startedAt += 60;
      s.campaignStartedAt = s.startedAt;
    });
  },
  stageAfterCampaign: (x) => {
    mutateStage(x, 3, (s, e) => {
      s.startedAt += 60;
      s.leaseDeadline += 60;
      if (s.lastAcceptedAt !== null) s.lastAcceptedAt += 60;
      e.observedAt += 60;
      if (e.retirementRequestedAt !== undefined) e.retirementRequestedAt += 60;
    });
  },
  observedNaN: (x) => {
    x.events[1].observedAt = NaN;
  },
  observedInfinity: (x) => {
    x.events[1].observedAt = Infinity;
  },
  observedReversal: (x) => {
    x.events[1].observedAt = 9;
  },
  negativeOrigin: (x) => {
    for (const e of x.events) e.sample.campaignStartedAt = -1;
  },
  infiniteLease: (x) => {
    x.events[1].sample.leaseDeadline = Infinity;
  },
  initialLease: (x) => {
    x.events[0].sample.leaseDeadline += 0.01;
  },
  replacementLease: (x) => {
    x.events[4].sample.leaseDeadline += 0.01;
  },
  leaseReversal: (x) => {
    x.events[2].sample.leaseDeadline = x.events[0].sample.leaseDeadline;
  },
  futureRenewal: (x) => {
    x.events[1].sample.leaseDeadline += 0.1;
  },
  pastRenewal: (x) => {
    x.events[1].sample.leaseDeadline = x.events[0].sample.leaseDeadline;
  },
  revivedLease: (x) => {
    x.events[1].observedAt += 0.5;
    x.events[1].sample.leaseDeadline += 0.5;
  },
  terminalRenewal: (x) => {
    x.events[3].sample.leaseDeadline += 0.01;
  },
  futureAcceptance: (x) => {
    x.events[1].sample.lastAcceptedAt = x.events[1].observedAt + 0.01;
  },
  acceptanceBeforeStart: (x) => {
    x.events[1].sample.lastAcceptedAt = 9;
  },
  lateAcceptance: (x) => {
    x.events[3].observedAt = 11;
    x.events[3].sample.lastAcceptedAt = 10.8;
  },
  acceptanceNaN: (x) => {
    x.events[1].sample.lastAcceptedAt = NaN;
  },
  acceptanceReversal: (x) => {
    x.events[2].sample.lastAcceptedAt = x.events[1].sample.lastAcceptedAt - 0.01;
  },
  equalCountTimeFabrication: (x) => {
    x.events[3].sample.lastAcceptedAt += 0.001;
  },
  noInitialBurst: (x) => {
    x.events[1].sample.lastAcceptedAt = 10.001;
  },
  accountedOverhead: (x) => {
    x.events[1].sample.lastAcceptedAt = 10 + (1316 * 8) / 500_000;
  },
  excessivePacedCount: (x) => {
    x.events[1].sample.acceptedPayloadBytes = '131600';
    x.events[1].sample.totalAcceptedPayloadBytes = '131600';
  },
  localCounterNumber: (x) => {
    x.events[1].sample.acceptedPayloadBytes = 1316;
  },
  totalCounterNumber: (x) => {
    x.events[1].sample.totalAcceptedPayloadBytes = 1316;
  },
  leadingZero: (x) => {
    x.events[1].sample.acceptedPayloadBytes = '01316';
  },
  totalLeadingZero: (x) => {
    x.events[1].sample.totalAcceptedPayloadBytes = '01316';
  },
  negativeCounter: (x) => {
    x.events[1].sample.acceptedPayloadBytes = '-1316';
  },
  fractionalCounter: (x) => {
    x.events[1].sample.acceptedPayloadBytes = '1316.0';
  },
  exponentCounter: (x) => {
    x.events[1].sample.totalAcceptedPayloadBytes = '1e3';
  },
  uint64Overflow: (x) => {
    x.events[1].sample.totalAcceptedPayloadBytes = '18446744073709551616';
  },
  counterNotPacketAligned: (x) => {
    x.events[1].sample.acceptedPayloadBytes = '1317';
  },
  totalNotPacketAligned: (x) => {
    x.events[1].sample.totalAcceptedPayloadBytes = '1317';
  },
  cumulativeCap: (x) => {
    x.events[1].sample.totalAcceptedPayloadBytes = String(1316 * 12749);
  },
  localCap: (x) => {
    x.events[1].sample.acceptedPayloadBytes = String(1316 * 12749);
  },
  localExceedsTotal: (x) => {
    x.events[1].sample.totalAcceptedPayloadBytes = '0';
  },
  initialAcceptance: (x) => {
    x.events[0].sample.acceptedPayloadBytes = '1316';
    x.events[0].sample.lastAcceptedAt = 10;
  },
  initialCumulative: (x) => {
    for (const e of x.events)
      e.sample.totalAcceptedPayloadBytes = String(
        BigInt(e.sample.totalAcceptedPayloadBytes) + 1316n,
      );
  },
  replacementNonzero: (x) => {
    x.events[4].sample.acceptedPayloadBytes = '1316';
    x.events[4].sample.lastAcceptedAt = x.events[4].sample.startedAt;
  },
  cumulativeReset: (x) => {
    mutateStage(x, 2, (s) => {
      s.totalAcceptedPayloadBytes = s.acceptedPayloadBytes;
    });
  },
  cumulativeJump: (x) => {
    mutateStage(x, 2, (s) => {
      s.totalAcceptedPayloadBytes = String(BigInt(s.totalAcceptedPayloadBytes) + 1316n);
    });
  },
  deltaMismatch: (x) => {
    x.events[2].sample.totalAcceptedPayloadBytes = '3948';
  },
  counterReversal: (x) => {
    x.events[2].sample.acceptedPayloadBytes = '0';
    x.events[2].sample.totalAcceptedPayloadBytes = '0';
    x.events[2].sample.lastAcceptedAt = null;
  },
  missingAcceptanceTime: (x) => {
    x.events[1].sample.lastAcceptedAt = null;
  },
  zeroCounterWithTime: (x) => {
    x.events[0].sample.lastAcceptedAt = 10;
  },
  stageWithoutAcceptance: (x) => {
    mutateStage(x, 1, (s) => {
      s.acceptedPayloadBytes = '0';
      s.totalAcceptedPayloadBytes = '0';
      s.lastAcceptedAt = null;
    });
  },
  retirementReason: (x) => {
    x.events[3].sample.reason = 'leaseExpired';
  },
  activeRetirement: (x) => {
    x.events[3].sample.reason = null;
  },
  prematureTerminal: (x) => {
    x.events[1].sample.reason = 'cancelled';
  },
  missingRetirementInstant: (x) => {
    delete x.events[3].retirementRequestedAt;
  },
  retirementNaN: (x) => {
    x.events[3].retirementRequestedAt = NaN;
  },
  retirementBeforePriorObservation: (x) => {
    x.events[3].retirementRequestedAt = x.events[2].observedAt - 0.001;
  },
  retirementAfterObservation: (x) => {
    x.events[3].retirementRequestedAt = x.events[3].observedAt + 0.001;
  },
  spuriousRetirementInstant: (x) => {
    x.events[1].retirementRequestedAt = x.events[1].observedAt;
  },
  nullRetirementInstantOutsideRetirement: (x) => {
    x.events[0].retirementRequestedAt = null;
  },
  missingRenewal: (x) => {
    x.events = x.events.filter((e, i) => i !== 1 && i !== 2);
  },
  missingRetirement: (x) => {
    x.events.splice(3, 1);
  },
  missingFinal: (x) => {
    x.events.pop();
  },
  extraFinal: (x) => {
    x.events.push(structuredClone(x.events.at(-1)));
  },
  extraAfterFinal: (x) => {
    x.events.push(structuredClone(x.events[0]));
  },
  unknownPhase: (x) => {
    x.events[1].phase = 'observed';
  },
  wrongFirstPhase: (x) => {
    x.events[0].phase = 'replaced';
  },
  wrongReplacementPhase: (x) => {
    x.events[4].phase = 'began';
  },
  finalNewAcceptance: (x) => {
    x.events.at(-1).sample.acceptedPayloadBytes = '3948';
    x.events.at(-1).sample.totalAcceptedPayloadBytes = '9212';
  },
  finalChangedTime: (x) => {
    x.events.at(-1).sample.lastAcceptedAt += 0.001;
  },
  finalChangedLease: (x) => {
    x.events.at(-1).sample.leaseDeadline += 0.001;
  },
  finalExtraSampleField: (x) => {
    x.events.at(-1).sample.extra = true;
  },
  tooManyEvents: (x) => {
    x.events = Array.from({ length: 608 }, () => structuredClone(x.events[0]));
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`staged proof rejects ${name}`, () => {
    const value = fixture();
    mutate(value);
    assert.throws(() => qualify(value), /Staged probe/);
  });

for (const key of ['stage', 'campaignStartedAt', 'totalAcceptedPayloadBytes']) {
  test(`v1 cannot silently discard ${key} metadata`, () => {
    const value = fixture(1);
    value.formatVersion = 1;
    value.mode = 'renew';
    value.events = value.events.slice(3, 6);
    value.events[0].phase = 'began';
    value.events[2].phase = 'final';
    for (const event of value.events) {
      delete event.retirementRequestedAt;
      delete event.sample.stage;
      delete event.sample.campaignStartedAt;
      delete event.sample.totalAcceptedPayloadBytes;
    }
    const options = { mode: 'renew', scope, publishingGeneration: '7' };
    assert.equal(qualifyNativeBandwidthProbe(value, options).acceptedPayloadBytes, 1316);
    value.events[1].sample[key] = null;
    assert.throws(() => qualifyNativeBandwidthProbe(value, options), /v1.*metadata/);
  });
}
