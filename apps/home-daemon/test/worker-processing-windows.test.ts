import { expect, it } from 'vitest';
import type { DecodedVideoSnapshot } from '@scorebug/protocol';
import { WorkerProcessingWindows } from '../src/worker-processing-windows.js';
import { DecodedFrameHistory } from '../src/decoded-frame-history.js';
import { EncoderTimingTelemetry } from '../src/encoder-timing.js';

function history(pending = false, scope = 'scope') {
  let now = 0;
  const decoded = new DecodedFrameHistory(() => now, scope);
  const encoded = new EncoderTimingTelemetry(() => now, scope);
  for (let i = 0; i < 10; i++) {
    now = i * 33;
    decoded.push(Buffer.from(`frame:${i} pts:${i * 3000} pts_time:${i / 30}\nscorebug.source=1\n`));
    now++;
    encoded.push(Buffer.from(`pre ${i} 1/90000 ${i * 3000}\n`));
    now++;
    if (!pending || i !== 5)
      encoded.push(Buffer.from(`post ${pending && i > 5 ? i - 1 : i} 1/90000 ${i * 3000}\n`));
  }
  return { decoded: decoded.snapshot(), encoded: encoded.snapshot() };
}
function video(sequence = 1): DecodedVideoSnapshot {
  return {
    clock: 'mpegts-pts-90k-v1',
    invalidReason: null,
    ended: false,
    completed: {
      sequence,
      durationMs: 5000,
      ageMs: 0,
      valid: true,
      firstPTS: (sequence - 1) * 9000,
      lastPTS: (sequence - 1) * 9000 + 6000,
      freshFrames: 3,
      duplicateFrames: 0,
      reorderedFrames: 0,
    },
  };
}
function acquired(pending = false) {
  const collector = new WorkerProcessingWindows();
  expect(collector.observe(video(), history())).toBeNull();
  return { collector, result: collector.observe(video(2), history(pending)) };
}
it('joins exactly adjacent source windows, excluding the previous endpoint', () => {
  expect(acquired().result).toEqual({
    scopeID: 'scope',
    previousSequence: 1,
    sequence: 2,
    firstPTS: 9000,
    interval: {
      sourceStartExclusive: 6000,
      sourceEndInclusive: 15000,
      decodedFrames: 3,
      submittedFrames: 3,
      completedFrames: 3,
      pendingFrames: 0,
      omittedBeforeEncoderFrames: 0,
      filterDuration: { meanMs: 1, maximumMs: 1 },
      processingDuration: { meanMs: 2, maximumMs: 2 },
    },
  });
});
it('can finish pending work on a later read of the same decoder window', () => {
  const { collector, result } = acquired(true);
  expect(result?.interval).toMatchObject({
    completedFrames: 2,
    pendingFrames: 1,
    processingDuration: null,
  });
  expect(collector.observe(video(2), history())?.interval.pendingFrames).toBe(0);
});
it('freezes completed observations through eviction and isolates returned mutations', () => {
  const { collector, result } = acquired();
  const expected = structuredClone(result);
  result!.interval.completedFrames = 999;
  const evicted = history();
  evicted.decoded = { ...evicted.decoded, frames: [] };
  evicted.encoded = { ...evicted.encoded, frames: [] };
  const later = video(2);
  later.completed!.ageMs = 1000;
  expect(collector.observe(later, evicted)).toEqual(expected);
});
it.each(['ended', 'invalid', 'scope'] as const)(
  'clears even frozen evidence on %s history',
  (kind) => {
    const { collector } = acquired();
    const snapshot = history();
    if (kind === 'ended') snapshot.encoded = { ...snapshot.encoded, ended: true };
    if (kind === 'invalid') snapshot.decoded = { ...snapshot.decoded, invalidReason: 'pipe' };
    if (kind === 'scope') snapshot.encoded = { ...snapshot.encoded, scopeID: 'other' };
    expect(collector.observe(video(2), snapshot)).toBeNull();
  },
);
it.each(['rewind', 'contents'] as const)('quarantines %s for the collector lifetime', (kind) => {
  const { collector } = acquired();
  const changed = video(kind === 'rewind' ? 1 : 2);
  if (kind === 'contents') changed.completed!.firstPTS++;
  expect(collector.observe(changed, history())).toBeNull();
  expect(collector.observe(video(2), history())).toBeNull();
});
it('rejects a sequence gap and reacquires on the next adjacent pair', () => {
  const collector = new WorkerProcessingWindows();
  collector.observe(video(), history());
  const second = video(2);
  second.completed!.sequence = 3;
  expect(collector.observe(second, history())).toBeNull();
  const next = video(2);
  next.completed!.sequence = 4;
  // Repeated source data does not establish a new source interval.
  expect(collector.observe(next, history())).toBeNull();
});
it.each(['duplicate', 'reordered', 'empty', 'invalid', 'ended', 'noWindow'] as const)(
  'does not retain current evidence across %s decoder windows',
  (kind) => {
    const { collector } = acquired();
    const changed = video(3);
    if (kind === 'duplicate') changed.completed!.duplicateFrames = 1;
    if (kind === 'reordered') changed.completed!.reorderedFrames = 1;
    if (kind === 'empty')
      Object.assign(changed.completed!, { firstPTS: null, lastPTS: null, freshFrames: 0 });
    if (kind === 'invalid') changed.invalidReason = 'clock';
    if (kind === 'ended') changed.ended = true;
    if (kind === 'noWindow') changed.completed = null;
    expect(collector.observe(changed, history())).toBeNull();
  },
);
it('requires exact retained anchors, first source PTS and frame counts', () => {
  for (const kind of ['anchor', 'first', 'count']) {
    const collector = new WorkerProcessingWindows();
    collector.observe(video(), history());
    const snapshot = history(),
      next = video(2);
    if (kind === 'anchor')
      snapshot.decoded = {
        ...snapshot.decoded,
        frames: snapshot.decoded.frames.filter((f) => f.pts !== 6000),
      };
    if (kind === 'first') next.completed!.firstPTS++;
    if (kind === 'count') next.completed!.freshFrames++;
    expect(collector.observe(next, snapshot)).toBeNull();
  }
});
it('does not freeze a zero-submission interval', () => {
  const collector = new WorkerProcessingWindows();
  collector.observe(video(), history());
  const snapshot = history();
  snapshot.encoded = {
    ...snapshot.encoded,
    frames: snapshot.encoded.frames.filter((f) => Number(f.pts) <= 6000 || Number(f.pts) > 15000),
  };
  expect(collector.observe(video(2), snapshot)?.interval.submittedFrames).toBe(0);
  expect(collector.observe(video(2), history())?.interval.submittedFrames).toBe(3);
});

it('reacquires after a sequence gap when the next source window is adjacent', () => {
  const collector = new WorkerProcessingWindows();
  collector.observe(video(), history());
  const skipped = video(2);
  skipped.completed!.sequence = 3;
  expect(collector.observe(skipped, history())).toBeNull();
  const next = video(3);
  next.completed!.sequence = 4;
  expect(collector.observe(next, history())).toMatchObject({
    previousSequence: 3,
    sequence: 4,
    interval: {
      sourceStartExclusive: 15000,
      sourceEndInclusive: 24000,
      decodedFrames: 3,
      completedFrames: 3,
    },
  });
});
