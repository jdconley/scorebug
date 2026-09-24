import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyRepeatedRecoveryInvalidations as qualify } from '../repeated-recovery-invalidation.mjs';
import { repeatedRecoveryInvalidationFixture as fixture } from './fixtures/repeated-recovery-invalidation-evidence.mjs';
import { repeatedMeasuredPolicyFixture } from './fixtures/repeated-measured-policy-evidence.mjs';

const rejected = (f) => f.quality.events.find((e) => e.kind === 'rejected');
const joined = (f) =>
  f.cadenceReports.rows.find(
    (r) => r.cadenceReceiptID === rejected(f).evaluationDiagnostic.session.cadenceReceiptID,
  );

test('preserves original indices and returns only invalidation descriptors for both recoveries', () => {
  const f = fixture(undefined, { revisions: ['2', '4'] }),
    before = JSON.stringify(f);
  const result = qualify(f);
  assert.equal(result.length, 2);
  for (const d of result) {
    const e = f.quality.events[d.eventIndex],
      r = f.cadenceReports.rows[d.reportIndex];
    assert.deepEqual(d, {
      eventIndex: f.quality.events.indexOf(e),
      reportIndex: f.cadenceReports.rows.indexOf(r),
      receiptID: e.evaluationDiagnostic.session.cadenceReceiptID,
      revision: e.revision,
      evaluatedAt: e.evaluationDiagnostic.session.evaluatedAt,
      caughtAt: e.evaluationDiagnostic.caughtAt,
      nextReportIndex: f.cadenceReports.rows.indexOf(r) + 1,
      availableAt: f.cadenceReports.rows[f.cadenceReports.rows.indexOf(r) + 1].evaluatedUptime,
    });
    assert.equal(r.cadenceReceiptID, d.receiptID);
    assert.equal(e.kind, 'rejected');
  }
  assert.equal(JSON.stringify(f), before);
  for (const c of f.faults.campaigns)
    assert(f.quality.events[c.confirmedEventIndex].reasons.includes('trialConfirmed'));
});

test('no rejected history supplies no invalidation or health authority', () => {
  assert.deepEqual(qualify(repeatedMeasuredPolicyFixture()), []);
});

for (const edge of ['lower', 'upper'])
  test(`accepts diagnostic age at conservative ${edge} boundary`, () => {
    const f = fixture(),
      e = rejected(f),
      r = joined(f),
      t = e.evaluationDiagnostic;
    const S = r.response.status.decoderCadenceAgeUpperBoundMs / 1000;
    t.session.sampleAgeSeconds =
      edge === 'lower'
        ? S + r.requestSeconds + t.session.evaluatedAt - r.receivedUptime
        : S + t.caughtAt - r.timing.statusRequestStartedUptime;
    assert.equal(qualify(f).length, 1);
  });

test('independently sampled diagnostic age need not equal audit age plus uptime delta', () => {
  const f = fixture(),
    e = rejected(f),
    r = joined(f);
  const extrapolated =
    r.sampleAgeSeconds + e.evaluationDiagnostic.session.evaluatedAt - r.evaluatedUptime;
  assert(Math.abs(e.evaluationDiagnostic.session.sampleAgeSeconds - extrapolated) > 0.0005);
  assert.equal(qualify(f).length, 1);
});

test('following fresh cached PTS may equal the advancing stale report', () => {
  const f = fixture(),
    r = joined(f),
    i = f.cadenceReports.rows.indexOf(r),
    next = f.cadenceReports.rows[i + 1];
  next.response.status.observation.decoderCadence.progress = {
    ...r.response.status.observation.decoderCadence.progress,
    ageMs: r.response.status.observation.decoderCadence.progress.ageMs + 250,
  };
  assert.equal(qualify(f).length, 1);
});

