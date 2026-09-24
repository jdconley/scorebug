import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyRepeatedRecoveryInvalidations as qualify } from '../repeated-recovery-invalidation.mjs';
import { qualifyRepeatedMeasuredPolicy } from '../repeated-measured-policy.mjs';
import { repeatedSourceExpiryFixture as fixture } from './fixtures/repeated-source-expiry-evidence.mjs';
const rejection = (f) => f.quality.events.find((e) => e.kind === 'rejected');
for (const revision of ['2', '4'])
  test(`source expiry in revision${revision} records invalidation without policy credit`, () => {
    const f = fixture({ revision }),
      before = JSON.stringify(f),
      e = rejection(f);
    const result = qualify(f);
    assert.equal(result.length, 1);
    const d = result[0];
    assert.equal(d.kind, 'source-expiry');
    assert.equal(d.eventIndex, f.quality.events.indexOf(e));
    assert.equal(d.sourceSequence, e.source.sequence);
    assert.equal(d.revision, revision);
    assert.equal(d.evaluatedAt, e.evaluationDiagnostic.session.evaluatedAt);
    assert.equal(JSON.stringify(f), before);
  });
test('policy replay consumes rejected source but no policy sequence and rebuilds recovery', () => {
  const f = fixture(),
    result = qualifyRepeatedMeasuredPolicy(f);
  assert.equal(result.invalidations.length, 1);
  assert.equal(result.recoveries.length, 2);
  assert(result.recoveries[1].sharedCoverage.start > rejection(f).evaluationDiagnostic.caughtAt);
});

function evidence(f) {
  const event = rejection(f),
    source = f.snapshot.sourceIntervals.find((s) => s.sequence === event.source.sequence);
  const proof = f.sourceIntervalQualification.intervals.find(
    (s) => s.sequence === Number(event.source.sequence),
  );
  const reportIndex = f.cadenceReports.rows.findIndex(
    (r) =>
      r.response.status.observation.decodedVideo?.completed?.sequence ===
      Number(event.source.sequence),
  );
  const reports = f.cadenceReports.rows,
    first = reports[reportIndex];
  const selected = reports.findLast(
    (r) => r.evaluatedUptime <= event.evaluationDiagnostic.selectedAt,
  );
  const next = reports.find((r) => r.evaluatedUptime > event.evaluationDiagnostic.caughtAt);
  return {
    event,
    source,
    proof,
    first,
    selected,
    next,
    previous: reports[reportIndex - 1],
    trace: event.evaluationDiagnostic,
    session: event.evaluationDiagnostic.session,
  };
}
const foreign = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
for (const [name, mutate] of [
  [
    'another rejection reason',
    (_, e) => {
      e.event.reason = 'duration';
    },
  ],
  [
    'another diagnostic kind',
    (_, e) => {
      e.session.kind = 'cadence';
    },
  ],
  [
    'cadence receipt on source rejection',
    (_, e) => {
      e.session.cadenceReceiptID = foreign;
    },
  ],
  [
    'foreign diagnostic source key',
    (_, e) => {
      e.session.sourceKey.readerID = foreign;
    },
  ],
  [
    'successful window metadata',
    (_, e) => {
      e.event.window = {};
    },
  ],
  [
    'successful policy action',
    (_, e) => {
      e.event.action = { kind: 'none' };
    },
  ],
  [
    'foreign current receipt',
    (_, e) => {
      e.event.receipt = structuredClone(e.event.receipt);
      e.event.receipt.bitRate++;
    },
  ],
  [
    'foreign native configuration',
    (_, e) => {
      e.source.encodingConfiguration.id = foreign;
    },
  ],
  [
    'foreign encoder session',
    (_, e) => {
      e.source.encodingConfiguration.encoderSessionID = foreign;
    },
  ],
  [
    'foreign source generation',
    (_, e) => {
      e.source.publishingGeneration++;
    },
  ],
  [
    'foreign source worker',
    (_, e) => {
      e.source.workerId = 'foreign-worker';
    },
  ],
  [
    'foreign source publication',
    (_, e) => {
      e.source.publication = structuredClone(e.source.publication);
      e.source.publication.publisherId = foreign;
    },
  ],
  [
    'foreign source attempt',
    (_, e) => {
      e.event.source.attemptID = foreign;
    },
  ],
  [
    'foreign processing scope',
    (_, e) => {
      e.source.processing.scopeID = foreign;
    },
  ],
  [
    'missing source proof',
    (f, e) => {
      f.sourceIntervalQualification.intervals = f.sourceIntervalQualification.intervals.filter(
        (p) => p !== e.proof,
      );
    },
  ],
  [
    'duplicate source proof',
    (f, e) => {
      f.sourceIntervalQualification.intervals.push(structuredClone(e.proof));
    },
  ],
  [
    'duplicate original source',
    (f, e) => {
      f.snapshot.sourceIntervals.push(structuredClone(e.source));
    },
  ],
  [
    'wrong proof prefix',
    (_, e) => {
      e.proof.previousSequence--;
    },
  ],
  [
    'wrong proof frame boundary',
    (_, e) => {
      e.proof.sourceEndInclusive--;
    },
  ],
  [
    'wrong proof frame count',
    (_, e) => {
      e.proof.decodedFrames--;
    },
  ],
  [
    'nonconsecutive source',
    (_, e) => {
      e.event.source.previousSequence = String(Number(e.event.source.previousSequence) - 1);
    },
  ],
  [
    'already expired selection',
    (_, e) => {
      e.trace.selectedAt = e.event.source.end + 2.0001;
    },
  ],
  [
    'source age at the evaluation boundary',
    (_, e) => {
      e.trace.dispatchedAt = e.event.source.end + 2;
      e.session.evaluatedAt = e.trace.dispatchedAt;
      e.session.sourceAgeSeconds = 2;
    },
  ],
  [
    'forged source age',
    (_, e) => {
      e.session.sourceAgeSeconds += 0.001;
    },
  ],
  [
    'reversed dispatch clock',
    (_, e) => {
      e.trace.dispatchedAt = e.trace.selectedAt - 0.001;
    },
  ],
  [
    'unbounded duration',
    (_, e) => {
      e.source.captureBoundaryStartTime = e.event.source.start = e.event.source.end - 5.251;
    },
  ],
  [
    'missing previous receipt anchor',
    (_, e) => {
      e.previous.response.status.observation.decodedVideo.completed = null;
    },
  ],
  [
    'contradictory previous anchor',
    (_, e) => {
      e.previous.response.status.observation.decodedVideo.completed.lastPTS--;
    },
  ],
  [
    'contradictory repeated source',
    (_, e) => {
      e.selected.response.status.observation.decodedVideo.completed.firstPTS++;
    },
  ],
  [
    'revoked source before selection',
    (_, e) => {
      e.selected.response.status.observation.decodedVideo.ended = true;
    },
  ],
  [
    'foreign repeated source owner',
    (_, e) => {
      e.selected.response.status.workerEpoch = foreign;
    },
  ],
  [
    'source helper age outside original clock bracket',
    (_, e) => {
      e.session.sampleAgeSeconds = 0.02;
    },
  ],
  [
    'source helper beyond independent upper clock bound',
    (_, e) => {
      e.session.sampleAgeSeconds += 0.01;
    },
  ],
  [
    'stale source helper',
    (_, e) => {
      e.session.sampleAgeSeconds = 2.001;
    },
  ],
  [
    'expired original source lease',
    (_, e) => {
      e.first.response.status.expiresAt = e.first.response.serverTime;
    },
  ],
  [
    'forged original request duration',
    (_, e) => {
      e.first.requestSeconds += 0.01;
    },
  ],
  [
    'forged original timing stages',
    (_, e) => {
      e.first.timing.statusRequestStartedUptime -= 0.01;
    },
  ],
  [
    'stale independent cadence',
    (_, e) => {
      e.selected.response.status.decoderCadenceAgeUpperBoundMs = 250;
      e.selected.sampleAgeSeconds = 0.25 + e.selected.requestSeconds + e.selected.residenceSeconds;
      e.selected.observedStall = null;
    },
  ],
  [
    'cadence expires before source evaluation',
    (_, e) => {
      e.selected.response.status.decoderCadenceAgeUpperBoundMs = 220;
      e.selected.sampleAgeSeconds = 0.22 + e.selected.requestSeconds + e.selected.residenceSeconds;
    },
  ],
  [
    'foreign following cadence owner',
    (_, e) => {
      e.next.response.status.workerEpoch = foreign;
    },
  ],
  [
    'following cadence PTS regression',
    (_, e) => {
      e.next.response.status.observation.decoderCadence.progress.lastFreshPTS = 0;
    },
  ],
])
  test(`source expiry rejects ${name}`, () => {
    const f = fixture();
    mutate(f, evidence(f));
    assert.throws(() => qualify(f));
  });

