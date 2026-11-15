import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyTransportIntervals } from '../transport-interval-evidence.mjs';
function fixture() {
  const base = (1n << 64n) - 10000n;
  const sample = (time, i, gauge) => ({
    publishingGeneration: '7',
    sampledAt: time,
    sentBytes: String(base + BigInt(i * 1000)),
    retransmittedBytes: String(base - 1000n + BigInt(i * 100)),
    droppedPackets: String(i),
    senderBufferedBytes: String(gauge),
    senderBufferMilliseconds: String(gauge),
    rttMilliseconds: gauge,
  });
  const samples = [sample(10, 0, 100), sample(11, 1, 400), sample(13, 2, 900)];
  return {
    validatedSamples: samples,
    history: { isClosed: true, isQuarantined: false, samples: structuredClone(samples) },
    source: {
      intervalProbes: [
        {
          name: 'after',
          captureBoundaryStartTime: 10.5,
          captureBoundaryEndTime: 12.5,
          transportInterval: {
            publishingGeneration: '7',
            start: 10.5,
            end: 12.5,
            enclosingStart: 10,
            enclosingEnd: 13,
            sampleCount: 3,
            enclosingSentBytes: '2000',
            enclosingRetransmittedBytes: '200',
            enclosingDroppedPackets: '2',
            meanBufferedBytes: 325,
            meanBufferMilliseconds: 325,
            meanRTTMilliseconds: 325,
            enclosingMaximumBufferedBytes: '900',
            enclosingMaximumBufferMilliseconds: '900',
            enclosingMaximumRTTMilliseconds: 900,
          },
        },
      ],
    },
  };
}
test('replays fractional sampled gauges while preserving wide enclosing counters', () => {
  assert.deepEqual(qualifyTransportIntervals(fixture()), {
    retainedSamples: 3,
    verifiedIntervals: 1,
    unknownIntervals: 0,
    scope: 'Historical sampled transport gauges; enclosing counter bounds; not capacity',
  });
});
for (const [name, mutate] of [
  [
    'interpolated counter',
    (x) => (x.source.intervalProbes[0].transportInterval.enclosingSentBytes = '1500'),
  ],
  ['changed mean', (x) => (x.source.intervalProbes[0].transportInterval.meanRTTMilliseconds = 900)],
  ['changed endpoint', (x) => (x.source.intervalProbes[0].transportInterval.start = 10)],
  [
    'hidden endpoint maximum',
    (x) => (x.source.intervalProbes[0].transportInterval.enclosingMaximumBufferedBytes = '400'),
  ],
  [
    'relabelled generation',
    (x) => (x.source.intervalProbes[0].transportInterval.publishingGeneration = '8'),
  ],
  ['raw sample tamper', (x) => (x.history.samples[0].sampledAt = 9)],
  ['unclosed history', (x) => (x.history.isClosed = false)],
  ['quarantined history', (x) => (x.history.isQuarantined = true)],
  ['unsupported unknown', (x) => (x.source.intervalProbes[0].transportInterval = null)],
])
  test(`rejects ${name}`, () => {
    const x = fixture();
    mutate(x);
    assert.throws(() => qualifyTransportIntervals(x));
  });

test('gap reset discards earlier coverage and permits a legitimate unknown probe', () => {
  const x = fixture();
  const newer = x.validatedSamples.map((p) => ({
    ...p,
    sampledAt: p.sampledAt + 10,
    sentBytes: String(BigInt(p.sentBytes) + 3000n),
    retransmittedBytes: String(BigInt(p.retransmittedBytes) + 300n),
    droppedPackets: String(BigInt(p.droppedPackets) + 3n),
  }));
  x.validatedSamples.push(...newer);
  x.history.samples = structuredClone(newer);
  const after = x.source.intervalProbes[0];
  const before = { ...structuredClone(after), name: 'before', transportInterval: null };
  after.captureBoundaryStartTime += 10;
  after.captureBoundaryEndTime += 10;
  for (const key of ['start', 'end', 'enclosingStart', 'enclosingEnd'])
    after.transportInterval[key] += 10;
  x.source.intervalProbes.unshift(before);
  assert.deepEqual(qualifyTransportIntervals(x), {
    retainedSamples: 3,
    verifiedIntervals: 1,
    unknownIntervals: 1,
    scope: 'Historical sampled transport gauges; enclosing counter bounds; not capacity',
  });
});

test('64-sample eviction never invents earlier interval coverage', () => {
  const samples = Array.from({ length: 70 }, (_, i) => ({
    publishingGeneration: '7',
    sampledAt: i,
    sentBytes: String(1000 + i * 100),
    retransmittedBytes: '0',
    droppedPackets: '0',
    senderBufferedBytes: '0',
    senderBufferMilliseconds: '0',
    rttMilliseconds: 0,
  }));
  const result = qualifyTransportIntervals({
    validatedSamples: samples,
    history: { isClosed: true, isQuarantined: false, samples: structuredClone(samples.slice(-64)) },
    source: {
      intervalProbes: [
        {
          name: 'before',
          captureBoundaryStartTime: 5.5,
          captureBoundaryEndTime: 6.5,
          transportInterval: null,
        },
        {
          name: 'after',
          captureBoundaryStartTime: 65.5,
          captureBoundaryEndTime: 68.5,
          transportInterval: {
            publishingGeneration: '7',
            start: 65.5,
            end: 68.5,
            enclosingStart: 65,
            enclosingEnd: 69,
            sampleCount: 5,
            enclosingSentBytes: '400',
            enclosingRetransmittedBytes: '0',
            enclosingDroppedPackets: '0',
            meanBufferedBytes: 0,
            meanBufferMilliseconds: 0,
            meanRTTMilliseconds: 0,
            enclosingMaximumBufferedBytes: '0',
            enclosingMaximumBufferMilliseconds: '0',
            enclosingMaximumRTTMilliseconds: 0,
          },
        },
      ],
    },
  });
  assert.deepEqual(result, {
    retainedSamples: 64,
    verifiedIntervals: 1,
    unknownIntervals: 1,
    scope: 'Historical sampled transport gauges; enclosing counter bounds; not capacity',
  });
});
