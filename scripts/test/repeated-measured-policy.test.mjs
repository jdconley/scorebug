import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyRepeatedMeasuredPolicy } from '../repeated-measured-policy.mjs';
import { repeatedMeasuredPolicyFixture } from './fixtures/repeated-measured-policy-evidence.mjs';

test('replays two complete cycles on the original global history', () => {
  const f = repeatedMeasuredPolicyFixture();
  const q = qualifyRepeatedMeasuredPolicy(f);
  assert.equal(q.repeatedPolicyQualified, true);
  assert.equal(q.productionUpgradeAuthorized, false);
  assert.deepEqual(q.scope, f.snapshot.scope);
  assert.equal(q.rawEventCount, f.quality.events.length);
  assert.equal(q.confirmations.length, 2);
  assert.equal(q.recoveries.length, 2);
  assert(q.confirmations[1].confirmedEventIndex > q.recoveries[0].resetEventIndex);
  assert.deepEqual(
    q.confirmations.map((p) => p.trialRevision),
    ['1', '3'],
  );
  for (const r of q.recoveries) assert(r.sharedCoverage.coverageSeconds >= 10);
  assert(q.healthHistory.some((h) => h.revision === '2'));
});

import { repeatedMeasuredDeliveryFaultFixture } from './fixtures/repeated-measured-recovery-fault-evidence.mjs';
for (const routes of [
  ['deliveryFailure', 'deliveryFailure'],
  ['decoderStall', 'deliveryFailure'],
  ['deliveryFailure', 'decoderStall'],
]) {
  test(`replays both owned fault routes: ${routes.join('/')}`, () => {
    const f = repeatedMeasuredPolicyFixture(repeatedMeasuredDeliveryFaultFixture(routes));
    const q = qualifyRepeatedMeasuredPolicy(f);
    assert.deepEqual(
      q.faults.campaigns.map((c) => c.triggerKind),
      routes,
    );
    assert.deepEqual(
      q.recoveries.map((r) => [r.sharedCoverage.start, r.sharedCoverage.end]),
      [
        [161, 171],
        [221, 231],
      ],
    );
  });
}

const evaluated = (f, revision) =>
  f.quality.events.filter((e) => e.kind === 'evaluated' && e.revision === revision);
