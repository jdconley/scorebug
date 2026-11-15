import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
const { qualifyMeasuredTrialPolicy } = await import('../measured-trial-policy.mjs').catch(
  () => ({}),
);
const fixture = () =>
  JSON.parse(
    fs.readFileSync(new URL('./fixtures/measured-trial-policy-diagnostic.json', import.meta.url)),
  );
const applied = (f) => f.quality.events.find((e) => e.kind === 'applied');
const probation = (f) =>
  f.quality.events.filter((e) => e.kind === 'evaluated' && e.revision === '1');
test('replays actual selected baseline, native application and contiguous probation without authorizing production', () => {
  assert.equal(typeof qualifyMeasuredTrialPolicy, 'function', 'measured policy replay must exist');
  const result = qualifyMeasuredTrialPolicy(fixture());
  assert.equal(result.confirmed, 1);
  assert.equal(result.trials, 1);
  assert.equal(result.upgradeAuthorized, false);
  assert.equal(result.baselineWindowSequence, '6');
  assert(result.probation.coverageSeconds >= 10);
  assert.equal(result.probation.windows, 3);
});
for (const [name, mutate] of [
  [
    'baseline failure episode cannot use initial recovery budget',
    (f) => {
      const e = f.quality.events.find((e) => e.kind === 'evaluated');
      e.evidence.thermal.samples.forEach((s) => (s.state = 2));
      e.window.thermal = 'elevated';
    },
  ],
  [
    'ignored rollback reason',
    (f) => {
      probation(f)[0].reasons.push('trialRollback');
    },
  ],
  [
    'forged early confirmation',
    (f) => {
      probation(f)[0].reasons.push('trialConfirmed');
    },
  ],
  [
    'short probation',
    (f) => {
      f.quality.events = f.quality.events.filter((e) => e !== probation(f)[1]);
    },
  ],
  [
    'stale probation',
    (f) => {
      probation(f)[0].evaluatedAt = probation(f)[0].window.end + 2.01;
    },
  ],
  [
    'rejected telemetry during probation',
    (f) => {
      const e = probation(f)[1];
      f.quality.events.splice(f.quality.events.indexOf(e), 0, {
        ...e,
        kind: 'rejected',
        reasons: [],
      });
    },
  ],
  [
    'reset after application',
    (f) => {
      applied(f).action.kind = 'reset';
    },
  ],
  [
    'altered worker ownership',
    (f) => {
      probation(f)[0].source.workerEpoch = '00000000-0000-4000-8000-000000000001';
    },
  ],
  [
    'altered processing ownership',
    (f) => {
      probation(f)[0].source.processingScopeID = 'other';
    },
  ],
  [
    'altered revision',
    (f) => {
      probation(f)[0].window.revision = '0';
    },
  ],
  [
    'altered native configuration',
    (f) => {
      probation(f)[0].receipt.configurationID = '00000000-0000-4000-8000-000000000001';
    },
  ],
  [
    'altered selected baseline',
    (f) => {
      applied(f).application.windowSequence = '5';
    },
  ],
  [
    'altered pressure samples',
    (f) => {
      probation(f)[0].evidence.thermal.samples.forEach((s) => (s.state = 2));
    },
  ],
  [
    'hidden nonhealthy pressure',
    (f) => {
      const e = probation(f)[0];
      e.evidence.thermal.samples.forEach((s) => (s.state = 2));
      e.window.thermal = 'elevated';
    },
  ],
  [
    'altered bootstrap rate',
    (f) => {
      f.quality.events[0].receipt.bitRate = 600000;
    },
  ],
  [
    'missing profile proof',
    (f) => {
      f.profileQualification = { qualified: true };
    },
  ],
  [
    'missing lifecycle proof',
    (f) => {
      f.lifecycleQualification = { qualified: true };
    },
  ],
  [
    'missing witness details',
    (f) => {
      f.candidateWitnessQualification = { qualified: true };
    },
  ],
  [
    'late native acknowledgment',
    (f) => {
      applied(f).acknowledgedAt = applied(f).application.completionDeadline + 0.01;
    },
  ],
  [
    'cadence stale reporting',
    (f) => {
      f.cadenceReports.rows.forEach((r) => (r.sampleAgeSeconds = 2));
    },
  ],
  [
    'cadence changed reader',
    (f) => {
      f.cadenceReports.rows.forEach((r) => (r.response.status.publication.readerId = 'other'));
    },
  ],
  [
    'transition credited as healthy',
    (f) => {
      const e = f.quality.events.find((e) => e.kind === 'transition');
      e.reasons = ['trialConfirmed'];
    },
  ],
  [
    'missing actual confirmation',
    (f) => {
      probation(f).forEach((e) => (e.reasons = e.reasons.filter((r) => r !== 'trialConfirmed')));
    },
  ],
])
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifyMeasuredTrialPolicy(f));
  });