test('duplicate source rejection cannot consume the same source twice', () => {
  const f = fixture(),
    e = rejection(f);
  f.quality.events.splice(f.quality.events.indexOf(e) + 1, 0, structuredClone(e));
  assert.throws(
    () => qualifyRepeatedMeasuredPolicy(f),
    /Duplicate rejected source|Overlapping rejected/,
  );
});
test('omitting rejected source leaves a gap in the original consumed source prefix', () => {
  const f = fixture();
  f.quality.events = f.quality.events.filter((e) => e.kind !== 'rejected');
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f));
});
test('rejected source cannot advance Core policy sequence', () => {
  const f = fixture(),
    e = rejection(f),
    next = f.quality.events.find((x) => x.kind === 'evaluated' && x.at > e.at);
  next.window.sequence = String(Number(next.window.sequence) + 1);
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f), /Missing or reused policy decision/);
});
test('pre-rejection health cannot fill a shortened whole recovery prefix', () => {
  const f = fixture();
  f.quality.events = f.quality.events.filter(
    (e) => !(e.kind === 'evaluated' && e.revision === '4' && e.source.end > 241),
  );
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f), /shared recovery coverage/i);
});
test('source invalidation awards no stale cadence exception', () => {
  const f = fixture(),
    e = evidence(f),
    r = e.first;
  r.response.status.decoderCadenceAgeUpperBoundMs = 250;
  r.sampleAgeSeconds = 0.25 + r.requestSeconds + r.residenceSeconds;
  r.observedStall = null;
  assert.equal(qualify(f).length, 1, 'Source helper proof is independently valid');
  assert.throws(() => qualifyRepeatedMeasuredPolicy(f), /cadence|stall/i);
});