const mutateCases = [
  [
    'missing second reset',
    (f) => {
      f.quality.events = f.quality.events.filter(
        (e) => !(e.kind === 'applied' && e.revision === '4'),
      );
    },
  ],
  [
    'missing first trigger',
    (f) => {
      f.quality.events = f.quality.events.filter(
        (e) => !(e.kind === 'decoderStall' && e.revision === '1'),
      );
    },
  ],
  [
    'second reset reused from first',
    (f) => {
      const a = f.quality.events.filter((e) => e.kind === 'applied');
      a[3].revision = '2';
    },
  ],
  [
    'missing probation event',
    (f) => {
      f.quality.events.splice(f.quality.events.indexOf(evaluated(f, '3')[0]), 1);
    },
  ],
  [
    'missing bridge event',
    (f) => {
      f.quality.events.splice(f.quality.events.indexOf(evaluated(f, '1')[4]), 1);
    },
  ],
  [
    'missing baseline bridge event',
    (f) => {
      f.quality.events.splice(f.quality.events.indexOf(evaluated(f, '2')[4]), 1);
    },
  ],
  [
    'missing interior suffix event',
    (f) => {
      f.quality.events.splice(f.quality.events.indexOf(evaluated(f, '4').at(-2)), 1);
    },
  ],
  [
    'early first confirmation',
    (f) => {
      evaluated(f, '1')[0].reasons.push('trialConfirmed');
    },
  ],
  [
    'early second confirmation',
    (f) => {
      evaluated(f, '3')[1].reasons.push('trialConfirmed');
    },
  ],
  [
    'missing second confirmation',
    (f) => {
      evaluated(f, '3')[2].reasons = ['missingCapacity'];
    },
  ],
  [
    'duplicate confirmation',
    (f) => {
      evaluated(f, '3')[3].reasons.push('trialConfirmed');
    },
  ],
  [
    'confirmation at baseline',
    (f) => {
      evaluated(f, '2')[0].reasons.push('trialConfirmed');
    },
  ],
  [
    'bridging source sequence omitted',
    (f) => {
      evaluated(f, '2')[3].source.previousSequence = '1';
    },
  ],
  [
    'policy sequence reused',
    (f) => {
      evaluated(f, '3')[0].window.sequence = evaluated(f, '2').at(-1).window.sequence;
    },
  ],
  [
    'source owner changed',
    (f) => {
      evaluated(f, '2')[3].source.workerEpoch = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001';
    },
  ],
  [
    'configuration receipt borrowed',
    (f) => {
      evaluated(f, '3')[0].receipt = structuredClone(evaluated(f, '1')[0].receipt);
    },
  ],
  [
    'lifecycle receipt mismatch',
    (f) => {
      f.lifecycleQualification.applications[2].acknowledgedAt += 0.01;
    },
  ],
  [
    'native phase mismatch',
    (f) => {
      f.profileQualification.phases[3].encoderSessionID =
        f.profileQualification.phases[1].encoderSessionID;
    },
  ],
  [
    'foreign admission campaign',
    (f) => {
      f.candidateWitnessQualifications[1].campaign = '1';
    },
  ],
  [
    'forged admission cost',
    (f) => {
      f.candidateWitnessQualifications[1].candidateTransportBitsPerSecond++;
    },
  ],
  [
    'unhealthy transport pressure hidden',
    (f) => {
      evaluated(f, '3')[0].evidence.transport.samples[1].rttMilliseconds = 100;
    },
  ],
  [
    'unhealthy queue hidden',
    (f) => {
      evaluated(f, '4')[0].evidence.queue.states[0].itemFraction = 0.9;
    },
  ],
  [
    'processing evidence borrowed',
    (f) => {
      evaluated(f, '4')[0].evidence.processing = evaluated(f, '2')[0].evidence.processing;
    },
  ],
  [
    'cadence bridge gap',
    (f) => {
      f.cadenceReports.rows = f.cadenceReports.rows.filter(
        (r) => r.evaluatedUptime < 176 || r.evaluatedUptime > 177,
      );
    },
  ],
  [
    'cadence suffix gap',
    (f) => {
      f.cadenceReports.rows = f.cadenceReports.rows.filter(
        (r) => r.evaluatedUptime < 247 || r.evaluatedUptime > 248,
      );
    },
  ],
  [
    'duplicate cadence time',
    (f) => {
      f.cadenceReports.rows.splice(10, 0, structuredClone(f.cadenceReports.rows[10]));
    },
  ],
  [
    'global cadence PTS reused from first cycle',
    (f) => {
      const r = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 180);
      r.response.status.observation.decoderCadence.progress.lastFreshPTS = 1000;
    },
  ],
  [
    'completed source ahead of cadence',
    (f) => {
      const e = evaluated(f, '2')[1],
        r = f.cadenceReports.rows.findLast((r) => r.evaluatedUptime <= e.evaluatedAt);
      r.response.status.observation.decoderCadence.progress.lastFreshPTS = 0;
    },
  ],
  [
    'decoder scope changed between cycles',
    (f) => {
      f.cadenceReports.rows.find(
        (r) => r.evaluatedUptime === 180,
      ).response.status.observation.decoderCadence.scopeID = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001';
    },
  ],
  [
    'unexpected stall in second probation',
    (f) => {
      const r = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 194);
      Object.assign(r.response.status.observation.decoderCadence.progress, {
        ageMs: 1001,
        stalled: true,
      });
      r.observedStall = true;
    },
  ],
  [
    'short first recovery delivery',
    (f) => {
      f.deliveryAudit.rows = f.deliveryAudit.rows.filter(
        (r) => r.appliedRevision !== '2' || r.end < 171,
      );
    },
  ],
  [
    'missing second two-second delivery lane',
    (f) => {
      f.deliveryAudit.rows = f.deliveryAudit.rows.filter(
        (r) => r.appliedRevision !== '4' || r.end - r.start !== 2,
      );
    },
  ],
  [
    'foreign revision delivery',
    (f) => {
      f.deliveryAudit.rows.find((r) => r.appliedRevision === '4').appliedRevision = '2';
    },
  ],
  [
    'delivery frame outside reset phase',
    (f) => {
      f.deliveryAudit.rows[0].frames[0].sourcePTS = f.format.compressedFrames[1].sourcePTS;
    },
  ],
  [
    'foreign delivery receipt',
    (f) => {
      f.deliveryAudit.rows[0].receipt.configuration.id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001';
    },
  ],
  [
    'fault pause reused from first campaign',
    (f) => {
      f.faults.campaigns[1].pauseSentAt = f.faults.campaigns[0].pauseSentAt;
    },
  ],
  [
    'fault confirmation index rebased',
    (f) => {
      f.faults.campaigns[1].confirmedEventIndex = f.faults.campaigns[0].confirmedEventIndex;
    },
  ],
  [
    'reset transition omitted',
    (f) => {
      f.quality.events = f.quality.events.filter(
        (e) => !(e.kind === 'transition' && e.revision === '2'),
      );
    },
  ],
  [
    'extra unsupported invalidation',
    (f) => {
      evaluated(f, '2')[3].kind = 'invalidated';
    },
  ],
  [
    'stopped before closed suffix',
    (f) => {
      f.quality.events.at(-1).closed = false;
    },
  ],
  [
    'unhealthy state with healthy counters',
    (f) => {
      evaluated(f, '3')[0].state = 'degraded';
    },
  ],
  [
    'closed native application',
    (f) => {
      f.quality.events.find((e) => e.kind === 'applied').closed = true;
    },
  ],
  [
    'nonfinite agreed admission costs',
    (f) => {
      const c = f.quality.events.find((e) => e.kind === 'candidate');
      for (const v of [c.candidate, c.candidateAdmission, f.candidateWitnessQualifications[0]]) {
        v.candidateTransportBitsPerSecond = Infinity;
        v.deliveredPaddingBitsPerSecond = Infinity;
      }
    },
  ],
];
for (const [name, mutate] of mutateCases)
  test(`rejects ${name}`, () => {
    const f = repeatedMeasuredPolicyFixture();
    mutate(f);
    assert.throws(() => qualifyRepeatedMeasuredPolicy(f));
  });