test('cadence freshness includes time between the audit and policy decision', () => {
  const f = fixture();
  const decision = probation(f)[0];
  const report = f.cadenceReports.rows.findLast((r) => r.evaluatedUptime <= decision.evaluatedAt);
  const decisionDelay = decision.evaluatedAt - report.evaluatedUptime;
  report.response.status.decoderCadenceAgeUpperBoundMs = 240;
  report.requestSeconds = 0.001;
  report.residenceSeconds = 0.001;
  report.sampleAgeSeconds = 0.242;
  assert(decisionDelay > 0 && decisionDelay < 0.25);
  assert(report.sampleAgeSeconds <= 0.25);
  assert(report.sampleAgeSeconds + decisionDelay > 0.25);
  assert.throws(() => qualifyMeasuredTrialPolicy(f), /Cadence evidence exceeds decision freshness/);
});

const intermediateCadence = (f) => {
  const first = probation(f)[0].evaluatedAt;
  const second = probation(f)[1].evaluatedAt;
  return f.cadenceReports.rows.find(
    (r) => r.evaluatedUptime > first + 1 && r.evaluatedUptime < second - 1,
  );
};
for (const [name, mutate] of [
  [
    'fresh stall',
    (r) => {
      r.observedStall = true;
      r.response.status.observation.decoderCadence.progress.stalled = true;
      r.response.status.observation.decoderCadence.progress.ageMs = 1001;
    },
  ],
  [
    'unavailable helper',
    (r) => {
      r.sampleAgeSeconds = null;
      r.observedStall = null;
    },
  ],
  [
    'worker ownership change',
    (r) => {
      r.response.status.workerEpoch = '00000000-0000-4000-8000-000000000001';
    },
  ],
  [
    'reader ownership change',
    (r) => {
      r.response.status.publication.readerId = '00000000-0000-4000-8000-000000000001';
    },
  ],
  [
    'decoder scope change',
    (r) => {
      r.response.status.observation.decoderCadence.scopeID = '00000000-0000-4000-8000-000000000001';
    },
  ],
  [
    'decoder progress regression',
    (r) => {
      r.response.status.observation.decoderCadence.progress.lastFreshPTS = 0;
    },
  ],
  [
    'stale newly received helper',
    (r) => {
      r.response.status.decoderCadenceAgeUpperBoundMs = 251;
      r.sampleAgeSeconds = 0.251 + r.requestSeconds + r.residenceSeconds;
      r.observedStall = null;
    },
  ],
])
  test(`rejects intermediate ${name} omitted from source decisions`, () => {
    const f = fixture();
    const report = intermediateCadence(f);
    assert(report);
    mutate(report);
    assert.throws(() => qualifyMeasuredTrialPolicy(f));
  });
test('missing intermediate cadence reports cannot preserve probation', () => {
  const f = fixture(),
    report = intermediateCadence(f),
    at = report.evaluatedUptime;
  f.cadenceReports.rows = f.cadenceReports.rows.filter(
    (r) => r.evaluatedUptime < at || r.evaluatedUptime > at + 0.6,
  );
  assert.throws(() => qualifyMeasuredTrialPolicy(f));
});

for (const [name, mutate] of [
  [
    'publisher change',
    (r) => {
      r.response.status.publication.publisherId = '00000000-0000-4000-8000-000000000001';
    },
  ],
  [
    'mux clock change',
    (r) => {
      r.response.status.publication.clock.originPTS = '99';
    },
  ],
  [
    'invalid cadence window',
    (r) => {
      r.response.status.observation.decoderCadence.oneSecond.valid = false;
    },
  ],
])
  test(`rejects intermediate ${name} that invalidates the native helper`, () => {
    const f = fixture();
    mutate(intermediateCadence(f));
    assert.throws(() => qualifyMeasuredTrialPolicy(f));
  });

