import assert from 'node:assert/strict';

const time = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e12;
const close = (a, b, tolerance = 1e-6) => {
  assert.ok(
    Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= tolerance,
    'Witness arithmetic mismatch',
  );
};
const uuid = (s) => {
  assert.ok(typeof s === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(s));
  return s.toLowerCase();
};
const uint = (s, maximum = 18446744073709551615n) => {
  assert.ok(typeof s === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(s));
  const n = BigInt(s);
  assert.ok(n <= maximum);
  return n;
};
const ns = (s) => uint(s, 86400000000000n);
const seconds = (s) => Number(ns(s)) / 1e9;
const counter = (s) => Number(uint(s, 16777216n));
const bounds = (b) => {
  assert.ok(Array.isArray(b) && b.length === 2 && b.every(time) && b[0] <= b[1]);
  return b;
};
const sameUUID = (a, b) => assert.equal(uuid(a), uuid(b));
function sameReceipt(a, b) {
  for (const key of ['configurationID', 'encoderSessionID']) sameUUID(a[key], b[key]);
  for (const key of ['generation', 'bitRate', 'acceptedAt', 'lastSubmittedPTS'])
    assert.deepEqual(a[key], b[key]);
}
function sameProbe(a, b) {
  sameUUID(a.id, b.id);
  for (const key of [
    'publishingGeneration',
    'stage',
    'bitRate',
    'startedAt',
    'leaseDeadline',
    'acceptedPayloadBytes',
    'lastAcceptedAt',
    'reason',
  ])
    assert.equal(a[key], b[key]);
}

/** Replay the frozen laboratory adapter inputs, never select a retrospective pair.
 * candidate and intervalQualification must come from the independent native gates;
 * nativeProof must also have passed qualifyNativeBandwidthProbe. This proves only
 * the admission-time witness/load relation, not media health, application or upgrade.
 */