test('health and recovery outputs preserve every original global join index', () => {
  const f = repeatedMeasuredPolicyFixture(),
    q = qualifyRepeatedMeasuredPolicy(f);
  for (const h of q.healthHistory) {
    const e = f.quality.events[h.eventIndex];
    assert.equal(e.window.sequence, h.healthSequence);
    assert.equal(e.window.end, h.healthyThrough);
    assert.equal(e.revision, h.revision);
  }
  for (const [i, r] of q.recoveries.entries()) {
    assert.equal(f.quality.events[r.resetEventIndex].revision, String(i * 2 + 2));
    assert.equal(r.sharedCoverage.start, 161 + i * 60);
    assert.equal(r.sharedCoverage.end, 171 + i * 60);
    assert.equal(r.sharedCoverage.qualifiedAt, 172.7 + i * 60);
    for (const w of r.healthyWindows)
      assert.equal(f.quality.events[w.eventIndex].window.sequence, w.policySequence);
    assert(
      q.healthHistory
        .filter((h) => h.revision === String(i * 2 + 2))
        .every((h) => h.healthySince === 161 + i * 60),
    );
  }
});

test('rejects evaluator time reversal despite ordered serialized event times', () => {
  const f = repeatedMeasuredPolicyFixture(),
    rows = evaluated(f, '2'),
    previous = rows[1],
    next = rows[2];
  previous.evaluatedAt = 172.8;
  previous.at = 172.85;
  next.at = 172.9;
  const report = structuredClone(f.cadenceReports.rows.findLast((r) => r.evaluatedUptime <= 171.2));
  report.evaluatedUptime = 172.79;
  report.receivedUptime = 172.78;
  report.response.status.observation.decoderCadence.progress.lastFreshPTS =
    Math.floor((172.79 - 100 - 0.13) * 30) * 3000;
  f.cadenceReports.rows.push(report);
  f.cadenceReports.rows.sort((a, b) => a.evaluatedUptime - b.evaluatedUptime);
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f));
});