test('intermediate cadence does not require a completed processing window', () => {
  const f = fixture();
  delete intermediateCadence(f).response.status.observation.processing;
  assert.equal(qualifyMeasuredTrialPolicy(f).confirmed, 1);
});

const { qualifyMeasuredTrialConfirmedPrefix } = await import('../measured-trial-policy.mjs');
// Synthetic bounded suffix exercises the full-history dependency contract. The
// original bootstrap/admission/confirmation rows remain byte-for-byte unchanged;
// this is not evidence that a real recovery occurred or that its suffix qualifies.
const recoveryContext = () => {
  const f = fixture(),
    first = applied(f),
    confirmation = f.quality.events.find((e) => e.reasons?.includes('trialConfirmed'));
  const reset = structuredClone(first);
  reset.at = confirmation.at + 4;
  reset.acknowledgedAt = reset.at - 0.01;
  reset.revision = '2';
  reset.profileID = '240p30';
  reset.action.kind = 'reset';
  reset.action.fromRevision = '1';
  reset.action.profileID = '240p30';
  reset.action.bitRate = 350000;
  reset.application.fromRevision = '1';
  reset.application.id = '00000000-0000-4000-8000-000000000002';
  reset.receipt.bitRate = 350000;
  reset.receipt.configurationID = '00000000-0000-4000-8000-000000000003';
  reset.receipt.encoderSessionID = '00000000-0000-4000-8000-000000000004';
  reset.profileReceipt = {
    ...reset.profileReceipt,
    profile: '240p30',
    width: 426,
    height: 240,
    encoderSessionID: reset.receipt.encoderSessionID,
    previousEncoderSessionID: first.receipt.encoderSessionID,
    acknowledgedAt: reset.acknowledgedAt - 0.01,
  };
  f.quality.events.splice(
    f.quality.events.length - 1,
    0,
    { kind: 'decoderStall', at: reset.at - 1, revision: '1' },
    reset,
  );
  const stop = f.quality.events.at(-1);
  stop.revision = '2';
  stop.profileID = '240p30';
  stop.receipt = reset.receipt;
  stop.acknowledgedAt = reset.acknowledgedAt;
  f.profileQualification.phases.push({
    ...f.profileQualification.phases[0],
    encoderSessionID: reset.receipt.encoderSessionID,
  });
  f.profileQualification.receipts.push(reset.profileReceipt);
  f.lifecycleQualification.applications.push({
    ...f.lifecycleQualification.applications[0],
    applicationID: reset.application.id,
    target: '240p30',
    acknowledgedAt: reset.acknowledgedAt,
    application: reset.application,
    receipt: reset.receipt,
    profileReceipt: reset.profileReceipt,
  });
  const later = structuredClone(f.cadenceReports.rows.at(-1));
  later.evaluatedUptime = confirmation.evaluatedAt + 2;
  later.observedStall = true;
  later.response.status.observation.decoderCadence.progress.stalled = true;
  later.response.status.observation.decoderCadence.progress.ageMs = 1001;
  f.cadenceReports.rows.push(later);
  return f;
};
test('confirmed prefix identifies its exact raw boundary without manufacturing a stopped event', () => {
  assert.equal(typeof qualifyMeasuredTrialConfirmedPrefix, 'function');
  const f = recoveryContext(),
    before = JSON.stringify(f),
    at = f.quality.events.findIndex((e) => e.reasons?.includes('trialConfirmed'));
  const result = qualifyMeasuredTrialConfirmedPrefix(f);
  assert.equal(JSON.stringify(f), before);
  assert.equal(result.proofExtent, 'confirmed-prefix');
  assert.equal(result.confirmedEventIndex, at);
  assert.equal(result.confirmedAt, f.quality.events[at].evaluatedAt);
  assert.equal(result.confirmedEventAt, f.quality.events[at].at);
  assert.equal(result.nextEventIndex, at + 1);
  assert.equal(result.rawEventCount, f.quality.events.length);
  assert.equal(result.confirmed, 1);
  assert.equal(result.upgradeAuthorized, false);
  assert.throws(() => qualifyMeasuredTrialPolicy(f));
});
test('ordinary successful history has the same independently reconstructed confirmed prefix', () => {
  const f = fixture(),
    prefix = qualifyMeasuredTrialConfirmedPrefix(f),
    full = qualifyMeasuredTrialPolicy(f);
  assert.deepEqual(prefix.probation, full.probation);
  assert.equal(prefix.confirmedEventAt, f.quality.events.at(-2).at);
});
for (const [name, mutate] of [
  ['forged early confirmation', (f) => probation(f)[0].reasons.push('trialConfirmed')],
  [
    'missing confirmation',
    (f) =>
      f.quality.events.forEach((e) => {
        if (e.reasons) e.reasons = e.reasons.filter((r) => r !== 'trialConfirmed');
      }),
  ],
  [
    'pre-confirmation invalidation',
    (f) => {
      const i = f.quality.events.indexOf(probation(f)[1]);
      f.quality.events.splice(i, 0, { kind: 'rejected', at: probation(f)[1].at });
    },
  ],
  [
    'duplicate pre-confirmation candidate',
    (f) => {
      const e = f.quality.events.find((e) => e.kind === 'candidate');
      f.quality.events.splice(f.quality.events.indexOf(e) + 1, 0, structuredClone(e));
    },
  ],
  [
    'pre-confirmation cadence stall',
    (f) => {
      const r = intermediateCadence(f);
      r.observedStall = true;
      r.response.status.observation.decoderCadence.progress.stalled = true;
      r.response.status.observation.decoderCadence.progress.ageMs = 1001;
    },
  ],
  [
    'altered trial native receipt',
    (f) => {
      f.profileQualification.receipts[0].encoderSessionID = '00000000-0000-4000-8000-000000000009';
    },
  ],
  ['unmatched full-history context', (f) => f.lifecycleQualification.applications.pop()],
])
  test(`confirmed prefix rejects ${name}`, () => {
    assert.equal(typeof qualifyMeasuredTrialConfirmedPrefix, 'function');
    const f = recoveryContext();
    mutate(f);
    assert.throws(() => qualifyMeasuredTrialConfirmedPrefix(f));
  });

