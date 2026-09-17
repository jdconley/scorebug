import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { qualifyMeasuredCandidateWitness as qualify } from '../measured-candidate-witness.mjs';

const fixture = () =>
  JSON.parse(
    fs.readFileSync(
      new URL('./fixtures/measured-candidate-witness-diagnostic-a.json', import.meta.url),
    ),
  );

test('replays actual rejected diagnostic-a admission witness without granting health or upgrade', () => {
  assert.equal(typeof qualify, 'function');
  const f = fixture();
  const result = qualify(f);
  assert.equal(f.provenance.runtimeDecision.kind, 'rejected');
  assert.equal(f.provenance.runtimeDecision.reason, 'candidate-staleAdvice');
  assert.equal(result.witnessQualified, true);
  assert.equal(result.headroomQualified, true);
  assert.equal(result.upgradeAuthorized, false);
  assert.equal(result.mediaHealthQualified, false);
  assert.equal(result.candidateTransportBitsPerSecond, f.witness.candidateTransportBitsPerSecond);
  assert.equal(result.deliveredPaddingBitsPerSecond, f.witness.deliveredPaddingBitsPerSecond);
  assert.equal(result.validUntil, f.witness.validUntil);
  assert.deepEqual(
    result.selectedIntervalIndexes,
    f.witness.intervals.map((i) =>
      f.intervals.intervals.findIndex(
        (r) => r.end.observedAtNanoseconds === i.end.snapshot.observedAtNanoseconds,
      ),
    ),
  );
});

