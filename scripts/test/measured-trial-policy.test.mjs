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
