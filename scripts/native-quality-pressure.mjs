import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
const finite = (n) => Number.isFinite(n) && n >= 0;
const integer = (n) => Number.isSafeInteger(n) && n >= 0;
const counter = (n) => {
  assert(typeof n === 'string' && /^(0|[1-9][0-9]*)$/.test(n));
  return BigInt(n);
};
function enclosed(history, window, now, validate) {
  assert(history && Array.isArray(history.samples) && history.samples.length <= 64);
  assert(typeof history.isClosed === 'boolean' && typeof history.isQuarantined === 'boolean');
  const samples = history.samples;
  for (let i = 0; i < samples.length; i++) {
    const s = samples[i],
      previous = samples[i - 1];
    assert(finite(s.sampledAt));
    if (previous) assert(s.sampledAt > previous.sampledAt && s.sampledAt - previous.sampledAt <= 2);
    validate(s, previous);
  }
  const left = samples.findLastIndex((s) => s.sampledAt <= window.start);
  const right = samples.findIndex((s) => s.sampledAt >= window.end);
  const latest = samples.at(-1);
  if (
    history.isClosed ||
    history.isQuarantined ||
    !latest ||
    latest.sampledAt > now ||
    now - latest.sampledAt > 2 ||
    left < 0 ||
    right <= left
  )
    return null;
  return samples.slice(left, right + 1);
}
/** Replay only explicit simulator limits; OS samples and worker timings are observations, not capacity. */
export function replayNativePressure(row, snapshot, source) {
  const e = row.evidence,
    w = row.window;
  assert(e, 'Missing evaluated raw diagnostic evidence');
  const thermalSamples = enclosed(e.thermal, w, row.evaluatedAt, (s) =>
    assert([-1, 0, 1, 2, 3].includes(s.state)),
  );
  const maximum =
    thermalSamples &&
    (thermalSamples.some((s) => s.state === -1)
      ? -1
      : Math.max(...thermalSamples.map((s) => s.state)));
  const thermal = maximum === 0 ? 'nominal' : maximum >= 2 ? 'elevated' : 'unknown';
  const transportSamples = enclosed(e.transport, w, row.evaluatedAt, (s, p) => {
    assert.equal(s.generation, row.receipt.generation);
    for (const key of ['elapsedMilliseconds', 'sentBytes', 'retransmittedBytes']) {
      counter(s[key]);
      if (p) assert(counter(s[key]) >= counter(p[key]));
    }
    assert(counter(s.retransmittedBytes) <= counter(s.sentBytes));
    assert(
      integer(s.droppedPackets) && integer(s.senderBufferMilliseconds) && finite(s.rttMilliseconds),
    );
    if (p) {
      assert(s.droppedPackets >= p.droppedPackets);
      assert(
        counter(s.retransmittedBytes) - counter(p.retransmittedBytes) <=
          counter(s.sentBytes) - counter(p.sentBytes),
      );
    }
  });
  let transport = 'unknown';
  if (transportSamples) {
    const first = transportSamples[0],
      last = transportSamples.at(-1);
    const sent = counter(last.sentBytes) - counter(first.sentBytes),
      retransmitted = counter(last.retransmittedBytes) - counter(first.retransmittedBytes);
    transport =
      last.droppedPackets > first.droppedPackets ||
      transportSamples.some((s) => s.senderBufferMilliseconds > 500 || s.rttMilliseconds > 500) ||
      (sent > 0n && Number(retransmitted) / Number(sent) > 0.01)
        ? 'elevated'
        : sent > 0n
          ? 'nominal'
          : 'unknown';
  }
  let queue = null;
  const q = e.queue;
  if (q) {
    assert(typeof q.isClosed === 'boolean' && typeof q.isQuarantined === 'boolean');
    assert(Array.isArray(q.states) && q.states.length <= 4096);
    assert(finite(q.coveredThrough));
    for (let i = 0; i < q.states.length; i++) {
      const s = q.states[i];
      assert(finite(s.at) && s.at <= q.coveredThrough && (i === 0 || s.at > q.states[i - 1].at));
      assert([s.itemFraction, s.byteFraction].every((x) => finite(x) && x <= 1));
      assert(['startup', 'admitting', 'draining', 'closed'].includes(s.phase));
    }
    if (
      !q.isClosed &&
      !q.isQuarantined &&
      isDeepStrictEqual(q.scope, snapshot.scope) &&
      q.coveredThrough >= w.end &&
      q.coveredThrough <= row.evaluatedAt &&
      row.evaluatedAt - q.coveredThrough <= 2 &&
      q.states[0]?.at <= w.start
    ) {
      let area = 0,
        valid = true;
      for (let i = 0; i < q.states.length; i++) {
        const s = q.states[i],
          end = q.states[i + 1]?.at ?? q.coveredThrough;
        const duration = Math.min(end, w.end) - Math.max(s.at, w.start);
        if (duration <= 0) continue;
        if (s.phase !== 'admitting') valid = false;
        area += Math.max(s.itemFraction, s.byteFraction) * duration;
      }
      if (valid) queue = Math.min(1, area / (w.end - w.start));
    }
  }
  let worker = 'unknown';
  const p = e.processing;
  if (p) {
    // Later completion may improve the saved history; never retroactively improve
    // the pending evidence that was actually supplied to this decision.
    const final = source.processing;
    assert(final, 'Evaluated processing is missing from saved worker history');
    for (const k of ['encoder', 'scopeID', 'sequence', 'previousSequence', 'firstPTS'])
      assert.equal(p[k], final[k]);
    const i = p.interval,
      f = final.interval;
    for (const k of [
      'sourceStartExclusive',
      'sourceEndInclusive',
      'decodedFrames',
      'submittedFrames',
      'omittedBeforeEncoderFrames',
    ])
      assert.equal(i[k], f[k]);
    assert.deepEqual(i.filterDuration, f.filterDuration);
    assert.equal(String(p.sequence), source.sequence);
    assert.equal(String(p.previousSequence), source.previousSequence);
    assert.equal(String(p.firstPTS), source.firstDecodedPTS);
    assert.equal(String(i.sourceStartExclusive), source.previousDecodedPTS);
    assert.equal(String(i.sourceEndInclusive), source.lastDecodedPTS);
    assert.equal(i.decodedFrames, w.received);
    assert(
      [
        i.decodedFrames,
        i.submittedFrames,
        i.completedFrames,
        i.pendingFrames,
        i.omittedBeforeEncoderFrames,
      ].every(integer),
    );
    assert(i.completedFrames <= i.submittedFrames && i.submittedFrames <= i.decodedFrames);
    assert.equal(i.pendingFrames, i.submittedFrames - i.completedFrames);
    assert.equal(i.omittedBeforeEncoderFrames, i.decodedFrames - i.submittedFrames);
    assert(i.completedFrames <= f.completedFrames);
    if (i.pendingFrames > 0 || i.submittedFrames === 0) assert(i.processingDuration == null);
    if (i.submittedFrames === 0) assert(i.filterDuration == null);
    if (i.pendingFrames === 0) assert.deepEqual(i.processingDuration, f.processingDuration);
    for (const d of [i.filterDuration, i.processingDuration].filter(Boolean))
      assert(
        finite(d.meanMs) &&
          finite(d.maximumMs) &&
          d.meanMs <= d.maximumMs &&
          d.maximumMs <= Number.MAX_SAFE_INTEGER,
      );
    if (p.encoder === 'videotoolbox') {
      worker =
        i.omittedBeforeEncoderFrames > 0 ||
        i.filterDuration?.maximumMs > 250 ||
        i.processingDuration?.maximumMs > 1000
          ? 'elevated'
          : i.submittedFrames > 0 &&
              i.pendingFrames === 0 &&
              i.filterDuration &&
              i.processingDuration
            ? 'nominal'
            : 'unknown';
    }
  }
  for (const [k, value] of Object.entries({ thermal, transport, worker }))
    assert.equal(w[k], value, `${k} disagrees with raw evidence`);
  if (queue === null) assert.equal(w.queue, null);
  else
    assert(
      finite(w.queue) && Math.abs(w.queue - queue) < 1e-9,
      'Queue pressure disagrees with raw integration',
    );
  return { thermal, transport, worker, queue };
}
