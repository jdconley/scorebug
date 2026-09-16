import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifyTransportStatistics } from '../transport-statistics-evidence.mjs';
function fixture() {
  return [0, 1].map((i) => ({
    event: 'publisher-observation',
    statisticsObservedAt: 10.5 + i,
    transportWindow:
      i === 0
        ? null
        : {
            publishingGeneration: '1',
            start: 10,
            end: 11,
            sampleCount: 2,
            sentBytes: '10000',
            retransmittedBytes: '0',
            droppedPackets: '0',
            meanBufferedBytes: 50,
            meanBufferMilliseconds: 1,
            meanRTTMilliseconds: 2,
            maximumBufferedBytes: '50',
            maximumBufferMilliseconds: '1',
            maximumRTTMilliseconds: 2,
          },
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

for (const [name, mutate] of Object.entries({
  missingWindow: (e) => {
    delete e[1].transportWindow;
  },
  wrongEndpoint: (e) => {
    e[1].transportWindow.start = 9;
  },
  impreciseDelta: (e) => {
    e[1].transportWindow.sentBytes = 10000;
  },
  wrongMean: (e) => {
    e[1].transportWindow.meanBufferedBytes = 25;
  },
  wrongMaximum: (e) => {
    e[1].transportWindow.maximumBufferedBytes = '49';
  },
  nonfiniteMean: (e) => {
    e[1].transportWindow.meanRTTMilliseconds = Infinity;
  },
  prematureWindow: (e) => {
    e[0].transportWindow = structuredClone(e[1].transportWindow);
  },
  windowAfterGap: (e) => {
    e[1].transportStatistics.sampledAt = 13;
    e[1].statisticsObservedAt = 13.5;
    e[1].transportWindow.end = 13;
  },
}))
  test(`rejects invalid pressure ${name}`, () => {
    const e = fixture();
    mutate(e);
    assert.throws(() => qualifyTransportStatistics(e, finish, '1'));
  });

test('nonuniform window oracle subtracts exact large counters and time-weights gauges', () => {
  const e = fixture();
  const base = (1n << 64n) - 10000n;
  e[0].transportStatistics.sentBytes = String(base);
  e[1].transportStatistics.sentBytes = String(base + 1000n);
  e[0].transportStatistics.senderBufferedBytes = '100';
  e[1].transportStatistics.senderBufferedBytes = '400';
  e[1].transportWindow.sentBytes = '1000';
  e[1].transportWindow.meanBufferedBytes = 100;
  e[1].transportWindow.maximumBufferedBytes = '400';
  const last = structuredClone(e[1]);
  last.statisticsObservedAt = 13.5;
  Object.assign(last.transportStatistics, {
    sampledAt: 13,
    elapsedMilliseconds: '4000',
    sentBytes: String(base + 4000n),
    senderBufferedBytes: '0',
  });
  Object.assign(last.transportWindow, {
    end: 13,
    sampleCount: 3,
    sentBytes: '4000',
    meanBufferedBytes: 300,
  });
  e.push(last);
  assert.equal(qualifyTransportStatistics(e, finish, '1').windows.at(-1).meanBufferedBytes, 300);
  last.transportWindow.meanBufferedBytes = 500 / 3;
  assert.throws(() => qualifyTransportStatistics(e, finish, '1'));
});

test('gap and subsecond coverage have no window', () => {
  for (const end of [10.5, 13]) {
    const e = fixture();
    e[1].transportStatistics.sampledAt = end;
    e[1].statisticsObservedAt = end + 0.1;
    e[1].transportWindow = null;
    assert.equal(qualifyTransportStatistics(e, finish, '1').windows.length, 0);
  }
});

test('completed duplicate and unavailable reads retain original window lease', () => {
  const e = fixture();
  const cached = structuredClone(e[1]);
  cached.statisticsObservedAt = 12;
  const missing = structuredClone(cached);
  missing.transportStatistics = null;
  missing.statisticsObservedAt = 13;
  const stale = structuredClone(missing);
  stale.statisticsObservedAt = 13.001;
  stale.transportWindow = null;
  e.push(cached, missing, stale);
  assert.equal(qualifyTransportStatistics(e, finish, '1').windows.length, 1);
  stale.transportWindow = structuredClone(missing.transportWindow);
  assert.throws(() => qualifyTransportStatistics(e, finish, '1'));
});

test('rolling five-second history moves to the oldest retained actual endpoint', () => {
  const [first, second] = fixture();
  const e = Array.from({ length: 7 }, (_, i) => {
    const item = structuredClone(i ? second : first);
    item.statisticsObservedAt = 10.5 + i;
    Object.assign(item.transportStatistics, {
      sampledAt: 10 + i,
      elapsedMilliseconds: String(1000 + i * 1000),
      sentBytes: String(100000 + i * 10000),
    });
    if (i)
      Object.assign(item.transportWindow, {
        start: Math.max(10, 5 + i),
        end: 10 + i,
        sampleCount: Math.min(i + 1, 6),
        sentBytes: String(Math.min(i, 5) * 10000),
      });
    return item;
  });
  assert.equal(qualifyTransportStatistics(e, finish, '1').windows.at(-1).start, 11);
  e.at(-1).transportWindow.start = 10;
  assert.throws(() => qualifyTransportStatistics(e, finish, '1'));
});
