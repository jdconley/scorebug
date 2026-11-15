import assert from 'node:assert/strict';
/** Requires samples from qualifyTransportStatistics and source probes already
 * joined to capture PTS/uptime by qualifyIngressPressure. */
export function qualifyTransportIntervals({ history, source, validatedSamples }) {
  assert.ok(history && source && Array.isArray(validatedSamples) && validatedSamples.length >= 2);
  assert.equal(history.isClosed, true);
  assert.equal(history.isQuarantined, false);
  let retained = [];
  for (const sample of validatedSamples) {
    if (retained.length && sample.sampledAt - retained.at(-1).sampledAt > 2) retained = [];
    retained.push(sample);
    if (retained.length > 64) retained.shift();
  }
  assert.deepEqual(
    history.samples,
    retained,
    'Native retained samples must match actual monitor collections',
  );
  let verified = 0,
    unknown = 0;
  for (const probe of source.intervalProbes) {
    const start = probe.captureBoundaryStartTime,
      end = probe.captureBoundaryEndTime;
    assert.ok(
      Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end > start && end <= 1e12,
    );
    const left = retained.findLastIndex((x) => x.sampledAt <= start),
      right = retained.findIndex((x) => x.sampledAt >= end);
    if (left < 0 || right < 0 || left >= right) {
      assert.equal(probe.transportInterval, null);
      unknown++;
      continue;
    }
    const points = retained.slice(left, right + 1),
      first = points[0],
      last = points.at(-1);
    const maximum = (key) => Math.max(...points.map((p) => Number(p[key])));
    const mean = (key) => {
      const max = maximum(key);
      if (!max) return 0;
      let normalized = 0;
      for (let i = 0; i < points.length - 1; i++) {
        const duration = Math.max(
          0,
          Math.min(end, points[i + 1].sampledAt) - Math.max(start, points[i].sampledAt),
        );
        normalized += (Number(points[i][key]) / max) * (duration / (end - start));
      }
      return Math.min(1, normalized) * max;
    };
    const expected = {
      publishingGeneration: first.publishingGeneration,
      start,
      end,
      enclosingStart: first.sampledAt,
      enclosingEnd: last.sampledAt,
      sampleCount: points.length,
      enclosingSentBytes: String(BigInt(last.sentBytes) - BigInt(first.sentBytes)),
      enclosingRetransmittedBytes: String(
        BigInt(last.retransmittedBytes) - BigInt(first.retransmittedBytes),
      ),
      enclosingDroppedPackets: String(BigInt(last.droppedPackets) - BigInt(first.droppedPackets)),
      meanBufferedBytes: mean('senderBufferedBytes'),
      meanBufferMilliseconds: mean('senderBufferMilliseconds'),
      meanRTTMilliseconds: mean('rttMilliseconds'),
      enclosingMaximumBufferedBytes: String(maximum('senderBufferedBytes')),
      enclosingMaximumBufferMilliseconds: String(maximum('senderBufferMilliseconds')),
      enclosingMaximumRTTMilliseconds: maximum('rttMilliseconds'),
    };
    assert.ok(probe.transportInterval);
    for (const [key, value] of Object.entries(expected)) {
      const actual = probe.transportInterval[key];
      if (key.startsWith('mean')) {
        assert.ok(Number.isFinite(actual));
        assert.ok(Math.abs(actual - value) <= 1e-8 * Math.max(1, value), `Incorrect ${key}`);
      } else assert.equal(actual, value, `Incorrect ${key}`);
    }
    verified++;
  }
  assert.ok(
    source.intervalProbes.find((p) => p.name === 'after')?.transportInterval,
    'Post-write finite fixture probe needs actual bracketing collections',
  );
  return {
    retainedSamples: retained.length,
    verifiedIntervals: verified,
    unknownIntervals: unknown,
    scope: 'Historical sampled transport gauges; enclosing counter bounds; not capacity',
  };
}