test('confirmed prefix cannot hide an in-range stall behind an out-of-order future report', () => {
  const f = recoveryContext();
  const end = f.quality.events.find((e) => e.reasons?.includes('trialConfirmed')).evaluatedAt;
  const index = f.cadenceReports.rows.findLastIndex((r) => r.evaluatedUptime <= end - 0.2);
  assert(index > 0 && end - f.cadenceReports.rows[index - 1].evaluatedUptime < 0.5);
  const stalled = f.cadenceReports.rows[index];
  const future = structuredClone(stalled);
  future.evaluatedUptime = end + 5;
  stalled.observedStall = true;
  stalled.response.status.observation.decoderCadence.progress.stalled = true;
  stalled.response.status.observation.decoderCadence.progress.ageMs = 1001;
  f.cadenceReports.rows.splice(index, 0, future);
  assert.throws(() => qualifyMeasuredTrialConfirmedPrefix(f), /Cadence audit time reversal/);
});

test('successful measured pressure replay requires explicit recovery format and policy', () => {
  const f = fixture();
  f.transportPolicy = 'recovery-budget-v1';
  f.quality.formatVersion = 5;
  f.quality.transportPolicy = f.transportPolicy;
  f.candidateWitnessQualification.policy = f.transportPolicy;
  f.lifecycleQualification.probePolicy = f.transportPolicy;
  const result = qualifyMeasuredTrialPolicy(f);
  assert.equal(result.transportPolicy, 'recovery-budget-v1');
  assert.equal(result.confirmed, 1);
  for (const change of [
    (x) => delete x.transportPolicy,
    (x) => (x.transportPolicy = 'future-v1'),
    (x) => (x.quality.formatVersion = 4),
    (x) => (x.quality.transportPolicy = 'sender-delay-v1'),
    (x) => delete x.candidateWitnessQualification.policy,
    (x) => delete x.lifecycleQualification.probePolicy,
  ]) {
    const changed = structuredClone(f);
    change(changed);
    assert.throws(() => qualifyMeasuredTrialPolicy(changed));
  }
});
test('historical measured pressure replay rejects unknown policy and new envelope metadata', () => {
  const f = fixture();
  f.transportPolicy = 'future-v1';
  assert.throws(() => qualifyMeasuredTrialPolicy(f));
  delete f.transportPolicy;
  f.quality.transportPolicy = 'recovery-budget-v1';
  assert.throws(() => qualifyMeasuredTrialPolicy(f));
});