for (const [name, requestSeconds, residenceSeconds, auditAge, diagnosticAge] of [
  ['exactly fresh diagnostic boundary', 0.1, 0.011, 0.251, 0.25],
  ['fresh diagnostic inside independent clock bracket', 0.099, 0.012, 0.251, 0.2495],
  ['still-stale diagnostic younger than its earlier audit', 0.1, 0.02, 0.26, 0.255],
])
  test(`rejects ${name} despite otherwise valid independent timing bracket`, () => {
    const f = fixture(),
      r = joined(f),
      trace = rejected(f).evaluationDiagnostic;
    Object.assign(r, { requestSeconds, residenceSeconds, sampleAgeSeconds: auditAge });
    trace.selectedAt = trace.dispatchedAt = trace.session.evaluatedAt = r.evaluatedUptime;
    trace.caughtAt = r.evaluatedUptime + 0.001;
    trace.session.sampleAgeSeconds = diagnosticAge;
    // Neither the raw stale audit nor broad cross-clock bounds establish that the
    // same immutable helper could report this younger/fresh age at classification.
    assert.throws(() => qualify(f));
  });

test('rejects still-stale age omitting elapsed time after selection', () => {
  const f = fixture(),
    r = joined(f),
    e = rejected(f),
    t = e.evaluationDiagnostic;
  Object.assign(r, { requestSeconds: 0.1, residenceSeconds: 0.04, sampleAgeSeconds: 0.28 });
  t.selectedAt = t.dispatchedAt = r.evaluatedUptime + 0.02;
  t.session.evaluatedAt = r.evaluatedUptime + 0.03;
  t.caughtAt = r.evaluatedUptime + 0.04;
  e.at = r.evaluatedUptime + 0.05;
  t.session.sampleAgeSeconds = 0.285;
  assert(t.session.sampleAgeSeconds > r.sampleAgeSeconds);
  assert(t.session.sampleAgeSeconds < r.sampleAgeSeconds + t.session.evaluatedAt - t.selectedAt);
  assert.throws(() => qualify(f));
});

test('rejects old receipt selected after a newer report was audited', () => {
  const f = fixture(),
    r = joined(f),
    e = rejected(f),
    t = e.evaluationDiagnostic;
  const next = f.cadenceReports.rows[f.cadenceReports.rows.indexOf(r) + 1];
  t.selectedAt = next.evaluatedUptime + 0.001;
  t.dispatchedAt = t.selectedAt + 0.001;
  t.session.evaluatedAt = t.selectedAt + 0.002;
  t.caughtAt = t.selectedAt + 0.003;
  e.at = t.selectedAt + 0.004;
  const S = r.response.status.decoderCadenceAgeUpperBoundMs / 1000;
  const lower = S + r.requestSeconds + t.session.evaluatedAt - r.receivedUptime;
  const upper = S + t.caughtAt - r.timing.statusRequestStartedUptime;
  t.session.sampleAgeSeconds = (lower + upper) / 2;
  assert.throws(() => qualify(f));
});

test('next response may arrive before selection when its audit still follows selection', () => {
  const f = fixture(),
    r = joined(f),
    t = rejected(f).evaluationDiagnostic;
  const next = f.cadenceReports.rows[f.cadenceReports.rows.indexOf(r) + 1];
  next.receivedUptime = t.selectedAt - 0.005;
  next.residenceSeconds = next.evaluatedUptime - next.receivedUptime;
  next.requestSeconds = 0;
  next.sampleAgeSeconds = next.residenceSeconds;
  assert(next.sampleAgeSeconds <= 0.25);
  assert.equal(qualify(f).length, 1);
});

function twoRecoveryInvalidations({ overlap = false } = {}) {
  const f = fixture(),
    first = rejected(f),
    firstReport = joined(f);
  const original = [...f.quality.events];
  const secondReport = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 167.75);
  for (const key of ['requestSeconds', 'residenceSeconds', 'sampleAgeSeconds', 'observedStall'])
    secondReport[key] = firstReport[key];
  secondReport.response.status.decoderCadenceAgeUpperBoundMs = 140;
  secondReport.timing = structuredClone(firstReport.timing);
  for (const key of Object.keys(secondReport.timing))
    if (key.endsWith('Uptime')) secondReport.timing[key] += 0.5;
  const second = structuredClone(first);
  second.at += 0.5;
  const trace = second.evaluationDiagnostic;
  for (const key of ['selectedAt', 'dispatchedAt', 'caughtAt']) trace[key] += 0.5;
  trace.session.evaluatedAt += 0.5;
  trace.session.cadenceReceiptID = secondReport.cadenceReceiptID;
  if (overlap) {
    first.evaluationDiagnostic.caughtAt = 171.001;
    first.at = 171.01;
    second.at = 171.02;
  }
  f.quality.events.push(second);
  f.quality.events.sort((a, b) => a.at - b.at);
  for (const campaign of f.faults.campaigns) {
    campaign.confirmedEventIndex = f.quality.events.indexOf(original[campaign.confirmedEventIndex]);
    if (campaign.readyEventIndex !== undefined)
      campaign.readyEventIndex = f.quality.events.indexOf(original[campaign.readyEventIndex]);
  }
  return f;
}