import { appendRepeatedPolicyShutdownSource } from './fixtures/repeated-measured-policy-evidence.mjs';
test('qualified shutdown source suffix adds no policy events or health credit', () => {
  const f = repeatedMeasuredPolicyFixture(),
    before = qualifyRepeatedMeasuredPolicy(f);
  const originalEvents = structuredClone(f.quality.events);
  appendRepeatedPolicyShutdownSource(f);
  appendRepeatedPolicyShutdownSource(f);
  const after = qualifyRepeatedMeasuredPolicy(f);
  assert.deepEqual(f.quality.events, originalEvents);
  assert.deepEqual(after, before);
});
for (const [name, mutate] of [
  ['source tail without qualification', (f) => f.sourceIntervalQualification.intervals.pop()],
  ['qualification tail without source', (f) => f.snapshot.sourceIntervals.pop()],
  ['divergent tail sequence', (f) => f.sourceIntervalQualification.intervals.at(-1).sequence++],
  [
    'divergent tail predecessor',
    (f) => f.sourceIntervalQualification.intervals.at(-1).previousSequence--,
  ],
  [
    'divergent tail source boundary',
    (f) => f.sourceIntervalQualification.intervals.at(-1).sourceStartExclusive++,
  ],
  [
    'divergent tail end boundary',
    (f) => f.sourceIntervalQualification.intervals.at(-1).sourceEndInclusive++,
  ],
  [
    'divergent tail frame count',
    (f) => f.sourceIntervalQualification.intervals.at(-1).decodedFrames--,
  ],
  [
    'tail sequence gap',
    (f) => {
      f.snapshot.sourceIntervals.at(-1).sequence = String(
        Number(f.snapshot.sourceIntervals.at(-1).sequence) + 1,
      );
      f.sourceIntervalQualification.intervals.at(-1).sequence++;
    },
  ],
  [
    'reordered raw source array',
    (f) => {
      const r = f.snapshot.sourceIntervals;
      r.unshift(r.pop());
    },
  ],
  [
    'reordered qualified source array',
    (f) => {
      const r = f.sourceIntervalQualification.intervals;
      r.unshift(r.pop());
    },
  ],
  [
    'jointly reordered source arrays',
    (f) => {
      for (const r of [f.snapshot.sourceIntervals, f.sourceIntervalQualification.intervals])
        r.unshift(r.pop());
    },
  ],
  [
    'omitted leading policy source',
    (f) => {
      const index = f.quality.events.findIndex((e) => e.kind === 'evaluated');
      f.quality.events.splice(index, 1);
    },
  ],
  [
    'omitted interior policy source',
    (f) => {
      const index = f.quality.events.findIndex((e) => e.kind === 'evaluated' && e.revision === '2');
      f.quality.events.splice(index, 1);
    },
  ],
])
  test(`shutdown suffix rejects ${name}`, () => {
    const f = appendRepeatedPolicyShutdownSource(repeatedMeasuredPolicyFixture());
    mutate(f);
    assert.throws(() => qualifyRepeatedMeasuredPolicy(f));
  });