const mutations = {
  'candidate identity': (f) => {
    f.witness.measurement.id = f.witness.applied.attemptID;
  },
  'candidate scope revision': (f) => {
    f.witness.measurement.scope.appliedProfileRevision = '0';
  },
  'applied revision': (f) => {
    f.witness.applied.revision = '1';
  },
  'bootstrap receipt configuration': (f) => {
    f.witness.applied.receipt.configurationID = f.witness.applied.attemptID;
  },
  'bootstrap receipt PTS': (f) => {
    f.witness.applied.receipt.lastSubmittedPTS.value = '7740';
  },
  'candidate admitted boundary': (f) => {
    f.witness.measurement.firstInputAt += 0.01;
  },
  'candidate submission duration': (f) => {
    f.witness.measurement.submissionDuration += 0.01;
  },
  'raw transport mismatch': (f) => {
    f.candidateProof.measurement.transport.mux.transportBytes += 188;
  },
  'qualified transport mismatch': (f) => {
    f.candidate.transport.transportBytes += 188;
  },
  'witness cost rate': (f) => {
    f.witness.candidateTransportBitsPerSecond -= 1;
  },
  'uncovered selected interval': (f) => {
    f.intervalQualification.coveredIntervalIndexes = [];
  },
  'reversed pair': (f) => {
    f.witness.intervals.reverse();
  },
  'interval worker identity': (f) => {
    f.witness.intervals[0].end.workerAttempt++;
  },
  'interval receiver counter': (f) => {
    f.witness.intervals[0].start.deliveredMessages = '2941';
  },
  'interval pending packets': (f) => {
    f.witness.intervals[0].start.pendingPackets = 1;
  },
  'interval duration': (f) => {
    f.witness.intervals[0].durationNanoseconds = '1064889752';
  },
  'interval payload lower bound': (f) => {
    f.witness.intervals[0].deliveredPayloadBytesLowerBound = '1306976';
  },
  'interval counter rate': (f) => {
    f.witness.intervals[0].payloadBitsPerSecondLowerBound++;
  },
  'padding rate': (f) => {
    f.witness.deliveredPaddingBitsPerSecond++;
  },
  'projection bracket': (f) => {
    f.witness.clock.before -= 0.11;
  },
  'clock after evaluation': (f) => {
    f.witness.clock.after += 0.01;
  },
  'expired candidate cost': (f) => {
    f.witness.clock.before += 2;
    f.witness.clock.after += 2;
    f.witness.evaluatedAt += 2;
  },
  'forged narrower newer offset': (f) => {
    f.witness.intervals[1].receiverClockOffsetUptimeBounds[0] += 0.001;
    f.witness.clock.receiverClockOffsetUptimeBounds[0] += 0.001;
  },
  'endpoint projection': (f) => {
    f.witness.intervals[0].startUptimeBounds[0] += 0.01;
  },
  'request projection': (f) => {
    f.witness.intervals[1].end.requestStartedAtUptimeBounds[0] += 0.01;
  },
  'snapshot freshness': (f) => {
    f.witness.intervals[1].end.snapshotAgeUpperBoundSeconds -= 0.001;
  },
  'delivery freshness': (f) => {
    f.witness.intervals[1].end.lastDeliveryAgeUpperBoundSeconds -= 0.001;
  },
  'extended deadline': (f) => {
    f.witness.validUntil += 0.01;
  },
  'shortened deadline': (f) => {
    f.witness.validUntil -= 0.01;
  },
  'probe identity': (f) => {
    f.witness.probe.id = f.witness.applied.attemptID;
  },
  'probe stage': (f) => {
    f.witness.probe.stage = 2;
  },
  'probe start': (f) => {
    f.witness.probe.startedAt -= 0.01;
  },
  'probe counter exceeds independent history': (f) => {
    f.witness.probe.acceptedPayloadBytes = '16776536';
  },
  'probe lease': (f) => {
    f.witness.probe.leaseDeadline += 0.001;
  },
  'probe withdrawn': (f) => {
    f.witness.probe.reason = 'expired';
  },
  'binding mismatch': (f) => {
    f.witness.binding.acceptedPayloadBytes = '740908';
  },
  'binding too early': (f) => {
    f.witness.boundAt = f.witness.binding.startedAt + 0.49;
  },
  'completed time': (f) => {
    f.witness.completedAt -= 0.1;
  },
  'native scope': (f) => {
    f.nativeProof.scope.matchID = 'other';
  },
  'native prior withdrawal': (f) => {
    f.nativeProof.events.find((e) => e.sample.stage === 3).sample.reason = 'expired';
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects ${name}`, () => {
    assert.equal(typeof qualify, 'function');
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });

test('receipt UUID comparison accepts native uppercase representation', () => {
  assert.equal(typeof qualify, 'function');
  const f = fixture();
  for (const key of ['configurationID', 'encoderSessionID'])
    f.witness.applied.receipt[key] = f.witness.applied.receipt[key].toUpperCase();
  assert.equal(qualify(f).witnessQualified, true);
});

test('future receiver observations never refine the admission clock or choose another pair', () => {
  assert.equal(typeof qualify, 'function');
  const f = fixture(),
    expected = qualify(f);
  for (const row of f.intervals.intervals.filter((r) => r.evaluatedAt > f.witness.evaluatedAt)) {
    row.requestStartedAt += 100;
    row.responseReceivedAt += 100;
    row.evaluatedAt += 100;
  }
  assert.deepEqual(qualify(f), expected);
});

test('actual raw artifact hashes are recorded without treating rejection as authorization', () => {
  const f = fixture();
  assert.ok(Object.keys(f.provenance.rawSha256).length >= 7);
  assert.ok(Object.values(f.provenance.rawSha256).every((h) => /^[0-9a-f]{64}$/.test(h)));
});

test('valid witness with insufficient measured margin stays valid but fails headroom', () => {
  const f = fixture();
  for (const key of ['transportBytes', 'transportMessageCount']) {
    f.witness.measurement[key] *= 3;
    f.candidate.transport[key] *= 3;
    f.candidateProof.measurement.transport.mux[key] *= 3;
  }
  const m = f.witness.measurement;
  f.witness.candidateTransportBitsPerSecond =
    ((m.transportBytes + 44 * m.transportMessageCount) * 8) /
    Math.min(m.sourceDuration, m.submissionDuration);
  const r = qualify(f);
  assert.equal(r.witnessQualified, true);
  assert.equal(r.headroomQualified, false);
  assert.equal(r.upgradeAuthorized, false);
  assert.equal(r.mediaHealthQualified, false);
});

for (const side of ['below', 'above'])
  test(`enforces 25 percent margin with transport cost ${side} threshold`, () => {
    const f = fixture(),
      m = f.witness.measurement;
    const messages = 4000;
    const boundaryBytes =
      ((f.witness.deliveredPaddingBitsPerSecond / 1.25) *
        Math.min(m.sourceDuration, m.submissionDuration)) /
        8 -
      44 * messages;
    const bytes =
      (side === 'below' ? Math.floor(boundaryBytes / 188) : Math.ceil(boundaryBytes / 188)) * 188;
    for (const p of [m, f.candidate.transport, f.candidateProof.measurement.transport.mux]) {
      p.transportBytes = bytes;
      p.transportMessageCount = messages;
    }
    f.witness.candidateTransportBitsPerSecond =
      ((bytes + 44 * messages) * 8) / Math.min(m.sourceDuration, m.submissionDuration);
    assert.equal(qualify(f).headroomQualified, side === 'below');
  });

test('strict first-start chronology uses the newer offset for both intervals', () => {
  const f = fixture(),
    w = f.witness;
  const firstStart =
    Number(w.intervals[0].start.observedAtNanoseconds) / 1e9 +
    w.clock.receiverClockOffsetUptimeBounds[0];
  w.measurement.firstInputAt = firstStart + 0.00001;
  f.candidateProof.measurement.encoding.frames[0].admittedAt = w.measurement.firstInputAt;
  assert.throws(() => qualify(f), /Coverage predates fresh candidate input/);
});

test('candidate overlap requires first start upper strictly before last input', () => {
  const f = fixture(),
    w = f.witness;
  w.measurement.lastInputAt =
    Number(w.intervals[0].start.observedAtNanoseconds) / 1e9 +
    w.clock.receiverClockOffsetUptimeBounds[1];
  f.candidateProof.measurement.encoding.frames.at(-1).admittedAt = w.measurement.lastInputAt;
  assert.throws(() => qualify(f), /No strict candidate overlap/);
});

test('newest receiver end must be strictly after candidate completion', () => {
  const f = fixture(),
    w = f.witness;
  w.measurement.endedAt =
    Number(w.intervals[1].end.snapshot.observedAtNanoseconds) / 1e9 +
    w.clock.receiverClockOffsetUptimeBounds[0];
  f.candidateProof.measurement.endedAt = w.measurement.endedAt;
  w.completedAt = w.measurement.endedAt + 0.01;
  f.candidateProof.probeBinding.completedAt = w.completedAt;
  assert.throws(() => qualify(f), /Receiver completion chronology/);
});

test('rejects counter disagreement at equal native acceptance timestamps', () => {
  const f = fixture(),
    w = f.witness;
  const next = f.nativeProof.events.find(
    (e) => e.sample.stage === 3 && e.sample.lastAcceptedAt > w.probe.lastAcceptedAt,
  );
  next.sample.lastAcceptedAt = w.probe.lastAcceptedAt;
  assert.throws(() => qualify(f));
});

test('cannot tighten both intervals with a fabricated future clock intersection', () => {
  const f = fixture(),
    w = f.witness;
  // Invent input chronology that only the fabricated narrower bounds can admit.
  w.measurement.firstInputAt =
    Number(w.intervals[0].start.observedAtNanoseconds) / 1e9 +
    w.clock.receiverClockOffsetUptimeBounds[0] +
    0.0005;
  f.candidateProof.measurement.encoding.frames[0].admittedAt = w.measurement.firstInputAt;
  for (const i of w.intervals) {
    i.receiverClockOffsetUptimeBounds[0] += 0.001;
    i.receiverClockOffsetUptimeBounds[1] -= 0.001;
    i.startUptimeBounds[0] += 0.001;
    i.startUptimeBounds[1] -= 0.001;
    i.endUptimeBounds[0] += 0.001;
    i.endUptimeBounds[1] -= 0.001;
  }
  w.clock.receiverClockOffsetUptimeBounds = [...w.intervals[1].receiverClockOffsetUptimeBounds];
  assert.throws(() => qualify(f));
});

test('accepts conservative clock tightening by unexported intermediate polls', () => {
  const f = fixture(),
    w = f.witness,
    i = w.intervals[1];
  i.receiverClockOffsetUptimeBounds[0] += 0.001;
  i.receiverClockOffsetUptimeBounds[1] -= 0.001;
  i.startUptimeBounds[0] += 0.001;
  i.startUptimeBounds[1] -= 0.001;
  i.endUptimeBounds[0] += 0.001;
  i.endUptimeBounds[1] -= 0.001;
  w.clock.receiverClockOffsetUptimeBounds = [...i.receiverClockOffsetUptimeBounds];
  assert.equal(qualify(f).witnessQualified, true);
});

test('rejects an old receiver pair when a newer interval was already available', () => {
  const f = fixture(),
    w = f.witness;
  const oldBefore = w.clock.before,
    width = w.clock.after - oldBefore;
  const p = f.nativeProof.events.find(
    (e) => e.observedAt > f.intervals.intervals[19].evaluatedAt && e.sample.stage === 3,
  );
  w.clock.before = p.observedAt;
  w.clock.after = p.observedAt + width;
  w.evaluatedAt = w.clock.after;
  w.probe = structuredClone(p.sample);
  for (const i of w.intervals) {
    i.end.snapshotAgeUpperBoundSeconds += w.clock.before - oldBefore;
    i.end.lastDeliveryAgeUpperBoundSeconds += w.clock.before - oldBefore;
  }
  const n = w.intervals[1].end;
  w.validUntil = Math.min(
    w.measurement.endedAt + 2,
    w.probe.leaseDeadline,
    w.clock.before + 1.5 - n.snapshotAgeUpperBoundSeconds,
    w.clock.before + 1.5 - n.lastDeliveryAgeUpperBoundSeconds,
  );
  assert.throws(() => qualify(f), /latest receiver pair/);
});

test('rejects old counters paired with a newer native renewal lease', () => {
  const f = fixture();
  f.witness.probe.acceptedPayloadBytes = '6580000';
  f.witness.probe.lastAcceptedAt = 1326232.4601614168;
  assert.throws(() => qualify(f), /renewal floor/);
});
