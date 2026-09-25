import assert from 'node:assert/strict';

const time = (value) =>
  assert(
    typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12,
    'Invalid clock',
  );
const uuid = (value) => {
  assert(
    typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value),
    'Invalid nonce/attempt',
  );
  return value.toLowerCase();
};
const keys = (value, expected) => {
  assert(value && typeof value === 'object' && !Array.isArray(value));
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort(), 'Unexpected clock fields');
};
export function capacityClockScope(value) {
  keys(value, [
    'recordingID',
    'matchID',
    'broadcastGeneration',
    'publishingAttemptID',
    'appliedProfileRevision',
  ]);
  for (const key of ['recordingID', 'matchID'])
    assert(typeof value[key] === 'string' && value[key].length > 0 && value[key].length <= 512);
  assert(Number.isSafeInteger(value.broadcastGeneration) && value.broadcastGeneration > 0);
  assert.equal(value.appliedProfileRevision, '1', 'Original capture scope required');
  return { ...value, publishingAttemptID: uuid(value.publishingAttemptID) };
}

/** Timing correspondence only. The caller independently qualifies the exact raw
 * proxy accounting and native media/policy. Samples bracket each fault using
 * causally ordered messages; no shared epoch, equal clock rate or offset is assumed. */
export function qualifyCapacityClockBrackets({ scope, schedule, nativeAudit, exchanges }) {
  const expectedScope = capacityClockScope(scope);
  keys(nativeAudit, [
    'formatVersion',
    'scope',
    'maximumSamples',
    'closed',
    'invalid',
    'overflow',
    'samples',
  ]);
  assert.equal(nativeAudit.formatVersion, 1);
  assert.deepEqual(capacityClockScope(nativeAudit.scope), expectedScope);
  assert.equal(nativeAudit.maximumSamples, 4);
  assert.equal(nativeAudit.closed, true);
  assert.equal(nativeAudit.invalid, false);
  assert.equal(nativeAudit.overflow, false);
  assert(Array.isArray(nativeAudit.samples) && nativeAudit.samples.length === 4);
  assert(Array.isArray(exchanges) && exchanges.length === 4);
  const requested = [
    { atMilliseconds: 0, rateBitsPerSecond: null },
    { atMilliseconds: 60000, rateBitsPerSecond: 550000 },
    { atMilliseconds: 120000, rateBitsPerSecond: null },
  ];
  assert.deepEqual(schedule.requested, requested);
  time(schedule.startedAt);
  time(schedule.stoppedAt);
  assert(schedule.stoppedAt - schedule.startedAt >= 180000);
  assert(Array.isArray(schedule.phases) && schedule.phases.length === 3);
  for (const [i, phase] of schedule.phases.entries()) {
    assert.equal(phase.atMilliseconds, requested[i].atMilliseconds);
    assert.equal(phase.rateBitsPerSecond, requested[i].rateBitsPerSecond);
    time(phase.appliedAt);
    const due = schedule.startedAt + phase.atMilliseconds;
    assert(
      phase.appliedAt >= due && phase.appliedAt <= due + 2000,
      'Fault outside applied schedule',
    );
    assert(phase.appliedAt < schedule.stoppedAt);
  }
  const nonces = new Set();
  for (const [i, exchange] of exchanges.entries()) {
    keys(exchange, ['requestAt', 'responseAt', 'request', 'response']);
    const { request, response } = exchange,
      sample = nativeAudit.samples[i];
    keys(request, ['formatVersion', 'scope', 'sequence', 'nonce']);
    keys(response, ['formatVersion', 'scope', 'sample']);
    keys(sample, ['sequence', 'nonce', 'nativeAt']);
    assert.equal(request.formatVersion, 1);
    assert.equal(response.formatVersion, 1);
    for (const value of [request.scope, response.scope])
      assert.deepEqual(capacityClockScope(value), expectedScope);
    assert.equal(request.sequence, i + 1);
    assert.equal(sample.sequence, i + 1);
    const nonce = uuid(request.nonce);
    assert(!nonces.has(nonce), 'Reused clock challenge');
    nonces.add(nonce);
    assert.equal(uuid(sample.nonce), nonce);
    assert.deepEqual(response.sample, sample, 'Native clock sample changed after reply');
    time(sample.nativeAt);
    time(exchange.requestAt);
    time(exchange.responseAt);
    assert(
      exchange.responseAt >= exchange.requestAt && exchange.responseAt - exchange.requestAt <= 250,
      'Clock exchange exceeds 250ms',
    );
    assert(exchange.requestAt >= schedule.startedAt && exchange.responseAt <= schedule.stoppedAt);
    if (i > 0) {
      assert(
        exchange.requestAt > exchanges[i - 1].responseAt,
        'Clock exchanges overlap or regress',
      );
      assert(sample.nativeAt > nativeAudit.samples[i - 1].nativeAt, 'Native clock regressed');
    }
  }
  const boundaries = [1, 2].map((phaseIndex, i) => {
    const before = exchanges[i * 2],
      after = exchanges[i * 2 + 1],
      phase = schedule.phases[phaseIndex];
    assert(before.responseAt < phase.appliedAt, 'Before reply did not precede applied fault');
    assert(after.requestAt >= phase.appliedAt, 'After challenge preceded applied fault');
    const nativeLower = nativeAudit.samples[i * 2].nativeAt,
      nativeUpper = nativeAudit.samples[i * 2 + 1].nativeAt;
    assert(after.responseAt - before.requestAt <= 1500, 'Host fault bracket exceeds 1.5s');
    assert(nativeUpper - nativeLower <= 1.5, 'Native fault bracket exceeds 1.5s');
    return {
      phaseIndex,
      appliedAt: phase.appliedAt,
      nativeLower,
      nativeUpper,
      beforeSequence: i * 2 + 1,
      afterSequence: i * 2 + 2,
    };
  });
  return {
    scope: expectedScope,
    boundaries,
    clockBracketsQualified: true,
    nativeAdaptationQualified: false,
  };
}
