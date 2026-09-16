import { expect, it } from 'vitest';
import { DecodedFrameHistory } from '../src/decoded-frame-history.js';
import { EncoderTimingTelemetry } from '../src/encoder-timing.js';
import { workerProcessingInterval } from '../src/worker-processing.js';
function fixture(points = [0, 3000, 6000, 9000], submitted = points) {
  let now = 0;
  const decoded = new DecodedFrameHistory(() => now, 'scope'),
    encoded = new EncoderTimingTelemetry(() => now, 'scope');
  for (const [i, pts] of points.entries()) {
    now = i * 10;
    decoded.push(Buffer.from(`frame:${i} pts:${pts} pts_time:0\nscorebug.source=1\n`));
  }
  now = 100;
  for (const [i, pts] of submitted.entries())
    encoded.push(Buffer.from(`pre ${i} 1/90000 ${pts}\n`));
  return {
    decoded,
    encoded,
    at: (t: number) => {
      now = t;
    },
    snapshot: () => ({ decoded: decoded.snapshot(), encoded: encoded.snapshot() }),
    complete: (points = submitted) => {
      for (const [i, pts] of points.entries())
        encoded.push(Buffer.from(`post ${i} 1/90000 ${pts}\n`));
    },
  };
}
it('matches a complete source interval and its reader-observed processing durations', () => {
  const f = fixture();
  f.at(120);
  f.complete();
  expect(workerProcessingInterval(f.snapshot(), 0, 9000)).toEqual({
    sourceStartExclusive: 0,
    sourceEndInclusive: 9000,
    decodedFrames: 3,
    submittedFrames: 3,
    completedFrames: 3,
    pendingFrames: 0,
    omittedBeforeEncoderFrames: 0,
    filterDuration: { meanMs: 80, maximumMs: 90 },
    processingDuration: { meanMs: 100, maximumMs: 110 },
  });
});
it('accounts for explicit frame caps with a submission beyond the decoder endpoint', () => {
  const f = fixture([0, 1500, 3000, 4500, 6000], [0, 3000, 6000]);
  f.at(120);
  f.complete();
  expect(workerProcessingInterval(f.snapshot(), 0, 4500)).toMatchObject({
    decodedFrames: 3,
    submittedFrames: 1,
    completedFrames: 1,
    pendingFrames: 0,
    omittedBeforeEncoderFrames: 2,
  });
  expect(workerProcessingInterval(f.snapshot(), 0, 1500)).toMatchObject({
    decodedFrames: 1,
    submittedFrames: 0,
    completedFrames: 0,
    filterDuration: null,
    processingDuration: null,
  });
});
it('preserves incomplete pending work without inventing completion durations', () => {
  const f = fixture();
  f.at(120);
  f.complete([0, 3000]);
  expect(workerProcessingInterval(f.snapshot(), 0, 9000)).toMatchObject({
    decodedFrames: 3,
    submittedFrames: 3,
    completedFrames: 1,
    pendingFrames: 2,
    filterDuration: { meanMs: 80, maximumMs: 90 },
    processingDuration: null,
  });
});
it('keeps valid source counts when independent pipe arrivals make latency unknown', () => {
  let now = 0;
  const encoded = new EncoderTimingTelemetry(() => now, 'scope');
  encoded.push(Buffer.from('pre 0 1/30 0\npre 1 1/30 1\npost 0 1/30 0\npost 1 1/30 1\n'));
  now = 10;
  const decoded = new DecodedFrameHistory(() => now, 'scope');
  decoded.push(
    Buffer.from(
      'frame:0 pts:0 pts_time:0\nscorebug.source=1\nframe:1 pts:3000 pts_time:0\nscorebug.source=1\n',
    ),
  );
  expect(
    workerProcessingInterval({ decoded: decoded.snapshot(), encoded: encoded.snapshot() }, 0, 3000),
  ).toMatchObject({
    decodedFrames: 1,
    submittedFrames: 1,
    completedFrames: 1,
    filterDuration: null,
    processingDuration: null,
  });
});
it('requires exact retained decoder anchors and encoder brackets', () => {
  const f = fixture();
  f.complete();
  for (const [a, b] of [
    [-3000, 6000],
    [0, 12000],
    [1, 6000],
    [0, 1],
    [6000, 3000],
    [0, 0],
    [NaN, 6000],
  ])
    expect(workerProcessingInterval(f.snapshot(), a!, b!)).toBeNull();
  const after = fixture([0, 3000, 6000, 9000], [0, 3000]);
  after.complete();
  expect(workerProcessingInterval(after.snapshot(), 0, 9000)).toBeNull();
  const before = fixture([0, 3000, 6000, 9000], [3000, 6000, 9000]);
  before.complete();
  expect(workerProcessingInterval(before.snapshot(), 0, 9000)).toBeNull();
});
it('rejects mismatched scopes, invalid histories and encoded frames absent from decoder history', () => {
  const f = fixture();
  f.complete();
  const snapshot = f.snapshot();
  expect(
    workerProcessingInterval(
      { ...snapshot, encoded: { ...snapshot.encoded, scopeID: 'other' } },
      0,
      9000,
    ),
  ).toBeNull();
  f.decoded.invalidatePipe();
  expect(workerProcessingInterval(f.snapshot(), 0, 9000)).toBeNull();
  const invalid = fixture();
  invalid.encoded.invalidatePipe();
  expect(workerProcessingInterval(invalid.snapshot(), 0, 9000)).toBeNull();
  const mismatch = fixture([0, 3000, 6000, 9000], [0, 4000, 9000]);
  mismatch.complete();
  expect(workerProcessingInterval(mismatch.snapshot(), 0, 9000)).toBeNull();
});
it('rejects fractional projection and missing history coverage; closes remain historical', () => {
  const f = fixture();
  f.complete();
  f.decoded.end();
  f.encoded.end();
  expect(workerProcessingInterval(f.snapshot(), 0, 9000)?.completedFrames).toBe(3);
  const s = f.snapshot();
  expect(
    workerProcessingInterval(
      { ...s, decoded: { ...s.decoded, frames: s.decoded.frames.slice(1) } },
      0,
      9000,
    ),
  ).toBeNull();
  expect(
    workerProcessingInterval(
      {
        ...s,
        encoded: {
          ...s.encoded,
          frames: s.encoded.frames.map((x) => ({ ...x, timeBaseDenominator: 999999999 })),
        },
      },
      0,
      9000,
    ),
  ).toBeNull();
});

it('requires the beyond-end cap bracket to have retained decoder provenance', () => {
  const f = fixture([0, 1500, 3000, 4500], [0, 3000, 6000]);
  f.complete();
  expect(workerProcessingInterval(f.snapshot(), 0, 4500)).toBeNull();
});
it('excludes a pending boundary anchor from included completion counts', () => {
  const f = fixture();
  f.at(120);
  f.complete([3000, 6000, 9000]);
  expect(f.snapshot().encoded.pendingFrames).toBe(1);
  expect(workerProcessingInterval(f.snapshot(), 0, 9000)).toMatchObject({
    submittedFrames: 3,
    completedFrames: 3,
    pendingFrames: 0,
    processingDuration: { meanMs: 100, maximumMs: 110 },
  });
});
