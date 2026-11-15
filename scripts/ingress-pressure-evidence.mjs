import assert from 'node:assert/strict';
const clock = (value) =>
  assert.ok(typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12);
const fraction = (value) =>
  assert.ok(typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1);
const rational = (value) => {
  assert.ok(value && /^[0-9]+$/.test(value.value));
  assert.ok(
    Number.isInteger(value.timescale) && value.timescale > 0 && value.timescale <= 2147483647,
  );
  assert.equal(value.epoch, '0');
  assert.ok(value.flags === 1 || value.flags === 3);
  return [BigInt(value.value), BigInt(value.timescale)];
};
const samePTS = (a, b) => {
  const [an, ad] = rational(a),
    [bn, bd] = rational(b);
  return an * bd === bn * ad;
};
const near = (a, b) => {
  assert.ok(Number.isFinite(a));
  assert.ok(Math.abs(a - b) <= 1e-8, `${a} differs from integrated ${b}`);
};

/** Independent finite-fixture integration of raw queue transitions. */
export function qualifyIngressPressure({ pressure, source }) {
  assert.ok(pressure && source);
  assert.deepEqual(pressure.scope, source.scope);
  assert.ok(typeof source.scope.recordingID === 'string' && source.scope.recordingID.length > 0);
  assert.ok(typeof source.scope.matchID === 'string' && source.scope.matchID.length > 0);
  assert.ok(
    Number.isSafeInteger(source.scope.broadcastGeneration) && source.scope.broadcastGeneration > 0,
  );
  assert.match(source.scope.publishingAttemptID, /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
  assert.match(source.scope.appliedProfileRevision, /^[1-9][0-9]*$/);
  assert.equal(pressure.isClosed, true);
  assert.equal(pressure.isQuarantined, false);
  assert.equal(pressure.omittedStates, '0', 'Finite fixture must retain all pressure transitions');
  clock(pressure.coveredThrough);
  const states = pressure.states;
  assert.ok(Array.isArray(states) && states.length > 0 && states.length <= 4096);
  for (let i = 0; i < states.length; i++) {
    const state = states[i];
    clock(state.at);
    fraction(state.itemFraction);
    fraction(state.byteFraction);
    assert.ok(['startup', 'admitting', 'draining', 'closed'].includes(state.phase));
    assert.ok(state.at <= pressure.coveredThrough);
    if (i) assert.ok(state.at > states[i - 1].at);
  }
  assert.equal(source.capture.length, 420);
  assert.equal(source.encoded.length, 420);
  for (let i = 0; i < source.capture.length; i++) {
    const frame = source.capture[i];
    clock(frame.observedAt);
    assert.ok(samePTS(frame.sourcePTS, source.encoded[i].sourcePTS));
    if (i) assert.ok(frame.observedAt > source.capture[i - 1].observedAt);
  }
  assert.deepEqual(source.intervalProbes.map((p) => p.name).sort(), [
    'after',
    'before',
    'crossing',
  ]);
  let verified = 0,
    unknown = 0;
  for (const probe of source.intervalProbes) {
    const previous = source.capture.find((f) => samePTS(f.sourcePTS, probe.sourceStartExclusive));
    const last = source.capture.find((f) => samePTS(f.sourcePTS, probe.sourceEndInclusive));
    assert.ok(previous && last);
    const start = previous.observedAt,
      end = last.observedAt;
    assert.equal(probe.captureBoundaryStartTime, start);
    assert.equal(probe.captureBoundaryEndTime, end);
    assert.ok(start < end);
    let available = start >= states[0].at && end <= pressure.coveredThrough;
    let item = 0,
      byte = 0,
      max = 0;
    for (let i = 0; i < states.length && available; i++) {
      const state = states[i];
      const duration =
        Math.min(end, states[i + 1]?.at ?? pressure.coveredThrough) - Math.max(start, state.at);
      if (duration <= 0) continue;
      if (state.phase !== 'admitting') {
        available = false;
        break;
      }
      item += duration * state.itemFraction;
      byte += duration * state.byteFraction;
      max += duration * Math.max(state.itemFraction, state.byteFraction);
    }
    if (!available) {
      assert.equal(probe.ingressPressure, null);
      unknown++;
      continue;
    }
    const actual = probe.ingressPressure;
    assert.ok(actual);
    assert.equal(actual.start, start);
    assert.equal(actual.end, end);
    near(actual.itemSeconds, item);
    near(actual.byteSeconds, byte);
    near(actual.maxPressureSeconds, max);
    near(actual.meanMaxPressure, max / (end - start));
    verified++;
  }
  assert.ok(
    source.intervalProbes.find((p) => p.name === 'after').ingressPressure,
    'Post-write fixture interval must have complete admitted queue coverage',
  );
  return {
    retainedStates: states.length,
    verifiedIntervals: verified,
    unknownIntervals: unknown,
    scope: 'Historical queue pressure over exact capture boundaries; not current health',
  };
}