export function qualifyMeasuredCandidateWitness({
  witness: w,
  candidateProof,
  candidate,
  bootstrap,
  intervals,
  intervalQualification,
  nativeProof,
}) {
  assert.equal(w.formatVersion, 1);
  assert.equal(w.convention, 'measured-candidate-ipv4-v1');
  const m = w.measurement,
    raw = candidateProof.measurement,
    a = w.applied;
  const now = w.clock.after,
    before = w.clock.before;
  assert.ok(time(before) && time(now) && before <= now && now - before <= 0.1);
  assert.equal(w.evaluatedAt, now);
  const projectionWidth = now - before;
  for (const at of [
    m.startedAt,
    m.endedAt,
    m.firstInputAt,
    m.lastInputAt,
    w.boundAt,
    w.completedAt,
    w.validUntil,
    a.acknowledgedAt,
    a.receipt.acceptedAt,
  ])
    assert.ok(time(at));
  assert.equal(candidateProof.formatVersion, 3);
  assert.equal(candidate.liveProfile, '240p30');
  assert.equal(candidateProof.liveProfile, '240p30');
  assert.equal(candidate.frames, 121);
  assert.equal(raw.encoding.frames.length, 121);
  sameUUID(m.id, raw.id);
  sameUUID(m.id, candidate.id);
  for (const scope of [
    raw.scope,
    candidate.scope,
    candidateProof.scope,
    intervals.scope,
    nativeProof.scope,
  ])
    assert.deepEqual(m.scope, scope);
  assert.equal(m.profile, raw.profile);
  assert.equal(m.profile, candidate.profile);
  assert.ok(['360p30', '540p30', '1080p30'].includes(m.profile));
  assert.equal(m.startedAt, raw.startedAt);
  assert.equal(m.endedAt, raw.endedAt);
  assert.equal(m.firstInputAt, raw.encoding.frames[0].admittedAt);
  assert.equal(m.lastInputAt, raw.encoding.frames.at(-1).admittedAt);
  assert.equal(m.sourceDuration, candidate.sourceDuration);
  assert.equal(m.submissionDuration, candidate.submissionDuration);
  assert.equal(
    m.submissionDuration,
    raw.encoding.frames.at(-1).submittedAt - raw.encoding.frames[0].submittedAt,
  );
  assert.equal(m.publishingGeneration, raw.transport.publishingGeneration);
  assert.equal(m.publishingGeneration, nativeProof.publishingGeneration);
  assert.ok(uint(m.publishingGeneration) > 0n);
  for (const key of ['transportBytes', 'transportMessageCount']) {
    assert.equal(m[key], raw.transport.mux[key]);
    assert.equal(m[key], candidate.transport[key]);
    assert.ok(Number.isSafeInteger(m[key]) && m[key] > 0);
  }
  assert.ok(
    m.transportBytes <= 40 * 1024 * 1024 &&
      m.transportBytes % 188 === 0 &&
      m.transportMessageCount <= 250000,
  );
  assert.ok(
    m.transportMessageCount * 188 <= m.transportBytes &&
      m.transportBytes <= m.transportMessageCount * 1316,
  );
  assert.ok(
    m.sourceDuration >= 4 &&
      m.sourceDuration <= 4.25 &&
      time(m.submissionDuration) &&
      m.submissionDuration > 0 &&
      m.submissionDuration < 5,
  );
  assert.ok(
    m.startedAt <= m.firstInputAt && m.firstInputAt < m.lastInputAt && m.lastInputAt <= m.endedAt,
  );
  assert.ok(
    m.endedAt - m.startedAt <= 7 &&
      m.endedAt <= w.completedAt &&
      w.completedAt <= now &&
      now - m.endedAt <= 2,
  );

  assert.equal(bootstrap.kind, 'bootstrap');
  assert.equal(bootstrap.revision, '0');
  assert.equal(bootstrap.profileID, '240p30');
  assert.equal(a.revision, '0');
  assert.equal(a.profileID, '240p30');
  assert.equal(a.videoBitrate, 350000);
  assert.equal(a.receipt.bitRate, a.videoBitrate);
  assert.equal(a.acknowledgedAt, bootstrap.acknowledgedAt);
  sameReceipt(a.receipt, bootstrap.receipt);
  assert.equal(a.receipt.generation, m.publishingGeneration);
  sameUUID(a.attemptID, m.scope.publishingAttemptID);
  assert.ok(a.receipt.acceptedAt <= a.acknowledgedAt && a.acknowledgedAt <= m.startedAt);

  const binding = candidateProof.probeBinding;
  assert.equal(w.boundAt, binding.boundAt);
  assert.equal(w.completedAt, binding.completedAt);
  sameProbe(w.binding, binding.initial);
  assert.equal(binding.initial.observedAt, w.boundAt);
  const probe = w.probe;
  sameUUID(probe.id, w.binding.id);
  for (const key of ['publishingGeneration', 'stage', 'bitRate', 'startedAt'])
    assert.equal(probe[key], w.binding[key]);
  assert.equal(probe.publishingGeneration, m.publishingGeneration);
  assert.equal(probe.stage, 3);
  assert.equal(probe.bitRate, 12000000);
  assert.ok(probe.startedAt + 0.5 <= w.boundAt && w.boundAt <= m.startedAt);
  assert.ok(
    Array.isArray(nativeProof.events) &&
      nativeProof.events.length > 0 &&
      nativeProof.events.length <= 2000,
  );
  const events = nativeProof.events.filter((e) => e.sample.stage === 3);
  assert.ok(events.length > 0);
  for (const e of events) {
    sameUUID(e.sample.id, probe.id);
    assert.equal(e.sample.publishingGeneration, m.publishingGeneration);
    assert.equal(e.sample.startedAt, probe.startedAt);
    assert.equal(e.sample.bitRate, 12000000);
    assert.ok(time(e.observedAt));
    if (e.observedAt <= now) assert.equal(e.sample.reason, null, 'Native probe already withdrawn');
  }
  for (const [p, at] of [
    [w.binding, w.boundAt],
    [probe, now],
  ]) {
    for (const key of ['startedAt', 'leaseDeadline', 'lastAcceptedAt']) assert.ok(time(p[key]));
    assert.equal(p.reason, null);
    assert.ok(
      p.startedAt <= p.lastAcceptedAt &&
        p.lastAcceptedAt <= at &&
        at < p.leaseDeadline &&
        p.leaseDeadline - at <= 0.300001,
    );
    const accepted = counter(p.acceptedPayloadBytes);
    assert.ok(accepted > 0 && accepted % 1316 === 0);
    const renewal = events.find((e) => e.sample.leaseDeadline === p.leaseDeadline);
    assert.ok(renewal, 'Unobserved admission probe lease');
    // Renewal and its snapshot are atomic on the native actor. A snapshot
    // carrying this lease cannot contain counters from before that renewal.
    assert.ok(
      accepted >= counter(renewal.sample.acceptedPayloadBytes) &&
        p.lastAcceptedAt >= renewal.sample.lastAcceptedAt,
      'Probe counters precede native renewal floor',
    );
    for (const e of events) {
      const n = counter(e.sample.acceptedPayloadBytes),
        last = e.sample.lastAcceptedAt;
      if (last === p.lastAcceptedAt) assert.equal(n, accepted);
      else if (last === null || last < p.lastAcceptedAt)
        assert.ok(n <= accepted, 'Probe counter regression');
      else assert.ok(n >= accepted, 'Probe counter exceeds native history');
    }
  }
  assert.ok(
    counter(probe.acceptedPayloadBytes) >= counter(w.binding.acceptedPayloadBytes) &&
      probe.leaseDeadline >= w.binding.leaseDeadline &&
      probe.lastAcceptedAt >= w.binding.lastAcceptedAt,
  );

  const rows = intervals.intervals,
    covered = intervalQualification.coveredIntervalIndexes;
  assert.ok(Array.isArray(rows) && rows.length <= 128 && Array.isArray(covered));
  assert.ok(
    covered.every(
      (i, n) => Number.isInteger(i) && i >= 0 && i < rows.length && (n === 0 || i > covered[n - 1]),
    ),
  );
  assert.ok(Array.isArray(w.intervals) && w.intervals.length === 2);
  const selectedIntervalIndexes = [];
  for (const i of w.intervals) {
    const matches = rows
      .map((r, index) => ({ r, index }))
      .filter(
        ({ r }) =>
          r.start.observedAtNanoseconds === i.start.observedAtNanoseconds &&
          r.end.observedAtNanoseconds === i.end.snapshot.observedAtNanoseconds,
      );
    assert.equal(matches.length, 1, 'Witness must name an exact unique interval');
    const { r, index } = matches[0];
    assert.ok(covered.includes(index), 'Selected interval lacks independent coverage');
    selectedIntervalIndexes.push(index);
    assert.deepEqual(i.start, r.start);
    assert.deepEqual(i.end.snapshot, r.end);
    for (const key of ['publication', 'workerEpoch', 'workerAttempt', 'serverAgeUpperBoundMs'])
      assert.deepEqual(i.end[key], r[key]);
    assert.equal(i.end.expected.workerId, r.workerId);
    assert.deepEqual(i.end.expected, {
      gameId: m.scope.matchID,
      generation: m.scope.broadcastGeneration,
      workerId: r.workerId,
      publishingAttemptId: uuid(a.attemptID),
      publishingGeneration: m.publishingGeneration,
      probeId: uuid(probe.id),
      stage: 3,
      bitRate: 12000000,
    });
    assert.equal(r.nativeProbeStage, 3);
    sameUUID(r.nativeProbeId, probe.id);
    assert.equal(r.nativePublishingGeneration, m.publishingGeneration);
    assert.equal(r.nativeStartedAt, probe.startedAt);
    assert.ok(time(r.evaluatedAt) && r.evaluatedAt <= now);
    const e = i.end,
      request = bounds(e.requestStartedAtUptimeBounds),
      received = bounds(e.receivedAtUptimeBounds);
    close(request[1] - request[0], projectionWidth);
    close(received[1] - received[0], projectionWidth);
    assert.ok(request[0] <= received[0] && received[1] <= now);
    assert.ok(
      r.requestStartedAt <= request[0] + 1e-6 && received[1] <= r.responseReceivedAt + 1e-6,
    );
    assert.ok(request[1] <= r.responseReceivedAt && r.requestStartedAt <= received[0]);
    close(e.requestDurationSeconds, r.requestDurationMs / 1000, 1e-9);
    close(received[0] - request[0], e.requestDurationSeconds);
    assert.ok(Number.isSafeInteger(e.serverAgeUpperBoundMs) && e.serverAgeUpperBoundMs >= 0);
    const age = e.serverAgeUpperBoundMs / 1000 + before - request[0];
    close(e.snapshotAgeUpperBoundSeconds, age);
    const deliveryAge =
      Number(ns(e.snapshot.observedAtNanoseconds) - ns(e.snapshot.lastDeliveredAtNanoseconds)) /
      1e9;
    assert.ok(age >= 0 && deliveryAge >= 0);
    close(e.lastDeliveryAgeUpperBoundSeconds, e.snapshotAgeUpperBoundSeconds + deliveryAge, 1e-9);
    const offset = bounds(i.receiverClockOffsetUptimeBounds);
    for (const [p, projected] of [
      [i.start, i.startUptimeBounds],
      [e.snapshot, i.endUptimeBounds],
    ]) {
      bounds(projected);
      close(projected[0], offset[0] + seconds(p.observedAtNanoseconds));
      close(projected[1], offset[1] + seconds(p.observedAtNanoseconds));
      sameUUID(p.id, probe.id);
      assert.equal(p.stage, 3);
      assert.equal(p.bitRate, 12000000);
      assert.equal(p.publishingGeneration, m.publishingGeneration);
    }
    const elapsed = ns(e.snapshot.observedAtNanoseconds) - ns(i.start.observedAtNanoseconds);
    const messages = uint(e.snapshot.deliveredMessages) - uint(i.start.deliveredMessages);
    assert.ok(
      Number.isInteger(i.start.pendingPackets) &&
        i.start.pendingPackets >= 0 &&
        i.start.pendingPackets <= 6,
    );
    const bytes = messages * 1316n - BigInt(i.start.pendingPackets) * 188n;
    assert.ok(elapsed >= 1000000000n && elapsed <= 5000000000n && bytes > 0n);
    assert.equal(ns(i.durationNanoseconds), elapsed);
    assert.equal(uint(i.deliveredMessages), messages);
    assert.equal(uint(i.deliveredPayloadBytesLowerBound), bytes);
    close(i.payloadBitsPerSecondLowerBound, (Number(bytes) * 8e9) / Number(elapsed), 0.001);
    for (const key of [
      'durationNanoseconds',
      'deliveredMessages',
      'deliveredPayloadBytesLowerBound',
      'payloadBitsPerSecondLowerBound',
    ])
      assert.equal(i[key], r[key]);
    assert.ok(counter(e.snapshot.deliveredPayloadBytes) <= counter(probe.acceptedPayloadBytes));
    // No later rows participate in clock projection. Earlier independent rows
    // can disprove the captured offset but cannot silently replace it.
    for (const prior of rows.slice(0, index + 1)) {
      assert.ok(prior.evaluatedAt <= now);
      const t = seconds(prior.end.observedAtNanoseconds);
      assert.ok(
        offset[0] >= prior.requestStartedAt - prior.serverAgeUpperBoundMs / 1000 - t - 1e-6,
      );
      assert.ok(offset[1] <= prior.responseReceivedAt - t + 1e-6);
    }
  }
  assert.ok(
    selectedIntervalIndexes[1] === selectedIntervalIndexes[0] + 1,
    'Selected intervals are not consecutive',
  );
  assert.ok(
    rows.slice(selectedIntervalIndexes[1] + 1).every((r) => r.evaluatedAt > now),
    'Witness did not use latest receiver pair',
  );
  const [older, newer] = w.intervals;
  assert.deepEqual(older.end.snapshot, newer.start);
  for (const key of ['expected', 'publication', 'workerEpoch', 'workerAttempt'])
    assert.deepEqual(older.end[key], newer.end[key]);
  assert.ok(newer.end.requestStartedAtUptimeBounds[0] >= older.end.receivedAtUptimeBounds[0]);
  const offset = bounds(w.clock.receiverClockOffsetUptimeBounds);
  assert.deepEqual(offset, newer.receiverClockOffsetUptimeBounds);
  const endSeconds = seconds(newer.end.snapshot.observedAtNanoseconds);
  // Intervening polls may tighten the offset without exporting an interval.
  // Require containment here and independently conservative chronology below.
  assert.ok(
    offset[0] >=
      Math.max(
        older.receiverClockOffsetUptimeBounds[0],
        newer.end.requestStartedAtUptimeBounds[0] -
          newer.end.serverAgeUpperBoundMs / 1000 -
          endSeconds,
      ) -
        1e-6,
  );
  assert.ok(
    offset[1] <=
      Math.min(
        older.receiverClockOffsetUptimeBounds[1],
        newer.end.receivedAtUptimeBounds[1] - endSeconds,
      ) +
        1e-6,
  );
  const firstStart = seconds(older.start.observedAtNanoseconds),
    firstEnd = seconds(older.end.snapshot.observedAtNanoseconds);
  assert.ok(
    firstStart + offset[0] >= Math.max(m.firstInputAt, now - 5),
    'Coverage predates fresh candidate input',
  );
  assert.ok(
    firstEnd + offset[0] > m.firstInputAt && firstStart + offset[1] < m.lastInputAt,
    'No strict candidate overlap',
  );
  assert.ok(
    endSeconds + offset[0] > m.endedAt && endSeconds + offset[1] <= now,
    'Receiver completion chronology',
  );
  // Interval exports omit polls which produced no interval. They can therefore
  // prove only an outer envelope for the older captured offset. Require the
  // chronology to hold for that independently replayed envelope as well, so an
  // unsupported narrower witness (including later observations) cannot rescue it.
  let independentLower = -Infinity,
    independentUpper = Infinity;
  for (const r of rows.slice(0, selectedIntervalIndexes[1] + 1)) {
    const t = seconds(r.end.observedAtNanoseconds);
    independentLower = Math.max(
      independentLower,
      r.requestStartedAt - r.serverAgeUpperBoundMs / 1000 - t,
    );
    independentUpper = Math.min(independentUpper, r.responseReceivedAt - t);
  }
  assert.ok(Number.isFinite(independentLower) && independentLower <= independentUpper);
  assert.ok(
    firstStart + independentLower >= Math.max(m.firstInputAt, now - 5),
    'Independent clock cannot prove candidate start',
  );
  assert.ok(
    firstEnd + independentLower > m.firstInputAt && firstStart + independentUpper < m.lastInputAt,
    'Independent clock cannot prove candidate overlap',
  );
  assert.ok(
    endSeconds + independentLower > m.endedAt && endSeconds + independentUpper <= now,
    'Independent clock cannot prove candidate completion',
  );
  const age = newer.end.snapshotAgeUpperBoundSeconds,
    deliveryAge = newer.end.lastDeliveryAgeUpperBoundSeconds;
  assert.ok(time(age) && time(deliveryAge) && age <= 1.5 && deliveryAge <= 1.5);
  // Include the complete projection bracket in the independent freshness check.
  assert.ok(age + projectionWidth <= 1.5 && deliveryAge + projectionWidth <= 1.5);
  const deadline = Math.min(
    m.endedAt + 2,
    probe.leaseDeadline,
    before + 1.5 - age,
    before + 1.5 - deliveryAge,
  );
  assert.ok(deadline > now);
  close(w.validUntil, deadline);
  const cost =
    ((m.transportBytes + 44 * m.transportMessageCount) * 8) /
    Math.min(m.sourceDuration, m.submissionDuration);
  const padding = Math.min(...w.intervals.map((i) => i.payloadBitsPerSecondLowerBound));
  assert.ok(Number.isFinite(cost) && cost > 0 && Number.isFinite(padding) && padding > 0);
  close(w.candidateTransportBitsPerSecond, cost, 0.001);
  close(w.deliveredPaddingBitsPerSecond, padding, 0.001);
  return {
    convention: w.convention,
    witnessQualified: true,
    headroomQualified: padding >= cost * 1.25,
    candidateTransportBitsPerSecond: cost,
    deliveredPaddingBitsPerSecond: padding,
    requiredPaddingBitsPerSecond: cost * 1.25,
    selectedIntervalIndexes,
    evaluatedAt: now,
    validUntil: deadline,
    mediaHealthQualified: false,
    upgradeAuthorized: false,
  };
}