test('complete pressure replay uses recovery rules for recovered retries and retains drop limits', () => {
  const f = fixture();
  for (const row of f.quality.events)
    for (const sample of row.evidence?.transport?.samples ?? [])
      sample.retransmittedBytes = String(BigInt(sample.sentBytes) / 20n);
  assert.throws(
    () => qualifyMeasuredTrialPolicy(f),
    'historical retry-fraction rule must reject the nominal claim',
  );
  f.transportPolicy = 'recovery-budget-v1';
  f.quality.formatVersion = 5;
  f.quality.transportPolicy = f.transportPolicy;
  f.candidateWitnessQualification.policy = f.transportPolicy;
  f.lifecycleQualification.probePolicy = f.transportPolicy;
  assert.equal(qualifyMeasuredTrialPolicy(f).confirmed, 1);
  for (const change of [
    (s) => (s.droppedPackets = Number(BigInt(s.sentBytes) / 10000n)),
    (s) => (s.senderDeliveryDelayMilliseconds = 0),
    (s) => (s.rttMilliseconds = 31),
    (s) => (s.senderBufferMilliseconds = 61),
  ]) {
    const bad = structuredClone(f);
    for (const row of bad.quality.events)
      for (const sample of row.evidence?.transport?.samples ?? []) change(sample);
    assert.throws(() => qualifyMeasuredTrialPolicy(bad));
  }
});

function recoveryBudgetPrefixInput(base = recoveryContext()) {
  base.transportPolicy = 'recovery-budget-v1';
  base.quality.formatVersion = 5;
  base.quality.transportPolicy = base.transportPolicy;
  base.candidateWitnessQualification.policy = base.transportPolicy;
  base.lifecycleQualification.probePolicy = base.transportPolicy;
  return base;
}
function capacityPrefixInput() {
  const f = recoveryBudgetPrefixInput();
  f.cadenceAuditMode = 'capacity';
  Object.assign(f.cadenceReports, {
    formatVersion: 2,
    mode: 'capacity',
    maximumRows: 3072,
    maximumBytes: 16777216,
  });
  return f;
}
test('capacity confirmed prefix explicitly selects its envelope without crediting the reset suffix', () => {
  const f = capacityPrefixInput(),
    before = structuredClone(f);
  const result = qualifyMeasuredTrialConfirmedPrefix(f);
  assert.equal(result.confirmed, 1);
  assert.equal(result.upgradeAuthorized, false);
  assert.equal(result.proofExtent, 'confirmed-prefix');
  assert(result.nextEventIndex < result.rawEventCount);
  assert.deepEqual(f, before);
  assert.throws(() => qualifyMeasuredTrialPolicy(f));
});
for (const [name, mutate] of Object.entries({
  'implicit mode': (f) => delete f.cadenceAuditMode,
  'wrong mode': (f) => (f.cadenceAuditMode = 'repeated'),
  'wrong policy': (f) => (f.transportPolicy = 'sender-delay-v1'),
  'wrong envelope': (f) => (f.cadenceReports.mode = 'repeated'),
  overflow: (f) => (f.cadenceReports.overflow = true),
  invalid: (f) => (f.cadenceReports.invalid = true),
  'missing confirmation': (f) => {
    for (const e of f.quality.events)
      if (e.reasons) e.reasons = e.reasons.filter((r) => r !== 'trialConfirmed');
  },
  'stalled prefix': (f) => (intermediateCadence(f).observedStall = true),
  'thermal pressure': (f) => probation(f)[0].evidence.thermal.samples.forEach((s) => (s.state = 2)),
}))
  test(`capacity prefix rejects ${name}`, () => {
    const f = capacityPrefixInput();
    mutate(f);
    assert.throws(() => qualifyMeasuredTrialConfirmedPrefix(f));
  });
