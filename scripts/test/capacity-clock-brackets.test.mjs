import assert from 'node:assert/strict';
import test from 'node:test';
const implementation = await import('../capacity-clock-brackets.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const scope = {
  recordingID: 'recording',
  matchID: 'match',
  broadcastGeneration: 1,
  publishingAttemptID: '11111111-1111-4111-8111-111111111111',
  appliedProfileRevision: '1',
};
const fixture = () => {
  const nativeTimes = [900059.7, 900060.15, 900119.7, 900120.15];
  const hostTimes = [69900, 70300, 129900, 130300];
  const samples = nativeTimes.map((nativeAt, i) => ({
    sequence: i + 1,
    nonce: `00000000-0000-4000-8000-00000000000${i + 1}`,
    nativeAt,
  }));
  return {
    scope: structuredClone(scope),
    schedule: {
      requested: [
        { atMilliseconds: 0, rateBitsPerSecond: null },
        { atMilliseconds: 60000, rateBitsPerSecond: 550000 },
        { atMilliseconds: 120000, rateBitsPerSecond: null },
      ],
      startedAt: 10000,
      stoppedAt: 190500,
      phases: [
        { atMilliseconds: 0, rateBitsPerSecond: null, appliedAt: 10000 },
        { atMilliseconds: 60000, rateBitsPerSecond: 550000, appliedAt: 70100 },
        { atMilliseconds: 120000, rateBitsPerSecond: null, appliedAt: 130100 },
      ],
    },
    nativeAudit: {
      formatVersion: 1,
      scope: structuredClone(scope),
      maximumSamples: 4,
      closed: true,
      invalid: false,
      overflow: false,
      samples: structuredClone(samples),
    },
    exchanges: samples.map((sample, i) => ({
      requestAt: hostTimes[i],
      responseAt: hostTimes[i] + 75,
      request: {
        formatVersion: 1,
        scope: structuredClone(scope),
        sequence: sample.sequence,
        nonce: sample.nonce,
      },
      response: {
        formatVersion: 1,
        scope: structuredClone(scope),
        sample: structuredClone(sample),
      },
    })),
  };
};
const qualify = (f) => {
  assert.equal(typeof implementation.qualifyCapacityClockBrackets, 'function');
  return implementation.qualifyCapacityClockBrackets(f);
};
test('native samples bracket applied host faults without a shared clock epoch or offset', () => {
  const f = fixture(),
    before = structuredClone(f),
    result = qualify(f);
  assert.equal(result.nativeAdaptationQualified, false);
  assert.equal(result.clockBracketsQualified, true);
  assert.deepEqual(
    result.boundaries.map((x) => [x.nativeLower, x.nativeUpper]),
    [
      [900059.7, 900060.15],
      [900119.7, 900120.15],
    ],
  );
  assert.deepEqual(f, before);
});
const mutations = {
  'unclosed audit': (f) => (f.nativeAudit.closed = false),
  'invalid audit': (f) => (f.nativeAudit.invalid = true),
  'overflow audit': (f) => (f.nativeAudit.overflow = true),
  'wrong budget': (f) => (f.nativeAudit.maximumSamples = 8),
  'missing exchange': (f) => f.exchanges.pop(),
  'extra exchange': (f) => f.exchanges.push(structuredClone(f.exchanges[0])),
  'missing native sample': (f) => f.nativeAudit.samples.pop(),
  'foreign audit': (f) => (f.nativeAudit.scope.recordingID = 'other'),
  'foreign request': (f) => (f.exchanges[0].request.scope.matchID = 'other'),
  'foreign response': (f) =>
    (f.exchanges[0].response.scope.publishingAttemptID = f.exchanges[0].request.nonce),
  'request nonce replay': (f) => (f.exchanges[1].request.nonce = f.exchanges[0].request.nonce),
  'wrong response nonce': (f) =>
    (f.exchanges[0].response.sample.nonce = f.exchanges[1].request.nonce),
  'rewritten native time': (f) => f.exchanges[0].response.sample.nativeAt++,
  'wrong native sequence': (f) => (f.nativeAudit.samples[0].sequence = 2),
  'future format': (f) => (f.exchanges[0].response.formatVersion = 2),
  'slow exchange': (f) => (f.exchanges[0].responseAt = f.exchanges[0].requestAt + 250.01),
  'backward host exchange': (f) => (f.exchanges[0].responseAt = f.exchanges[0].requestAt - 1),
  'before response at fault': (f) => (f.exchanges[0].responseAt = f.schedule.phases[1].appliedAt),
  'after request before fault': (f) =>
    (f.exchanges[1].requestAt = f.schedule.phases[1].appliedAt - 1),
  'wide host bracket': (f) => {
    f.exchanges[0].requestAt -= 1500;
    f.exchanges[0].responseAt -= 1500;
  },
  'wide native bracket': (f) => {
    f.nativeAudit.samples[0].nativeAt -= 2;
    f.exchanges[0].response.sample.nativeAt -= 2;
  },
  'native time regression': (f) => {
    f.nativeAudit.samples[1].nativeAt = f.nativeAudit.samples[0].nativeAt;
    f.exchanges[1].response.sample.nativeAt = f.nativeAudit.samples[0].nativeAt;
  },
  'missing applied phase': (f) => f.schedule.phases.pop(),
  'wrong rate': (f) => (f.schedule.phases[1].rateBitsPerSecond = 1),
  'wrong schedule': (f) => (f.schedule.requested[1].atMilliseconds = 59000),
  'phase before due': (f) => (f.schedule.phases[1].appliedAt = 69999),
  'phase too late': (f) => (f.schedule.phases[1].appliedAt = 72001),
};
for (const [name, mutate] of Object.entries(mutations))
  test(`clock bracket rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualify(f));
  });