for (const [name, mutate] of [
  [
    'unchanged PTS with reset freshness',
    (f) => {
      const rows = f.cadenceReports.rows.filter(
        (r) => r.evaluatedUptime >= 175 && r.evaluatedUptime <= 175.25,
      );
      rows[1].response.status.observation.decoderCadence.progress.lastFreshPTS =
        rows[0].response.status.observation.decoderCadence.progress.lastFreshPTS;
      rows[1].response.status.observation.decoderCadence.progress.ageMs = 10;
    },
  ],
  [
    'unchanged PTS with age reversal',
    (f) => {
      const a = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 175),
        b = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 175.25);
      a.response.status.observation.decoderCadence.progress.ageMs = 200;
      Object.assign(b.response.status.observation.decoderCadence.progress, {
        lastFreshPTS: a.response.status.observation.decoderCadence.progress.lastFreshPTS,
        ageMs: 0,
      });
    },
  ],
  [
    'unchanged PTS with impossible age jump',
    (f) => {
      const a = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 175),
        b = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 175.25);
      Object.assign(b.response.status.observation.decoderCadence.progress, {
        lastFreshPTS: a.response.status.observation.decoderCadence.progress.lastFreshPTS,
        ageMs: 800,
      });
    },
  ],
  [
    'freshness reset across first resumption boundary',
    (f) => {
      const a = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 160.81),
        b = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 161);
      Object.assign(b.response.status.observation.decoderCadence.progress, {
        lastFreshPTS: a.response.status.observation.decoderCadence.progress.lastFreshPTS,
        ageMs: 10,
      });
    },
  ],
  [
    'freshness reset across second resumption boundary',
    (f) => {
      const a = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 220.81),
        b = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 221);
      Object.assign(b.response.status.observation.decoderCadence.progress, {
        lastFreshPTS: a.response.status.observation.decoderCadence.progress.lastFreshPTS,
        ageMs: 10,
      });
    },
  ],
])
  test(`global progress rejects ${name}`, () => {
    const f = repeatedMeasuredPolicyFixture();
    mutate(f);
    assert.throws(
      () => qualifyRepeatedMeasuredPolicy(f),
      /Inconsistent global decoder last-fresh time/,
    );
  });

test('global progress permits a genuinely cached snapshot with increasing sample age', () => {
  const f = repeatedMeasuredPolicyFixture();
  const original = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 175);
  const cached = structuredClone(original);
  cached.evaluatedUptime = 175.1;
  cached.receivedUptime = 175.09;
  cached.response.status.decoderCadenceAgeUpperBoundMs = 100;
  cached.sampleAgeSeconds = 0.12;
  f.cadenceReports.rows.push(cached);
  f.cadenceReports.rows.sort((a, b) => a.evaluatedUptime - b.evaluatedUptime);
  assert.equal(
    cached.response.status.observation.decoderCadence.progress.lastFreshPTS,
    original.response.status.observation.decoderCadence.progress.lastFreshPTS,
  );
  assert.equal(
    cached.response.status.observation.decoderCadence.progress.ageMs,
    original.response.status.observation.decoderCadence.progress.ageMs,
  );
  assert.equal(qualifyRepeatedMeasuredPolicy(f).repeatedPolicyQualified, true);
});

test('global progress tolerates different feasible sample locations inside age bounds', () => {
  const f = repeatedMeasuredPolicyFixture();
  const report = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 160.25);
  report.response.status.observation.decoderCadence.progress.ageMs += 5;
  assert.equal(qualifyRepeatedMeasuredPolicy(f).repeatedPolicyQualified, true);
});

test('global progress rejects a newer PTS whose arrival must precede the previous fresh arrival', () => {
  const f = repeatedMeasuredPolicyFixture();
  f.cadenceReports.rows.find(
    (r) => r.evaluatedUptime === 175.25,
  ).response.status.observation.decoderCadence.progress.ageMs = 900;
  assert.throws(
    () => qualifyRepeatedMeasuredPolicy(f),
    /Inconsistent global decoder last-fresh time/,
  );
});

test('global progress retains the cumulative intersection, not just adjacent overlap', () => {
  const f = repeatedMeasuredPolicyFixture();
  const first = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 175);
  first.response.status.observation.decoderCadence.progress.ageMs = 50;
  const reports = [first];
  for (const [at, ageMs] of [
    [175.1, 135],
    [175.2, 220],
  ]) {
    const report = structuredClone(first);
    report.evaluatedUptime = at;
    report.receivedUptime = at - 0.01;
    report.response.status.observation.decoderCadence.progress.ageMs = ageMs;
    reports.push(report);
    f.cadenceReports.rows.push(report);
  }
  const bounds = reports.map((r) => {
    const upper =
      r.evaluatedUptime - r.response.status.observation.decoderCadence.progress.ageMs / 1000;
    return { lower: upper - r.sampleAgeSeconds, upper };
  });
  assert(bounds[1].lower < bounds[0].upper && bounds[2].lower < bounds[1].upper);
  assert(bounds[2].lower > bounds[0].upper);
  f.cadenceReports.rows.sort((a, b) => a.evaluatedUptime - b.evaluatedUptime);
  assert.throws(
    () => qualifyRepeatedMeasuredPolicy(f),
    /Inconsistent global decoder last-fresh time/,
  );
});