for (const suffix of [false, true])
  test(`recovery-budget prefix preserves exact confirmation with later suffix=${suffix}`, () => {
    const f = recoveryBudgetPrefixInput(suffix ? recoveryContext() : fixture());
    const before = JSON.stringify(f);
    const result = qualifyMeasuredTrialConfirmedPrefix(f);
    const index = f.quality.events.findIndex((e) => e.reasons?.includes('trialConfirmed'));
    assert.equal(result.proofExtent, 'confirmed-prefix');
    assert.equal(result.transportPolicy, 'recovery-budget-v1');
    assert.equal(result.confirmedEventIndex, index);
    assert.equal(result.nextEventIndex, index + 1);
    assert.equal(result.rawEventCount, f.quality.events.length);
    assert.equal(result.confirmedAt, f.quality.events[index].evaluatedAt);
    assert.equal(result.upgradeAuthorized, false);
    assert.match(result.scope, /suffix and recovery remain unqualified/);
    assert.equal(JSON.stringify(f), before);
    if (suffix) assert.throws(() => qualifyMeasuredTrialPolicy(f));
    else assert.deepEqual(result.probation, qualifyMeasuredTrialPolicy(f).probation);
  });
for (const [name, mutate] of Object.entries({
  policy: (f) => delete f.transportPolicy,
  format: (f) => (f.quality.formatVersion = 4),
  metadata: (f) => (f.quality.transportPolicy = 'sender-delay-v1'),
  admissionPolicy: (f) => delete f.candidateWitnessQualification.policy,
  lifecyclePolicy: (f) => delete f.lifecycleQualification.probePolicy,
  unqualifiedHistory: (f) => f.lifecycleQualification.applications.pop(),
  missingConfirmation: (f) => {
    for (const e of f.quality.events)
      if (e.reasons) e.reasons = e.reasons.filter((r) => r !== 'trialConfirmed');
  },
  earlyConfirmation: (f) => probation(f)[0].reasons.push('trialConfirmed'),
  staleProbation: (f) => (probation(f)[0].evaluatedAt = probation(f)[0].window.end + 2.01),
  nativeOwner: (f) =>
    (probation(f)[0].receipt.configurationID = '00000000-0000-4000-8000-000000000001'),
  pressure: (f) => probation(f)[0].evidence.thermal.samples.forEach((s) => (s.state = 2)),
  cadence: (f) => (intermediateCadence(f).observedStall = true),
  rejected: (f) => {
    const e = probation(f)[1];
    f.quality.events.splice(f.quality.events.indexOf(e), 0, {
      ...e,
      kind: 'rejected',
      reasons: [],
    });
  },
  discontinuous: (f) => (f.quality.events = f.quality.events.filter((e) => e !== probation(f)[1])),
}))
  test(`recovery-budget prefix rejects ${name}`, () => {
    const f = recoveryBudgetPrefixInput();
    mutate(f);
    assert.throws(() => qualifyMeasuredTrialConfirmedPrefix(f));
  });
test('recovery-budget prefix accepts recovered retries but rejects actual transport pressure', () => {
  const f = recoveryBudgetPrefixInput();
  for (const e of f.quality.events)
    for (const s of e.evidence?.transport?.samples ?? [])
      s.retransmittedBytes = String(BigInt(s.sentBytes) / 20n);
  assert.equal(qualifyMeasuredTrialConfirmedPrefix(f).confirmed, 1);
  for (const mutate of [
    (s) => (s.droppedPackets = Number(BigInt(s.sentBytes) / 10000n)),
    (s) => (s.senderDeliveryDelayMilliseconds = 0),
    (s) => (s.rttMilliseconds = 31),
    (s) => (s.senderBufferMilliseconds = 61),
  ]) {
    const bad = structuredClone(f);
    for (const e of bad.quality.events)
      for (const s of e.evidence?.transport?.samples ?? []) mutate(s);
    assert.throws(() => qualifyMeasuredTrialConfirmedPrefix(bad));
  }
});

