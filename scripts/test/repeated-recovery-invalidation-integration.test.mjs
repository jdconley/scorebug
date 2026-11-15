import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyRepeatedMeasuredPolicy } from '../repeated-measured-policy.mjs';
import { repeatedMeasuredPolicyFixture } from './fixtures/repeated-measured-policy-evidence.mjs';
import { repeatedRecoveryInvalidationFixture } from './fixtures/repeated-recovery-invalidation-evidence.mjs';

test('recovery invalidations preserve native sequences and restart whole-window credit in both cycles', () => {
  const original = repeatedMeasuredPolicyFixture(undefined, { recoveryDeliverySeconds: 22 });
  const baseline = qualifyRepeatedMeasuredPolicy(original);
  const f = repeatedRecoveryInvalidationFixture(structuredClone(original), {
    revisions: ['2', '4'],
  });
  const before = structuredClone(f);
  const result = qualifyRepeatedMeasuredPolicy(f);
  assert.deepEqual(f, before);
  assert.equal(result.repeatedPolicyQualified, true);
  assert.equal(result.productionUpgradeAuthorized, false);
  assert.equal(result.rawEventCount, baseline.rawEventCount + 2);
  assert.equal(result.evaluated, baseline.evaluated);
  assert.deepEqual(
    result.invalidations.map((x) => x.revision),
    ['2', '4'],
  );
  assert.deepEqual(
    result.recoveries.map((r) => [r.sharedCoverage.start, r.sharedCoverage.end]),
    [
      [171, 182],
      [231, 241],
    ],
  );
  for (const [revision, evaluatedAt, healthySince] of [
    ['2', 171.2, 166],
    ['4', 231.2, 226],
  ]) {
    const eventIndex = f.quality.events.findIndex(
      (e) => e.revision === revision && e.evaluatedAt === evaluatedAt,
    );
    const checkpoint = result.healthHistory.find((h) => h.eventIndex === eventIndex);
    assert.equal(
      checkpoint.healthySince,
      healthySince,
      'Native state retains actual straddling window start',
    );
  }
  for (const invalidation of result.invalidations) {
    const recovery = result.recoveries.find(
      (r) => r.campaign === (invalidation.revision === '2' ? '1' : '2'),
    );
    assert(recovery.sharedCoverage.start >= invalidation.caughtAt);
    assert(
      recovery.healthyWindows.some((w) => w.end < invalidation.evaluatedAt),
      'Earlier raw history retained',
    );
  }
});

test('a stale audit row cannot pass repeated policy without its original invalidation event', () => {
  const f = repeatedRecoveryInvalidationFixture();
  f.quality.events = f.quality.events.filter((e) => e.kind !== 'rejected');
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f));
});

test('pre-invalidation duration cannot fill a short final recovery', () => {
  const f = repeatedRecoveryInvalidationFixture(undefined, { revisions: ['4'] });
  f.quality.events = f.quality.events.filter(
    (e) => !(e.kind === 'evaluated' && e.revision === '4' && e.window.end > 236),
  );
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f), /shared recovery coverage/i);
});

test('a second unjoined stale row still fails despite a supported invalidation', () => {
  const f = repeatedRecoveryInvalidationFixture();
  const report = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 168.25);
  report.response.status.decoderCadenceAgeUpperBoundMs = 250;
  report.sampleAgeSeconds = 0.27;
  report.observedStall = null;
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f), /cadence|stall/i);
});

import { qualifyRepeatedRecoveryInvalidations } from '../repeated-recovery-invalidation.mjs';
import { qualifyMeasuredCadenceContinuity } from '../measured-trial-policy.mjs';
import { repeatedMeasuredDeliveryFaultFixture } from './fixtures/repeated-measured-recovery-fault-evidence.mjs';