test('synthetic owned pause samples and native reports share a feasible physical arrival timeline', () => {
  for (const routes of [
    ['decoderStall', 'decoderStall'],
    ['deliveryFailure', 'deliveryFailure'],
    ['decoderStall', 'deliveryFailure'],
    ['deliveryFailure', 'decoderStall'],
  ]) {
    const f = repeatedMeasuredPolicyFixture(repeatedMeasuredDeliveryFaultFixture(routes));
    for (let i = 0; i < 2; i++) {
      const fault = f.faults.campaigns[i],
        delivery = routes[i] === 'deliveryFailure',
        shift = i * 60;
      const frame = (delivery ? 1715 : 1760) + i * 1800,
        arrivedAt = delivery ? 158.97 + shift : 100 + frame / 30 + 0.1,
        pausedAt = fault.pauseSentAt / 1000 + 59,
        resumedAt = fault.resumeSentAt / 1000 + 59;
      assert.equal(fault.resumeSentAt - fault.pauseSentAt, 1800);
      assert(arrivedAt < pausedAt);
      for (const sample of [fault.beforePauseSample, fault.pausedSample]) {
        const upper =
          sample.receivedAt / 1000 + 59 - sample.value.decoderCadence.progress.ageMs / 1000;
        const ageUpper =
          (sample.receivedAt -
            sample.requestStartedAt +
            sample.value.decoderCadenceAgeUpperBoundMs) /
          1000;
        assert(arrivedAt >= upper - ageUpper - 1e-9 && arrivedAt <= upper + 1e-9);
      }
      const frozen = f.cadenceReports.rows.filter(
        (r) => r.evaluatedUptime >= pausedAt && r.evaluatedUptime < resumedAt,
      );
      assert(frozen.length >= 5);
      for (const r of frozen) {
        const progress = r.response.status.observation.decoderCadence.progress;
        assert.equal(progress.lastFreshPTS, frame * 3000);
        const upper = r.evaluatedUptime - progress.ageMs / 1000;
        assert(arrivedAt >= upper - r.sampleAgeSeconds - 1e-9 && arrivedAt <= upper + 1e-9);
      }
      const resumed = f.cadenceReports.rows.find(
        (r) =>
          r.evaluatedUptime >= resumedAt &&
          r.response.status.observation.decoderCadence.progress.lastFreshPTS > frame * 3000,
      );
      assert.equal(resumed.evaluatedUptime, 160.81 + shift);
      if (delivery) {
        const lane = f.deliveryAudit.rows.find((r) => r.appliedRevision === String(i * 2 + 1));
        assert.equal(lane.result.onTimeFrames, 0);
        assert.equal(lane.result.lateFrames, 6);
        assert.equal(lane.result.missingFrames, 24);
      }
    }
  }
});

test('owned-stall allowance cannot refresh the unchanged last-fresh arrival', () => {
  const f = repeatedMeasuredPolicyFixture();
  const trigger = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 159.88);
  const later = f.cadenceReports.rows.find((r) => r.evaluatedUptime === 160.25);
  assert.equal(later.observedStall, true);
  assert.equal(
    later.response.status.observation.decoderCadence.progress.lastFreshPTS,
    trigger.response.status.observation.decoderCadence.progress.lastFreshPTS,
  );
  later.response.status.observation.decoderCadence.progress.ageMs =
    trigger.response.status.observation.decoderCadence.progress.ageMs;
  assert.throws(
    () => qualifyRepeatedMeasuredPolicy(f),
    /Inconsistent global decoder last-fresh time/,
  );
});
