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