test('accepts sequential independent invalidations during the same recovery', () => {
  assert.equal(qualify(twoRecoveryInvalidations()).length, 2);
});

test('rejects later rejection selection before the preceding invocation was caught', () => {
  const f = twoRecoveryInvalidations({ overlap: true });
  assert.throws(() => qualify(f));
});

test('fixture can position invalidation immediately before a recovery window boundary', () => {
  const f = fixture(undefined, { reportTimes: { 2: 170.75 } });
  const r = joined(f),
    e = rejected(f);
  assert.equal(r.evaluatedUptime, 170.75);
  assert.equal(e.evaluationDiagnostic.caughtAt, 170.78);
  const [proof] = qualify(f);
  assert.equal(proof.nextReportIndex, proof.reportIndex + 1);
  assert.equal(proof.availableAt, 171);
});

const mutations = {
  'wrong reason': (f) => (rejected(f).reason = 'time'),
  'trial phase': (f) => (rejected(f).revision = '1'),
  'bootstrap phase': (f) => (rejected(f).revision = '0'),
  'wrong profile': (f) => (rejected(f).profileID = '360p30'),
  'closed event': (f) => (rejected(f).closed = true),
  'receipt changed': (f) => rejected(f).receipt.bitRate++,
  'application changed': (f) =>
    (rejected(f).application.id = 'eeeeeeee-eeee-4eee-8eee-000000000099'),
  'profile receipt changed': (f) => rejected(f).profileReceipt.width++,
  'acknowledgement changed': (f) => rejected(f).acknowledgedAt++,
  'competing source': (f) => (rejected(f).source = null),
  'competing window': (f) => (rejected(f).window = {}),
  'competing action': (f) => (rejected(f).action = {}),
  'competing evaluatedAt': (f) => (rejected(f).evaluatedAt = 167.27),
  'competing signal': (f) => (rejected(f).decoderStall = {}),
  'unknown event metadata': (f) => (rejected(f).extra = true),
  'wrong session kind': (f) => (rejected(f).evaluationDiagnostic.session.kind = 'source'),
  'source key': (f) => (rejected(f).evaluationDiagnostic.session.sourceKey = {}),
  'source age': (f) => (rejected(f).evaluationDiagnostic.session.sourceAgeSeconds = 0),
  'missing receipt': (f) => delete rejected(f).evaluationDiagnostic.session.cadenceReceiptID,
  'noncanonical receipt': (f) =>
    (rejected(f).evaluationDiagnostic.session.cadenceReceiptID =
      rejected(f).evaluationDiagnostic.session.cadenceReceiptID.toUpperCase()),
  'foreign receipt': (f) =>
    (rejected(f).evaluationDiagnostic.session.cadenceReceiptID =
      'eeeeeeee-eeee-4eee-8eee-000000000099'),
  'duplicate receipt': (f) => {
    const r = joined(f),
      i = f.cadenceReports.rows.indexOf(r);
    f.cadenceReports.rows[i + 1].cadenceReceiptID = r.cadenceReceiptID;
  },
  'duplicate rejection': (f) => {
    const e = rejected(f);
    f.quality.events.splice(f.quality.events.indexOf(e) + 1, 0, structuredClone(e));
  },
  'selection before audit': (f) => (rejected(f).evaluationDiagnostic.selectedAt = 167.24),
  'dispatch before selection': (f) => (rejected(f).evaluationDiagnostic.dispatchedAt = 167.255),
  'evaluation before dispatch': (f) =>
    (rejected(f).evaluationDiagnostic.session.evaluatedAt = 167.26),
  'catch before evaluation': (f) => (rejected(f).evaluationDiagnostic.caughtAt = 167.26),
  'event before catch': (f) => (rejected(f).at = 167.275),
  'age below bracket': (f) => (rejected(f).evaluationDiagnostic.session.sampleAgeSeconds = 0.28),
  'age above bracket': (f) => (rejected(f).evaluationDiagnostic.session.sampleAgeSeconds = 0.31),
  'missing timing': (f) => delete joined(f).timing,
  'reversed stage': (f) => (joined(f).timing.probeReadFinishedUptime = 167.24),
  'derived stage duration': (f) => (joined(f).timing.nativeProbeSeconds = 0.01),
  'misbound audit stage': (f) => (joined(f).timing.auditEvaluatedUptime += 0.001),
  'misbound response stage': (f) => (joined(f).timing.responseReceivedUptime += 0.001),
  'uncontained request duration': (f) => (joined(f).requestSeconds = 0.13),
  'residence below lower bracket': (f) => (joined(f).residenceSeconds = 0),
  'residence above selection bracket': (f) => (joined(f).residenceSeconds = 0.03),
  'forged raw age': (f) => (joined(f).sampleAgeSeconds = 0.28),
  'fresh raw report with stale diagnostic': (f) => {
    const r = joined(f);
    r.response.status.decoderCadenceAgeUpperBoundMs = 100;
    r.sampleAgeSeconds = 0.23;
  },
  'observed stall instead of unavailable': (f) => (joined(f).observedStall = false),
  'expired at catch': (f) => (joined(f).response.status.expiresAt = '2040-01-01T00:00:00.150Z'),
  'foreign publication': (f) =>
    (joined(f).response.status.publication.publisherId = 'eeeeeeee-eeee-4eee-8eee-000000000099'),
  'foreign worker': (f) =>
    (joined(f).response.status.workerEpoch = 'eeeeeeee-eeee-4eee-8eee-000000000099'),
  'foreign decoder': (f) =>
    (joined(f).response.status.observation.decoderCadence.scopeID =
      'eeeeeeee-eeee-4eee-8eee-000000000099'),
  'foreign expected attempt': (f) =>
    (joined(f).expectedAttempt = 'eeeeeeee-eeee-4eee-8eee-000000000099'),
  'foreign source evidence': (f) => {
    const e = rejected(f),
      i = f.quality.events.indexOf(e);
    f.quality.events.slice(0, i).findLast((e) => e.source).source.readerID =
      'eeeeeeee-eeee-4eee-8eee-000000000099';
  },
  'no advancing PTS': (f) => {
    const r = joined(f),
      i = f.cadenceReports.rows.indexOf(r);
    r.response.status.observation.decoderCadence.progress.lastFreshPTS =
      f.cadenceReports.rows[i - 1].response.status.observation.decoderCadence.progress.lastFreshPTS;
  },
  'following PTS regression': (f) => {
    const r = joined(f),
      i = f.cadenceReports.rows.indexOf(r);
    f.cadenceReports.rows[i + 1].response.status.observation.decoderCadence.progress.lastFreshPTS =
      0;
  },
  'stalled progress': (f) =>
    (joined(f).response.status.observation.decoderCadence.progress = {
      lastFreshPTS: 6042000,
      ageMs: 1000,
      stalled: true,
    }),
  'stale adjacent report': (f) => {
    const r = joined(f),
      i = f.cadenceReports.rows.indexOf(r);
    f.cadenceReports.rows[i + 1].sampleAgeSeconds = 0.3;
  },
  'missing adjacent coverage': (f) => {
    const r = joined(f),
      i = f.cadenceReports.rows.indexOf(r);
    f.cadenceReports.rows.splice(i + 1, 3);
  },
  'legacy envelope': (f) => (f.cadenceReports.formatVersion = 1),
  'overflow envelope': (f) => (f.cadenceReports.overflow = true),
};
for (const [name, damage] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    const f = fixture();
    damage(f);
    assert.throws(() => qualify(f));
  });
