import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyTransportStatistics } from '../transport-statistics-evidence.mjs';
function fixture() {
  return [0, 1].map((i) => ({
    event: 'publisher-observation',
    statisticsObservedAt: 10.5 + i,
    transportStatistics: {
      publishingGeneration: '1',
      sampledAt: 10 + i,
      elapsedMilliseconds: String(1000 + i * 1000),
      sentBytes: String(100000 + i * 10000),
      retransmittedBytes: '1000',
      droppedPackets: '0',
      rttMilliseconds: 2,
      estimatedBandwidthMbps: 100,
      senderBufferedBytes: '50',
      senderBufferMilliseconds: '1',
      availableSenderBytes: '1000',
    },
  }));
}
const finish = { transportStatisticsAfterStop: null };
test('qualifies native collections without asserting video capacity', () => {
  const result = qualifyTransportStatistics(fixture(), finish, '1');
  assert.equal(result.sentByteDelta, '10000');
  assert.equal(result.retransmittedByteDelta, '0');
  assert.equal(result.samples.length, 2);
  assert.equal(result.usableVideoCapacity, undefined);
});
for (const [name, mutate] of Object.entries({
  missing: (e) => {
    delete e[0].transportStatistics;
  },
  stale: (e) => {
    e[0].statisticsObservedAt += 3;
  },
  future: (e) => {
    e[0].statisticsObservedAt = 9;
  },
  generation: (e) => {
    e[0].transportStatistics.publishingGeneration = '2';
  },
  reset: (e) => {
    e[1].transportStatistics.sentBytes = '1';
  },
  contradiction: (e) => {
    e[1].transportStatistics.sampledAt = 10;
  },
  clock: (e) => {
    e[1].transportStatistics.elapsedMilliseconds = '999';
  },
  nonfinite: (e) => {
    e[1].transportStatistics.rttMilliseconds = Infinity;
  },
  imprecise: (e) => {
    e[1].transportStatistics.sentBytes = 110000;
  },
  retransmissions: (e) => {
    e[1].transportStatistics.retransmittedBytes = '20000';
  },
  negative: (e) => {
    e[1].transportStatistics.senderBufferMilliseconds = '-1';
  },
  unchanged: (e) => {
    e[1].transportStatistics = structuredClone(e[0].transportStatistics);
  },
}))
  test(`rejects ${name}`, () => {
    const e = fixture();
    mutate(e);
    assert.throws(() => qualifyTransportStatistics(e, finish, '1'));
  });
test('rejects post-stop statistics', () =>
  assert.throws(() =>
    qualifyTransportStatistics(fixture(), { transportStatisticsAfterStop: {} }, '1'),
  ));
test('duplicate cached readings do not count as new collections', () => {
  const e = fixture();
  e.splice(1, 0, structuredClone(e[0]));
  assert.equal(qualifyTransportStatistics(e, finish, '1').samples.length, 2);
});