// Synthetic startup pressure prepended to the existing recorded policy fixture.
// The fixture's first policy sequence is5, leaving1/2 for these unknown windows.
function startupPressureInput() {
  const f = recoveryBudgetPrefixInput(fixture());
  f.startupPressurePolicy = 'minimum-before-source-v1';
  const boot = f.quality.events[0];
  const rows = [1, 2].map((n) => {
    const start = boot.at + n,
      end = start + 0.25;
    return {
      ...structuredClone(boot),
      kind: 'localPressure',
      at: end + 0.02,
      evaluatedAt: end + 0.01,
      state: 'unknown',
      reasons: [
        ...(n === 2 ? ['telemetryGap'] : []),
        'unknownConnectivity',
        'missingCapture',
        'missingEncoded',
        'missingReceiver',
        'missingSourceLoss',
        'missingCapacity',
        'unknownPressure',
        'transportPressure',
        'minimumProfileInsufficient',
      ],
      window: {
        start,
        end,
        sequence: String(n),
        revision: '0',
        captured: null,
        encoded: null,
        received: null,
        observedAt: null,
        expected: null,
        lost: null,
        capacity: null,
        connectivity: 'unknown',
        worker: 'unknown',
        thermal: 'nominal',
        transport: 'elevated',
        queue: 0,
      },
      evidence: {
        local: {
          isPublishing: true,
          ingressClosed: false,
          clockGeneration: boot.receipt.generation,
          receipt: structuredClone(boot.receipt),
        },
        processing: null,
        thermal: {
          isClosed: false,
          isQuarantined: false,
          samples: [start, end].map((sampledAt) => ({ sampledAt, state: 0 })),
        },
        transport: {
          isClosed: false,
          isQuarantined: false,
          samples: [start, end].map((sampledAt, i) => ({
            sampledAt,
            generation: boot.receipt.generation,
            elapsedMilliseconds: String(n * 1000 + i * 250),
            sentBytes: String(n * 10000 + i * 1000),
            retransmittedBytes: '0',
            droppedPackets: 0,
            senderBufferMilliseconds: 40,
            rttMilliseconds: 125,
            senderDeliveryDelayMilliseconds: 400,
          })),
        },
        queue: {
          isClosed: false,
          isQuarantined: false,
          scope: structuredClone(f.snapshot.scope),
          coveredThrough: end,
          states: [{ at: start, phase: 'admitting', itemFraction: 0, byteFraction: 0 }],
        },
      },
    };
  });
  f.quality.events.splice(1, 0, ...rows);
  f.quality.events.find((e) => e.kind === 'evaluated').reasons.unshift('telemetryGap');
  return f;
}
for (const replay of [qualifyMeasuredTrialPolicy, qualifyMeasuredTrialConfirmedPrefix])
  test(`explicit startup pressure grants no healthy duration in ${replay.name}`, () => {
    const f = startupPressureInput(),
      before = structuredClone(f);
    const result = replay(f);
    assert.equal(result.confirmed, 1);
    assert.equal(result.upgradeAuthorized, false);
    assert.deepEqual(
      result.probation,
      qualifyMeasuredTrialPolicy(recoveryBudgetPrefixInput(fixture())).probation,
    );
    assert.deepEqual(result.startupPressure, {
      policy: f.startupPressurePolicy,
      events: 2,
      healthyCreditSeconds: 0,
      lastWindowEnd: f.quality.events[2].window.end,
    });
    assert.deepEqual(f, before);
  });
