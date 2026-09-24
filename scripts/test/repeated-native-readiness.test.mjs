import assert from 'node:assert/strict';
import test from 'node:test';
import { repeatedReceiverIntervalFixture } from './fixtures/repeated-receiver-interval-evidence.mjs';
const implementation = await import('../repeated-native-readiness.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});

// Component dependency contract only. Full policy replay must independently
// reconstruct these checkpoints before production code can call this join.
function fixture() {
  const f = repeatedReceiverIntervalFixture();
  const baselines = [
    f.quality.events[0],
    f.quality.events.find((e) => e.kind === 'applied' && e.revision === '2'),
  ];
  const windows = [
    [0, 3, 107, 112],
    [1, 10, 161, 166],
    [1, 11, 166, 171],
    [1, 12, 171, 172],
  ];
  const history = windows.map(([campaign, sequence, start, end]) => {
    const event = {
      ...structuredClone(baselines[campaign]),
      kind: 'evaluated',
      at: end + 0.1,
      evaluatedAt: end + 0.09,
      window: {
        sequence: String(sequence),
        revision: String(campaign * 2),
        start,
        end,
        observedAt: end + 0.05,
      },
    };
    f.quality.events.push(event);
    return { event, healthySince: campaign ? 161 : 107 };
  });
  f.quality.events.sort((a, b) => a.at - b.at);
  const healthHistory = history.map(({ event, healthySince }) => ({
    eventIndex: f.quality.events.indexOf(event),
    revision: event.revision,
    healthSequence: event.window.sequence,
    healthySince,
    healthyThrough: event.window.end,
  }));
  const healthyWindows = history.slice(1).map(({ event }) => ({
    eventIndex: f.quality.events.indexOf(event),
    policySequence: event.window.sequence,
    start: event.window.start,
    end: event.window.end,
    evaluatedAt: event.evaluatedAt,
  }));
  for (const [index, campaign] of f.probe.campaigns.entries()) {
    const checkpoint = healthHistory[index ? 3 : 0];
    Object.assign(campaign.context, {
      healthSequence: checkpoint.healthSequence,
      healthySince: checkpoint.healthySince,
      healthyThrough: checkpoint.healthyThrough,
    });
  }
  return {
    nativeProbe: f.probe,
    quality: f.quality,
    scope: f.scope,
    publishingGeneration: f.format.publishingGeneration,
    policyQualification: {
      scope: f.scope,
      rawEventCount: f.quality.events.length,
      healthHistory,
      recoveries: [
        {
          healthyWindows,
          sharedCoverage: {
            start: 161,
            end: 171,
            coverageSeconds: 10,
            qualifiedAt: 172.7,
            policyWindowSequences: ['10', '11'],
            sourceWindowSequences: ['10', '11'],
            windowCount: 2,
          },
        },
        {},
      ],
    },
  };
}
function qualify(f) {
  assert.equal(
    typeof implementation.qualifyRepeatedNativeReadiness,
    'function',
    'readiness join must exist',
  );
  return implementation.qualifyRepeatedNativeReadiness(f);
}
test('joins both original native probe contexts to independently replayed health', () => {
  const f = fixture(),
    before = structuredClone(f),
    result = qualify(f);
  assert.deepEqual(f, before);
  assert.equal(result.readinessQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.deepEqual(
    result.campaigns.map((c) => [c.campaign, c.appliedRevision, c.healthSequence]),
    [
      ['1', '0', '3'],
      ['2', '2', '12'],
    ],
  );
  assert.equal(result.campaigns[1].precedingRecoveryEnd, 171);
});
test('valid context may precede a newer health checkpoint during asynchronous begin', () => {
  const f = fixture();
  const prior = f.policyQualification.healthHistory.at(-1);
  const row = structuredClone(f.quality.events[prior.eventIndex]);
  row.at = 172.8;
  row.evaluatedAt = 172.79;
  row.window = { ...row.window, sequence: '13', start: 172, end: 172.75, observedAt: 172.78 };
  f.quality.events.splice(prior.eventIndex + 1, 0, row);
  f.policyQualification.rawEventCount++;
  f.policyQualification.healthHistory.push({
    ...prior,
    eventIndex: prior.eventIndex + 1,
    healthSequence: '13',
    healthyThrough: 172.75,
  });
  assert.equal(qualify(f).readinessQualified, true);
});
test('readiness can be captured after evaluation but before asynchronous event logging', () => {
  const f = fixture();
  f.quality.events[f.policyQualification.healthHistory.at(-1).eventIndex].at = 173.01;
  assert.equal(qualify(f).readinessQualified, true);
});

for (const changed of ['healthySince', 'missingCheckpoint']) {
  test(`readiness cannot survive intervening ${changed}`, () => {
    const f = fixture(),
      prior = f.policyQualification.healthHistory.at(-1);
    const row = structuredClone(f.quality.events[prior.eventIndex]);
    row.at = 172.8;
    row.evaluatedAt = 172.79;
    row.window = { ...row.window, sequence: '13', start: 172.1, end: 172.75, observedAt: 172.78 };
    f.quality.events.splice(prior.eventIndex + 1, 0, row);
    f.policyQualification.rawEventCount++;
    if (changed === 'healthySince')
      f.policyQualification.healthHistory.push({
        ...prior,
        eventIndex: prior.eventIndex + 1,
        healthSequence: '13',
        healthySince: 172.1,
        healthyThrough: 172.75,
      });
    assert.throws(() => qualify(f), /intervening/i);
  });
}

test('future delivery qualification cannot justify an earlier native probe', () => {
  const f = fixture();
  f.policyQualification.recoveries[0].sharedCoverage.qualifiedAt = 173.01;
  assert.throws(() => qualify(f), /recovery evidence/i);
});

const mutations = {
  'foreign scope': (f) => {
    f.policyQualification.scope = { ...f.scope, matchID: 'foreign' };
  },
  'truncated policy history': (f) => {
    f.policyQualification.rawEventCount--;
  },
  'missing health checkpoint': (f) => {
    f.policyQualification.healthHistory.pop();
  },
  'duplicate health checkpoint': (f) => {
    f.policyQualification.healthHistory.push(
      structuredClone(f.policyQualification.healthHistory.at(-1)),
    );
  },
  'invented healthy start': (f) => {
    f.nativeProbe.campaigns[1].context.healthySince -= 1;
  },
  'invented healthy end': (f) => {
    f.nativeProbe.campaigns[1].context.healthyThrough += 0.01;
  },
  'foreign health sequence': (f) => {
    f.nativeProbe.campaigns[1].context.healthSequence = '99';
  },
  'wrong acknowledgement': (f) => {
    f.nativeProbe.campaigns[1].context.acknowledgedAt += 0.01;
  },
  'wrong encoder': (f) => {
    f.nativeProbe.campaigns[1].context.encoderSessionID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  },
  'wrong configuration': (f) => {
    f.nativeProbe.campaigns[1].context.configurationID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  },
  'checkpoint not evaluated': (f) => {
    f.quality.events[f.policyQualification.healthHistory.at(-1).eventIndex].kind = 'transition';
  },
  'checkpoint raw sequence differs': (f) => {
    f.quality.events[f.policyQualification.healthHistory.at(-1).eventIndex].window.sequence = '99';
  },
  'checkpoint raw end differs': (f) => {
    f.quality.events[f.policyQualification.healthHistory.at(-1).eventIndex].window.end += 0.01;
  },
  'checkpoint raw revision differs': (f) => {
    f.quality.events[f.policyQualification.healthHistory.at(-1).eventIndex].window.revision = '0';
  },
  'health evaluated after probe start': (f) => {
    const r = f.quality.events[f.policyQualification.healthHistory.at(-1).eventIndex];
    r.evaluatedAt = 173.01;
    r.at = 173.02;
  },
  'stale receiver observation': (f) => {
    f.quality.events[f.policyQualification.healthHistory.at(-1).eventIndex].window.observedAt = 170;
  },
  'missing first recovery': (f) => {
    f.policyQualification.recoveries = [];
  },
  'short first recovery': (f) => {
    f.policyQualification.recoveries[0].sharedCoverage.coverageSeconds = 9;
  },
  'recovery after probe starts': (f) => {
    f.policyQualification.recoveries[0].sharedCoverage.end = 174;
  },
  'recovery not yet evaluated': (f) => {
    f.policyQualification.recoveries[0].healthyWindows[1].evaluatedAt = 173.01;
  },
  'selected health predates recovery': (f) => {
    f.policyQualification.recoveries[0].sharedCoverage.policyWindowSequences = ['12', '13'];
  },
  'missing credited recovery window': (f) => {
    f.policyQualification.recoveries[0].healthyWindows.splice(1, 1);
  },
  'forged current health receipt': (f) => {
    f.quality.events[
      f.policyQualification.healthHistory.at(-1).eventIndex
    ].receipt.configurationID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('readiness rejects invalidation evaluated before begin but serialized afterward', () => {
  const f = fixture();
  const origin = f.nativeProbe.campaigns[1].events[0].sample.campaignStartedAt;
  const event = {
    kind: 'rejected',
    reason: 'cadence-freshness',
    revision: '2',
    at: origin + 0.02,
    evaluationDiagnostic: {
      caughtAt: origin + 0.01,
      session: {
        evaluatedAt: origin - 0.01,
        cadenceReceiptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      },
    },
  };
  f.quality.events.push(event);
  f.quality.events.sort((a, b) => a.at - b.at);
  const eventIndex = f.quality.events.indexOf(event);
  f.policyQualification.rawEventCount++;
  f.policyQualification.invalidations = [
    {
      eventIndex,
      reportIndex: 7,
      nextReportIndex: 8,
      availableAt: origin + 0.05,
      receiptID: event.evaluationDiagnostic.session.cadenceReceiptID,
      revision: '2',
      evaluatedAt: origin - 0.01,
      caughtAt: origin + 0.01,
    },
  ];
  assert.throws(() => qualify(f), /invalidation|intervening/i);
});

test('readiness never infers a rejection proof from unqualified diagnostic metadata', () => {
  const f = fixture();
  const origin = f.nativeProbe.campaigns[1].events[0].sample.campaignStartedAt;
  f.quality.events.push({
    kind: 'rejected',
    reason: 'cadence-freshness',
    revision: '2',
    at: origin + 0.02,
    evaluationDiagnostic: { caughtAt: origin + 0.01, session: { evaluatedAt: origin - 0.01 } },
  });
  f.quality.events.sort((a, b) => a.at - b.at);
  f.policyQualification.rawEventCount++;
  assert.throws(() => qualify(f), /invalidation/i);
});

test('a qualified rejection evaluated after begin does not rewrite earlier readiness', () => {
  const f = fixture();
  const origin = f.nativeProbe.campaigns[1].events[0].sample.campaignStartedAt;
  const event = {
    kind: 'rejected',
    reason: 'cadence-freshness',
    revision: '2',
    at: origin + 0.04,
    evaluationDiagnostic: {
      caughtAt: origin + 0.03,
      session: {
        evaluatedAt: origin + 0.02,
        cadenceReceiptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      },
    },
  };
  f.quality.events.push(event);
  f.quality.events.sort((a, b) => a.at - b.at);
  f.policyQualification.rawEventCount++;
  f.policyQualification.invalidations = [
    {
      eventIndex: f.quality.events.indexOf(event),
      reportIndex: 7,
      nextReportIndex: 8,
      availableAt: origin + 0.05,
      receiptID: event.evaluationDiagnostic.session.cadenceReceiptID,
      revision: '2',
      evaluatedAt: origin + 0.02,
      caughtAt: origin + 0.03,
    },
  ];
  assert.equal(qualify(f).readinessQualified, true);
  const original = structuredClone(f.policyQualification.invalidations[0]);
  for (const change of [
    { evaluatedAt: origin + 0.01 },
    { caughtAt: origin + 0.04 },
    { revision: '4' },
    { receiptID: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' },
    { reportIndex: -1 },
  ]) {
    f.policyQualification.invalidations = [{ ...original, ...change }];
    assert.throws(() => qualify(f));
  }
  f.policyQualification.invalidations = [original, original];
  assert.throws(() => qualify(f), /duplicate/i);
});

test('readiness cannot count a recovery window beginning before fresh telemetry became available', () => {
  const f = fixture();
  const original = [...f.quality.events];
  const event = {
    kind: 'rejected',
    reason: 'cadence-freshness',
    revision: '2',
    at: 161,
    evaluationDiagnostic: {
      caughtAt: 160.99,
      session: { evaluatedAt: 160.9, cadenceReceiptID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' },
    },
  };
  f.quality.events.push(event);
  f.quality.events.sort((a, b) => a.at - b.at);
  for (const h of [
    ...f.policyQualification.healthHistory,
    ...f.policyQualification.recoveries[0].healthyWindows,
  ])
    h.eventIndex = f.quality.events.indexOf(original[h.eventIndex]);
  f.policyQualification.rawEventCount++;
  f.policyQualification.invalidations = [
    {
      eventIndex: f.quality.events.indexOf(event),
      reportIndex: 7,
      nextReportIndex: 8,
      availableAt: 161.05,
      receiptID: event.evaluationDiagnostic.session.cadenceReceiptID,
      revision: '2',
      evaluatedAt: 160.9,
      caughtAt: 160.99,
    },
  ];
  assert.throws(() => qualify(f), /availability|invalidation/i);
});

function sourceInvalidationFixture() {
  const f = fixture(),
    origin = f.nativeProbe.campaigns[1].events[0].sample.campaignStartedAt;
  const source = {
    workerEpoch: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    workerAttempt: 1,
    readerID: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    sequence: '20',
  };
  const event = {
    kind: 'rejected',
    reason: 'time',
    revision: '2',
    at: origin + 0.04,
    source,
    evaluationDiagnostic: {
      caughtAt: origin + 0.03,
      session: {
        kind: 'source',
        cadenceReceiptID: null,
        sourceKey: structuredClone(source),
        evaluatedAt: origin + 0.02,
      },
    },
  };
  f.quality.events.push(event);
  f.quality.events.sort((a, b) => a.at - b.at);
  f.policyQualification.rawEventCount++;
  f.policyQualification.invalidations = [
    {
      kind: 'source-expiry',
      eventIndex: f.quality.events.indexOf(event),
      sourceSequence: '20',
      sourceIndex: 7,
      proofIndex: 7,
      reportIndex: 20,
      nextReportIndex: 26,
      availableAt: origin + 0.05,
      revision: '2',
      evaluatedAt: origin + 0.02,
      caughtAt: origin + 0.03,
    },
  ];
  return f;
}
test('readiness joins source expiry to retained original report and later fresh replacement', () => {
  const f = sourceInvalidationFixture();
  assert.equal(qualify(f).readinessQualified, true);
});
test('readiness still validates a revision4 source invalidation after both admissions', () => {
  const f = sourceInvalidationFixture(),
    d = f.policyQualification.invalidations[0],
    e = f.quality.events[d.eventIndex];
  d.revision = e.revision = '4';
  assert.equal(qualify(f).readinessQualified, true);
  e.evaluationDiagnostic.session.sourceKey.sequence = '21';
  assert.throws(() => qualify(f));
});
test('source expiry before allocation invalidates an otherwise fresh readiness context', () => {
  const f = sourceInvalidationFixture(),
    d = f.policyQualification.invalidations[0],
    e = f.quality.events[d.eventIndex];
  d.evaluatedAt = e.evaluationDiagnostic.session.evaluatedAt =
    f.nativeProbe.campaigns[1].events[0].sample.campaignStartedAt - 0.001;
  assert.throws(() => qualify(f), /Intervening event invalidates native readiness/);
});
for (const [name, mutate] of [
  [
    'source sequence',
    (d) => {
      d.sourceSequence = '21';
    },
  ],
  [
    'source index',
    (d) => {
      d.sourceIndex = -1;
    },
  ],
  [
    'proof index',
    (d) => {
      d.proofIndex = -1;
    },
  ],
  [
    'report order',
    (d) => {
      d.nextReportIndex = d.reportIndex;
    },
  ],
  [
    'unknown descriptor kind',
    (d) => {
      d.kind = 'unknown';
    },
  ],
  [
    'event reason',
    (_, e) => {
      e.reason = 'cadence-freshness';
    },
  ],
  [
    'session kind',
    (_, e) => {
      e.evaluationDiagnostic.session.kind = 'cadence';
    },
  ],
  [
    'cadence receipt',
    (_, e) => {
      e.evaluationDiagnostic.session.cadenceReceiptID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    },
  ],
  [
    'source key',
    (_, e) => {
      e.evaluationDiagnostic.session.sourceKey.sequence = '21';
    },
  ],
])
  test(`source expiry readiness rejects mismatched ${name}`, () => {
    const f = sourceInvalidationFixture(),
      d = f.policyQualification.invalidations[0];
    mutate(d, f.quality.events[d.eventIndex]);
    assert.throws(() => qualify(f));
  });
