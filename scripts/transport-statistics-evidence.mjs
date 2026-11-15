import assert from 'node:assert/strict';
const max64 = (1n << 64n) - 1n;
function integer(value, label, maximum = max64) {
  assert.ok(
    typeof value === 'string' && value.length <= 20 && /^(0|[1-9]\d*)$/.test(value),
    `${label}: exact decimal integer required`,
  );
  const result = BigInt(value);
  assert.ok(result <= maximum, `${label}: out of range`);
  return result;
}
function finite(value, label) {
  assert.ok(
    typeof value === 'number' && Number.isFinite(value) && value >= 0,
    `${label}: invalid number`,
  );
  return value;
}
/** Real local SRT fixture evidence only. No inferred available/video capacity. */
export function qualifyTransportStatistics(events, finished, publishingGeneration) {
  assert.equal(
    finished.transportStatisticsAfterStop,
    null,
    'Statistics must be unavailable after joined stop',
  );
  const observations = events.filter((x) => x.event === 'publisher-observation');
  assert.ok(
    observations.length >= 2 && observations.length <= 64,
    'Bounded transport observations required',
  );
  let prior = null;
  const samples = [];
  for (const observation of observations) {
    const sample = observation.transportStatistics;
    if (sample === null) continue; // No collection may have happened at startup.
    assert.ok(sample && typeof sample === 'object', 'Missing timestamped statistics');
    assert.equal(
      sample.publishingGeneration,
      publishingGeneration,
      'Publishing generation mismatch',
    );
    assert.ok(integer(sample.publishingGeneration, 'generation') > 0n);
    const sampledAt = finite(sample.sampledAt, 'sample time'),
      observedAt = finite(observation.statisticsObservedAt, 'read time');
    assert.ok(
      sampledAt <= 1e12 && observedAt >= sampledAt && observedAt - sampledAt <= 2,
      'Stale or future cached sample',
    );
    const elapsed = integer(sample.elapsedMilliseconds, 'elapsed', (1n << 63n) - 1n);
    const sent = integer(sample.sentBytes, 'sent'),
      retransmitted = integer(sample.retransmittedBytes, 'retransmitted');
    const dropped = integer(sample.droppedPackets, 'drops', 2147483647n);
    for (const key of ['senderBufferedBytes', 'senderBufferMilliseconds', 'availableSenderBytes'])
      integer(sample[key], key, 2147483647n);
    finite(sample.rttMilliseconds, 'RTT');
    finite(sample.estimatedBandwidthMbps, 'bandwidth estimate');
    assert.ok(retransmitted <= sent, 'Retransmissions exceed total send bytes');
    if (prior) {
      if (sampledAt === prior.sampledAt) {
        assert.deepEqual(sample, prior, 'Contradictory cached reading');
        continue;
      }
      assert.ok(
        sampledAt > prior.sampledAt && elapsed >= BigInt(prior.elapsedMilliseconds),
        'Transport clock reversed',
      );
      const sentDelta = sent - BigInt(prior.sentBytes),
        retransDelta = retransmitted - BigInt(prior.retransmittedBytes);
      assert.ok(
        sentDelta >= 0n &&
          retransDelta >= 0n &&
          retransDelta <= sentDelta &&
          dropped >= BigInt(prior.droppedPackets),
        'Counters reset or contradict',
      );
    }
    samples.push(sample);
    prior = sample;
  }
  assert.ok(samples.length >= 2, 'Need advancing native collections');
  const first = samples[0],
    last = samples.at(-1);
  assert.ok(BigInt(last.sentBytes) > BigInt(first.sentBytes), 'No actual transport bytes sent');
  assert.ok(
    BigInt(last.elapsedMilliseconds) > BigInt(first.elapsedMilliseconds),
    'Socket clock did not advance',
  );
  return {
    method: 'Actual timestamped native SRT collections; capacity remains unqualified',
    samples,
    windows: qualifyWindows(observations),
    sentByteDelta: String(BigInt(last.sentBytes) - BigInt(first.sentBytes)),
    retransmittedByteDelta: String(
      BigInt(last.retransmittedBytes) - BigInt(first.retransmittedBytes),
    ),
  };
}

// Independently reconstruct actual endpoints and left-held gauge weights from raw
// validated collections. This fixture oracle never infers delivery or capacity.
function qualifyWindows(observations) {
  let retained = [],
    previous = null;
  const windows = [];
  for (const observation of observations) {
    const sample = observation.transportStatistics;
    const now = finite(observation.statisticsObservedAt, 'window read time');
    if (sample && sample.sampledAt !== previous?.sampledAt) {
      if (previous && sample.sampledAt - previous.sampledAt > 2) retained = [];
      retained.push(sample);
      if (retained.length > 64) retained.shift();
      previous = sample;
    }
    let expected = null;
    if (previous && now >= previous.sampledAt && now - previous.sampledAt <= 2) {
      const points = retained.filter((x) => previous.sampledAt - x.sampledAt <= 5);
      const first = points[0],
        last = points.at(-1);
      const duration = last.sampledAt - first.sampledAt;
      if (duration >= 1) {
        const mean = (key) => {
          const maximum = Math.max(...points.map((x) => Number(x[key])));
          if (maximum === 0) return 0;
          let weighted = 0;
          for (let i = 0; i < points.length - 1; i++)
            weighted +=
              (Number(points[i][key]) / maximum) *
              ((points[i + 1].sampledAt - points[i].sampledAt) / duration);
          return Math.min(1, weighted) * maximum;
        };
        expected = {
          publishingGeneration: last.publishingGeneration,
          start: first.sampledAt,
          end: last.sampledAt,
          sampleCount: points.length,
          sentBytes: String(BigInt(last.sentBytes) - BigInt(first.sentBytes)),
          retransmittedBytes: String(
            BigInt(last.retransmittedBytes) - BigInt(first.retransmittedBytes),
          ),
          droppedPackets: String(BigInt(last.droppedPackets) - BigInt(first.droppedPackets)),
          meanBufferedBytes: mean('senderBufferedBytes'),
          meanBufferMilliseconds: mean('senderBufferMilliseconds'),
          meanRTTMilliseconds: mean('rttMilliseconds'),
          maximumBufferedBytes: String(
            Math.max(...points.map((x) => Number(x.senderBufferedBytes))),
          ),
          maximumBufferMilliseconds: String(
            Math.max(...points.map((x) => Number(x.senderBufferMilliseconds))),
          ),
          maximumRTTMilliseconds: Math.max(...points.map((x) => x.rttMilliseconds)),
        };
      }
    }
    const actual = observation.transportWindow;
    if (expected === null) {
      assert.equal(actual, null, 'Window without complete fresh coverage');
      continue;
    }
    assert.ok(actual && typeof actual === 'object', 'Missing transport window');
    assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort(), 'Window fields');
    for (const [key, value] of Object.entries(expected)) {
      if (key.startsWith('mean')) {
        finite(actual[key], key);
        assert.ok(Math.abs(actual[key] - value) <= Math.max(1, value) * 1e-12, `Incorrect ${key}`);
      } else assert.equal(actual[key], value, `Incorrect window ${key}`);
    }
    if (windows.at(-1)?.end !== actual.end) windows.push(actual);
  }
  return windows;
}
