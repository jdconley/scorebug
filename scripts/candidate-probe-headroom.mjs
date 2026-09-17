import assert from 'node:assert/strict';

const time = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e12;
const integer = (n, maximum) => Number.isSafeInteger(n) && n > 0 && n <= maximum;
const seconds = (s) => {
  assert.ok(typeof s === 'string' && /^(0|[1-9][0-9]{0,13})$/.test(s));
  const n = BigInt(s);
  assert.ok(n <= 86400000000000n);
  return Number(n) / 1e9;
};
const counter = (s) => {
  assert.ok(typeof s === 'string' && /^(0|[1-9][0-9]{0,7})$/.test(s));
  const n = Number(s);
  assert.ok(n <= 16 * 1024 * 1024);
  return n;
};

/** Joins outputs of the full candidate/native-probe/receiver replay gates.
 * This historical IPv4 load relation does not qualify current media health or
 * authorize a production upgrade. Callers must run those independent gates first. */
export function qualifyCandidateProbeHeadroom({
  candidate,
  candidateProof,
  accepted,
  nativeProof,
  intervals,
  intervalQualification,
}) {
  const m = candidateProof.measurement,
    binding = candidateProof.probeBinding;
  for (const scope of [candidate.scope, m.scope, nativeProof.scope, intervals.scope])
    assert.deepEqual(scope, candidateProof.scope);
  assert.equal(candidate.frames, 121);
  assert.equal(accepted.mode, 'staged');
  assert.equal(accepted.schedule, 'candidate-headroom-v1');
  assert.equal(m.transport.publishingGeneration, accepted.publishingGeneration);
  const stage = accepted.stages.find((s) => s.stage === 3);
  assert.ok(stage && stage.bitRate === 12000000 && binding);
  for (const at of [
    m.startedAt,
    m.endedAt,
    binding.boundAt,
    binding.completedAt,
    stage.startedAt,
    stage.retirementRequestedAt,
  ])
    assert.ok(time(at));
  assert.ok(
    stage.startedAt + 0.5 <= binding.boundAt &&
      binding.boundAt <= m.startedAt &&
      m.startedAt <= m.endedAt &&
      m.endedAt <= binding.completedAt &&
      binding.completedAt < stage.retirementRequestedAt,
  );
  for (const [index, snapshot] of [binding.initial, binding.final].entries()) {
    assert.ok(snapshot && snapshot.id.toLowerCase() === stage.id.toLowerCase());
    assert.equal(snapshot.publishingGeneration, accepted.publishingGeneration);
    assert.equal(snapshot.stage, 3);
    assert.equal(snapshot.bitRate, stage.bitRate);
    assert.equal(snapshot.startedAt, stage.startedAt);
    assert.equal(snapshot.reason, null);
    for (const at of [snapshot.observedAt, snapshot.leaseDeadline, snapshot.lastAcceptedAt])
      assert.ok(time(at));
    assert.ok(
      snapshot.startedAt <= snapshot.lastAcceptedAt &&
        snapshot.lastAcceptedAt <= snapshot.observedAt &&
        snapshot.observedAt < snapshot.leaseDeadline &&
        snapshot.leaseDeadline - 0.3 <= snapshot.observedAt + 1e-6,
    );
    const acceptedBytes = counter(snapshot.acceptedPayloadBytes);
    assert.ok(
      acceptedBytes > 0 &&
        acceptedBytes % 1316 === 0 &&
        acceptedBytes <= stage.acceptedPayloadBytes,
    );
    const events = nativeProof.events.filter((e) => e.sample.stage === 3);
    assert.ok(
      events.some((e) => e.sample.leaseDeadline === snapshot.leaseDeadline),
      'Unobserved binding lease',
    );
    for (const event of events) {
      const n = counter(event.sample.acceptedPayloadBytes),
        last = event.sample.lastAcceptedAt;
      if (last === snapshot.lastAcceptedAt) assert.equal(n, counter(snapshot.acceptedPayloadBytes));
      else if (last === null || last < snapshot.lastAcceptedAt)
        assert.ok(n <= counter(snapshot.acceptedPayloadBytes));
      else assert.ok(n >= counter(snapshot.acceptedPayloadBytes));
      if (event.observedAt <= snapshot.observedAt) assert.equal(event.sample.reason, null);
    }
    if (index === 0) assert.equal(snapshot.observedAt, binding.boundAt);
    else assert.ok(m.endedAt <= snapshot.observedAt && snapshot.observedAt <= binding.completedAt);
  }
  const frames = m.encoding.frames,
    firstAt = frames[0].admittedAt,
    lastAt = frames.at(-1).admittedAt;
  assert.ok(
    time(firstAt) &&
      time(lastAt) &&
      m.startedAt <= firstAt &&
      firstAt < lastAt &&
      lastAt <= m.endedAt,
  );
  const mux = m.transport.mux;
  for (const key of ['transportBytes', 'transportMessageCount'])
    assert.equal(mux[key], candidate.transport[key]);
  assert.ok(
    integer(mux.transportBytes, 40 * 1024 * 1024) && integer(mux.transportMessageCount, 250000),
  );
  assert.ok(
    mux.transportMessageCount * 188 <= mux.transportBytes &&
      mux.transportBytes <= mux.transportMessageCount * 1316,
  );
  for (const n of [candidate.sourceDuration, candidate.submissionDuration])
    assert.ok(time(n) && n >= 1 && n <= 5);
  const duration = Math.min(candidate.sourceDuration, candidate.submissionDuration);
  const candidateAccountedBitsPerSecond =
    ((mux.transportBytes + 44 * mux.transportMessageCount) * 8) / duration;

  const rows = intervals.intervals,
    covered = intervalQualification.coveredIntervalIndexes;
  assert.ok(Array.isArray(rows) && rows.length <= 128 && Array.isArray(covered));
  assert.ok(
    covered.every(
      (i, n) => Number.isInteger(i) && i >= 0 && i < rows.length && (n === 0 || i > covered[n - 1]),
    ),
  );
  let offsetLower = -Infinity,
    offsetUpper = Infinity;
  for (const row of rows) {
    for (const at of [row.requestStartedAt, row.responseReceivedAt, row.evaluatedAt])
      assert.ok(time(at));
    assert.ok(
      time(row.serverAgeUpperBoundMs) &&
        row.requestStartedAt <= row.responseReceivedAt &&
        row.responseReceivedAt <= row.evaluatedAt,
    );
    const end = seconds(row.end.observedAtNanoseconds);
    offsetLower = Math.max(
      offsetLower,
      row.requestStartedAt - row.serverAgeUpperBoundMs / 1000 - end,
    );
    offsetUpper = Math.min(offsetUpper, row.responseReceivedAt - end);
  }
  assert.ok(
    Number.isFinite(offsetLower) && offsetLower <= offsetUpper,
    'Inconsistent receiver clock bounds',
  );
  // Choose chronology first, never search backwards for a rate that passes.
  const eligible = covered.filter(
    (i) =>
      rows[i].nativeProbeStage === 3 &&
      rows[i].evaluatedAt <= m.endedAt + 2 &&
      rows[i].evaluatedAt < stage.retirementRequestedAt,
  );
  const selected = eligible.slice(-2);
  assert.equal(selected.length, 2, 'Need two independently covered fresh intervals');
  const pair = selected.map((i) => rows[i]),
    t = pair[1].evaluatedAt;
  assert.ok(m.endedAt <= t && t - m.endedAt <= 2 && t < pair[1].nativeLeaseDeadline);
  assert.deepEqual(pair[0].end, pair[1].start, 'Receiver coverage is not contiguous');
  const identity = (r) => [r.publication, r.workerId, r.workerEpoch, r.workerAttempt];
  assert.deepEqual(identity(pair[0]), identity(pair[1]));
  const coverage = pair.map((r) => {
    assert.equal(r.nativeProbeId.toLowerCase(), stage.id.toLowerCase());
    assert.equal(r.nativePublishingGeneration, accepted.publishingGeneration);
    for (const p of [r.start, r.end]) {
      assert.equal(p.id.toLowerCase(), stage.id.toLowerCase());
      assert.equal(p.stage, 3);
      assert.equal(p.publishingGeneration, accepted.publishingGeneration);
      assert.equal(p.bitRate, stage.bitRate);
    }
    const start = seconds(r.start.observedAtNanoseconds),
      end = seconds(r.end.observedAtNanoseconds);
    const duration = end - start;
    assert.ok(
      duration >= 1 && duration <= 5 && Math.abs(seconds(r.durationNanoseconds) - duration) < 1e-9,
    );
    const rate = (counter(r.deliveredPayloadBytesLowerBound) * 8) / duration;
    assert.ok(rate > 0 && Math.abs(rate - r.payloadBitsPerSecondLowerBound) < 0.001);
    const outerAge = r.serverAgeUpperBoundMs / 1000 + r.evaluatedAt - r.requestStartedAt;
    const deliveryAge = end - seconds(r.end.lastDeliveredAtNanoseconds);
    assert.ok(outerAge >= 0 && deliveryAge >= 0 && outerAge + deliveryAge <= 1.5);
    return {
      startLower: start + offsetLower,
      startUpper: start + offsetUpper,
      endLower: end + offsetLower,
      endUpper: end + offsetUpper,
      payloadBitsPerSecondLowerBound: rate,
    };
  });
  assert.ok(
    coverage[0].startLower >= Math.max(firstAt, t - 5),
    'Coverage predates fresh candidate input',
  );
  assert.ok(
    coverage[0].endLower > firstAt && coverage[0].startUpper < lastAt,
    'No guaranteed candidate overlap',
  );
  assert.ok(
    coverage[1].endLower >= m.endedAt,
    'Latest receiver snapshot predates candidate completion',
  );
  assert.ok(coverage[1].endUpper <= t);
  const minimumDeliveredPayloadBitsPerSecond = Math.min(
    ...coverage.map((r) => r.payloadBitsPerSecondLowerBound),
  );
  const requiredPaddingPayloadBitsPerSecond = candidateAccountedBitsPerSecond * 1.25;
  return {
    convention: 'candidate-probe-load-ipv4-v1',
    candidateProfile: candidate.profile,
    probeId: stage.id,
    publishingGeneration: accepted.publishingGeneration,
    stage: 3,
    evaluatedAt: t,
    candidateAge: t - m.endedAt,
    selectedIntervalIndexes: selected,
    coverage,
    candidateAccountedBitsPerSecond,
    requiredPaddingPayloadBitsPerSecond,
    minimumDeliveredPayloadBitsPerSecond,
    sufficient: minimumDeliveredPayloadBitsPerSecond >= requiredPaddingPayloadBitsPerSecond,
    mediaHealthQualified: false,
    upgradeAuthorized: false,
  };
}