test('unavailable cadence exception requires the exact receipt and explicit repeated mode', () => {
  const f = repeatedRecoveryInvalidationFixture();
  const invalidations = qualifyRepeatedRecoveryInvalidations({ ...f, scope: f.snapshot.scope });
  const args = {
    reports: f.cadenceReports.rows,
    start: 166.5,
    end: 168,
    source: f.quality.events.find((e) => e.source).source,
    scope: f.snapshot.scope,
    cadenceAuditMode: 'repeated',
    recoveryInvalidations: invalidations,
  };
  assert.doesNotThrow(() => qualifyMeasuredCadenceContinuity(args));
  assert.throws(() => qualifyMeasuredCadenceContinuity({ ...args, cadenceAuditMode: 'legacy' }));
  assert.throws(() => qualifyMeasuredCadenceContinuity({ ...args, recoveryInvalidations: [] }));
  assert.throws(() =>
    qualifyMeasuredCadenceContinuity({
      ...args,
      recoveryInvalidations: [
        { ...invalidations[0], reportIndex: invalidations[0].reportIndex + 1 },
      ],
    }),
  );
});

for (const routes of [
  ['deliveryFailure', 'deliveryFailure'],
  ['decoderStall', 'deliveryFailure'],
  ['deliveryFailure', 'decoderStall'],
])
  test(`recovery invalidations retain both independent ${routes.join('/')} fault proofs`, () => {
    const base = repeatedMeasuredPolicyFixture(repeatedMeasuredDeliveryFaultFixture(routes), {
      recoveryDeliverySeconds: 22,
    });
    const f = repeatedRecoveryInvalidationFixture(base, { revisions: ['2', '4'] });
    const result = qualifyRepeatedMeasuredPolicy(f);
    assert.deepEqual(
      result.faults.campaigns.map((c) => c.triggerKind),
      routes,
    );
    assert.deepEqual(
      result.recoveries.map((r) => [r.sharedCoverage.start, r.sharedCoverage.end]),
      [
        [171, 182],
        [231, 241],
      ],
    );
    assert.equal(result.productionUpgradeAuthorized, false);
  });

for (const duration of [1, 2])
  test(`post-invalidation recovery cannot borrow earlier ${duration}-second delivery coverage`, () => {
    const f = repeatedRecoveryInvalidationFixture(undefined, { revisions: ['4'] });
    f.deliveryAudit.rows = f.deliveryAudit.rows.filter(
      (row) => !(row.appliedRevision === '4' && row.end - row.start === duration && row.end > 231),
    );
    assert.throws(() => qualifyRepeatedMeasuredPolicy(f), /whole recovered|shared recovery/i);
  });

test('whole recovery credit begins after the proved fresh replacement, not just the logged rejection', () => {
  const f = repeatedRecoveryInvalidationFixture(undefined, { reportTimes: { 2: 170.75 } });
  const next = f.cadenceReports.rows.find((row) => row.evaluatedUptime === 171);
  next.evaluatedUptime += 0.05;
  next.receivedUptime += 0.05;
  next.response.status.observation.decoderCadence.progress.ageMs += 50;
  const result = qualifyRepeatedMeasuredPolicy(f);
  const proof = result.invalidations[0];
  assert(proof.caughtAt < 171 && proof.availableAt === 171.05);
  assert.equal(proof.nextReportIndex, proof.reportIndex + 1);
  assert.deepEqual(
    [result.recoveries[0].sharedCoverage.start, result.recoveries[0].sharedCoverage.end],
    [172, 182],
  );
  assert(
    result.recoveries[0].healthyWindows.some((window) => window.start === 171),
    'Native straddling window retained',
  );
});

test('successive recovery invalidations retain all evidence and cannot regress the cutoff', () => {
  const f = repeatedRecoveryInvalidationFixture();
  repeatedRecoveryInvalidationFixture(f, { reportTimes: { 2: 168.25 } });
  const result = qualifyRepeatedMeasuredPolicy(f);
  assert.equal(result.invalidations.length, 2);
  assert.equal(result.recoveries[0].latestInvalidationAvailableAt, 168.5);
  assert.equal(result.recoveries[0].latestInvalidationCaughtAt, 168.28);
  const original = [...f.quality.events];
  const [first, second] = f.quality.events.filter((event) => event.kind === 'rejected');
  first.evaluationDiagnostic.caughtAt = 171.001;
  first.at = 171.01;
  second.at = 171.02;
  f.quality.events.sort((a, b) => a.at - b.at);
  for (const campaign of f.faults.campaigns)
    campaign.confirmedEventIndex = f.quality.events.indexOf(original[campaign.confirmedEventIndex]);
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f), /previous catch/i);
});