for (const [name, mutate] of Object.entries({
  default: (f) => delete f.startupPressurePolicy,
  unknownOption: (f) => (f.startupPressurePolicy = 'ignore'),
  nullOption: (f) => (f.startupPressurePolicy = null),
  falseOption: (f) => (f.startupPressurePolicy = false),
  unsupportedTransport: (f) => (f.transportPolicy = 'sender-delay-v1'),
  forgedHealth: (f) => (f.quality.events[1].state = 'healthy'),
  missingReason: (f) => f.quality.events[1].reasons.pop(),
  duplicateReason: (f) => f.quality.events[1].reasons.push('transportPressure'),
  stalePressure: (f) => (f.quality.events[1].evaluatedAt = f.quality.events[1].window.end + 2.01),
  futureEvaluation: (f) => (f.quality.events[1].evaluatedAt = f.quality.events[1].at + 0.01),
  receiptMismatch: (f) => f.quality.events[1].receipt.bitRate++,
  profileMismatch: (f) => (f.quality.events[1].profileID = '360p30'),
  revisionMismatch: (f) => (f.quality.events[1].revision = '1'),
  missingAck: (f) => delete f.quality.events[1].acknowledgedAt,
  replayedSequence: (f) => (f.quality.events[2].window.sequence = '1'),
  overlappingPressure: (f) => (f.quality.events[2].window.start = f.quality.events[1].window.start),
  contradictorySamples: (f) =>
    f.quality.events[1].evidence.transport.samples.forEach((s) => (s.rttMilliseconds = 50)),
  foreignQueue: (f) => (f.quality.events[1].evidence.queue.scope.recordingID = 'foreign'),
  missingEvidence: (f) => delete f.quality.events[1].evidence,
  receiverClaim: (f) => (f.quality.events[1].window.received = 8),
  applicationAuthority: (f) => (f.quality.events[1].application = {}),
  actionAuthority: (f) => (f.quality.events[1].action = {}),
  candidateAuthority: (f) => (f.quality.events[1].candidate = {}),
  admissionAuthority: (f) => (f.quality.events[1].candidateAdmission = {}),
  profileReceipt: (f) => (f.quality.events[1].profileReceipt = {}),
  unknownRowField: (f) => (f.quality.events[1].unrecognized = true),
  windowBeforeBootstrap: (f) =>
    (f.quality.events[1].window.start = f.quality.events[0].acknowledgedAt - 1),
  hiddenGap: (f) => f.quality.events[2].reasons.shift(),
  sourceSequenceReused: (f) =>
    (f.quality.events.find((e) => e.kind === 'evaluated').window.sequence = '2'),
  sourceMissingGap: (f) => f.quality.events.find((e) => e.kind === 'evaluated').reasons.shift(),
  latePressure: (f) => {
    const local = f.quality.events.splice(2, 1)[0];
    const first = f.quality.events.findIndex((e) => e.kind === 'evaluated');
    local.at = f.quality.events[first].at;
    f.quality.events.splice(first + 1, 0, local);
  },
}))
  test(`startup pressure rejects ${name}`, () => {
    const f = startupPressureInput();
    mutate(f);
    assert.throws(() => qualifyMeasuredTrialPolicy(f));
    assert.throws(() => qualifyMeasuredTrialConfirmedPrefix(f));
  });
test('explicit startup mode without pressure preserves baseline qualification', () => {
  const f = recoveryBudgetPrefixInput(fixture());
  f.startupPressurePolicy = 'minimum-before-source-v1';
  assert.deepEqual(qualifyMeasuredTrialPolicy(f).startupPressure, {
    policy: f.startupPressurePolicy,
    events: 0,
    healthyCreditSeconds: 0,
  });
});

test('startup replay verifies queue and thermal pressure reasons independently', () => {
  for (const metric of ['queue', 'thermal']) {
    const f = startupPressureInput();
    for (const row of f.quality.events.filter((e) => e.kind === 'localPressure')) {
      row.evidence.transport.samples.forEach((s) => (s.rttMilliseconds = 50));
      row.window.transport = 'nominal';
      row.reasons[row.reasons.indexOf('transportPressure')] = metric + 'Pressure';
      if (metric === 'queue') {
        row.window.queue = 0.8;
        row.evidence.queue.states.forEach((s) => (s.byteFraction = 0.8));
      } else {
        row.window.thermal = 'elevated';
        row.evidence.thermal.samples.forEach((s) => (s.state = 2));
      }
    }
    assert.equal(qualifyMeasuredTrialPolicy(f).startupPressure.events, 2);
  }
});
test('startup replay retains missing queue and unknown transport with independent thermal pressure', () => {
  const f = startupPressureInput();
  for (const row of f.quality.events.filter((e) => e.kind === 'localPressure')) {
    row.window.thermal = 'elevated';
    row.evidence.thermal.samples.forEach((s) => (s.state = 2));
    row.window.transport = 'unknown';
    row.evidence.transport.isQuarantined = true;
    row.window.queue = null;
    row.evidence.queue.isQuarantined = true;
    row.reasons.splice(row.reasons.indexOf('missingCapacity'), 0, 'missingQueue');
    row.reasons.splice(
      row.reasons.indexOf('transportPressure'),
      1,
      'unknownTransportPressure',
      'thermalPressure',
    );
  }
  assert.equal(qualifyMeasuredTrialPolicy(f).startupPressure.events, 2);
});
test('startup evidence cannot move evaluation time backwards', () => {
  const f = startupPressureInput();
  f.quality.events[1].evaluatedAt = f.quality.events[2].at;
  f.quality.events[1].at = f.quality.events[2].at;
  assert.throws(() => qualifyMeasuredTrialPolicy(f));
});
