import assert from 'node:assert/strict';
import test from 'node:test';
import {
  decodeFixtureBarcodes,
  fixtureFrameID,
  qualifyVideoObservation,
} from '../video-observation-qualification.mjs';

const scope = {
  recordingID: 'recording',
  matchID: 'match',
  broadcastGeneration: 1,
  publishingAttemptID: '4ab12a92-ef52-4f22-a142-94e2f2eaa983',
  appliedProfileRevision: '1',
};
const ids = (first, last) => Array.from({ length: last - first + 1 }, (_, i) => first + i);
const pts = (frame) => ({ value: String(7395 + frame * 2), timescale: 60, epoch: '0', flags: 1 });
function aggregate(first, last, end) {
  return {
    callbackCount: String(last - first + 1),
    advancingSourcePTSCount: String(last - first + 1),
    duplicateSourcePTSCount: '0',
    reorderedSourcePTSCount: '0',
    invalidSourcePTSCount: '0',
    discontinuousSourcePTSCount: '0',
    firstSourcePTS: pts(first),
    lastSourcePTS: pts(last),
    highWaterSourcePTS: pts(last),
    firstObservationTime: 1,
    lastObservationTime: end - 0.01,
    invalidity: 0,
  };
}
function window(start, end, first, last, partial = false) {
  return {
    monotonicStart: start,
    monotonicEnd: end,
    scheduledMonotonicEnd: start + 5,
    coveredWindowCount: '1',
    isCoalescedEmptyGap: false,
    isPartial: partial,
    isClosed: partial,
    captureVideo: aggregate(first, last, end),
    encodedVideo: aggregate(first, last, end),
  };
}
function fixture() {
  return {
    snapshot: {
      formatVersion: 1,
      scope: { ...scope },
      monotonicAnchor: 0,
      captureDetachedAt: 17,
      windowDuration: 5,
      completed: [window(0, 5, 60, 149), window(5, 10, 150, 299), window(10, 15, 300, 449)],
      current: window(15, 17, 450, 479, true),
      omittedCompletedWindowCount: '0',
      omittedThroughMonotonicTime: null,
      rejectedClockOperationCount: '0',
      invalidity: 0,
      isClosed: true,
    },
    expectedScope: { recordingID: 'recording', matchID: 'match', broadcastGeneration: 1 },
    archiveIDs: ids(0, 599),
    liveIDs: ids(120, 479),
  };
}

test('maps rational fixture timestamps exactly, including source frame zero', () => {
  assert.equal(fixtureFrameID(pts(0)), 0);
  assert.equal(fixtureFrameID({ value: '493', timescale: 4, epoch: '0', flags: 1 }), 0);
  assert.equal(fixtureFrameID(pts(137)), 137);
  assert.throws(() => fixtureFrameID({ ...pts(0), value: '7396' }), /integer fixture frame/);
  assert.throws(() => fixtureFrameID({ ...pts(0), epoch: '1' }), /epoch/);
  assert.throws(() => fixtureFrameID({ ...pts(0), value: '0' }), /integer fixture frame/);
  assert.throws(() => fixtureFrameID({ ...pts(0), value: 7395 }), /decimal string/);
});

test('extended fixture history requires an explicit trusted limit and retains all quality gates', () => {
  const f = fixture();
  for (let i = 3; i < 10; i++)
    f.snapshot.completed.push(window(i * 5, (i + 1) * 5, i * 150, (i + 1) * 150 - 1));
  f.snapshot.current = window(50, 52, 1500, 1559, true);
  f.snapshot.captureDetachedAt = 52;
  f.archiveIDs = ids(0, 1709);
  f.liveIDs = ids(120, 1559);
  assert.throws(() => qualifyVideoObservation(f), /Bounded completed history/);
  const result = qualifyVideoObservation({ ...f, completedWindowLimit: 64 });
  assert.equal(result.windows.length, 11);
  f.snapshot.completed[5].encodedVideo.callbackCount = '149';
  assert.throws(() => qualifyVideoObservation({ ...f, completedWindowLimit: 64 }), /count/);
});

test('observation history limit cannot be widened arbitrarily', () => {
  for (const completedWindowLimit of [0, 9, 65, Infinity, '64'])
    assert.throws(
      () => qualifyVideoObservation({ ...fixture(), completedWindowLimit }),
      /history limit/,
    );
});

test('uses full monotonic intervals and reports startup, drain, and legitimate GOP acquisition gap', () => {
  const result = qualifyVideoObservation(fixture());
  assert.equal(result.windows[0].captureVideo.fps, 18);
  assert.equal(result.windows[1].captureVideo.fps, 30);
  assert.equal(result.windows[3].encodedVideo.fps, 15);
  assert.equal(result.windows[3].durationSeconds, 2);
  assert.equal(result.windows[3].phase, 'finalPartial');
  assert.equal(result.stableCompletedWindowCount, 2);
  assert.equal(result.totals.captureVideo, 420);
  assert.equal(result.alignedComparison.windows.length, 3);
  assert.deepEqual(result.uncompared.acquisition, {
    firstSourceFrame: 60,
    lastSourceFrame: 119,
    sourceFrames: 60,
  });
  assert.equal(result.uncompared.windows[0].index, 0);
  assert.equal(result.uncompared.windows[0].reason, 'outside decoded live range');
});

for (const [name, mutate, message] of [
  ['wrong recording', (f) => (f.snapshot.scope.recordingID = 'stale'), /scope/],
  ['wrong match', (f) => (f.snapshot.scope.matchID = 'stale'), /scope/],
  ['wrong generation', (f) => (f.snapshot.scope.broadcastGeneration = 2), /scope/],
  ['wrong profile', (f) => (f.snapshot.scope.appliedProfileRevision = '2'), /profile/],
  ['invalid attempt', (f) => (f.snapshot.scope.publishingAttemptID = 'old'), /UUID/],
  ['open owner', (f) => (f.snapshot.isClosed = false), /closed/],
  ['open terminal', (f) => (f.snapshot.current.isClosed = false), /closed/],
  ['invalid owner', (f) => (f.snapshot.invalidity = 1), /invalidity/],
  ['invalid window', (f) => (f.snapshot.completed[1].encodedVideo.invalidity = 2), /invalidity/],
  ['clock rejection', (f) => (f.snapshot.rejectedClockOperationCount = '1'), /clock/],
  ['evicted history', (f) => (f.snapshot.omittedCompletedWindowCount = '1'), /evicted/],
  ['eviction time', (f) => (f.snapshot.omittedThroughMonotonicTime = 0), /evicted/],
  [
    'fractional PTS',
    (f) => (f.snapshot.completed[0].captureVideo.firstSourcePTS.value = '7396'),
    /integer fixture frame/,
  ],
  ['bad count', (f) => (f.snapshot.completed[1].encodedVideo.callbackCount = '149'), /count/],
  ['missing decoded frame', (f) => f.liveIDs.splice(100, 1), /decoded/],
  ['duplicate decoded frame', (f) => (f.liveIDs[100] = f.liveIDs[99]), /decoded/],
  ['archive gap', (f) => f.archiveIDs.splice(100, 1), /archive/],
  ['missing full interval', (f) => f.snapshot.completed.splice(1, 1), /contiguous/],
  ['nonfinite detach', (f) => (f.snapshot.captureDetachedAt = NaN), /finite/],
  ['detach before anchor', (f) => (f.snapshot.captureDetachedAt = -1), /detach/],
  ['detach after closure', (f) => (f.snapshot.captureDetachedAt = 18), /detach/],
  ['nonfinite clock', (f) => (f.snapshot.current.monotonicEnd = NaN), /finite/],
  ['wrong full duration', (f) => (f.snapshot.completed[1].monotonicEnd = 9), /full window/],
])
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifyVideoObservation(f), message);
  });

test('rejects a low steady cadence even though source PTS cadence is 30 fps', () => {
  const f = fixture();
  f.snapshot.completed[1] = window(5, 10, 150, 249);
  f.snapshot.completed[2] = window(10, 15, 250, 399);
  f.snapshot.current = window(15, 17, 400, 429, true);
  assert.throws(() => qualifyVideoObservation(f), /24 fps/);
});

test('requires two stable complete windows and one aligned encoded comparison', () => {
  const f = fixture();
  f.snapshot.completed.pop();
  f.snapshot.current = window(10, 12, 300, 329, true);
  f.snapshot.captureDetachedAt = 12;
  assert.throws(() => qualifyVideoObservation(f), /two stable/);
  const g = fixture();
  g.liveIDs = ids(470, 479);
  assert.throws(() => qualifyVideoObservation(g), /aligned/);
});

test('decodes the bounded sixteen-bit fixture barcode artifact', () => {
  const bytes = Buffer.alloc(32);
  bytes[0] = 255;
  bytes[15] = 255;
  bytes[16 + 5] = 255;
  assert.deepEqual(decodeFixtureBarcodes(bytes), [32769, 32]);
  assert.throws(() => decodeFixtureBarcodes(Buffer.alloc(17)), /barcode/);
  assert.throws(() => fixtureFrameID(pts(-1)), /fixture range/);
});

function emptyAggregate(firstObservationTime = null, lastObservationTime = null, highWater = null) {
  return {
    ...aggregate(0, -1, 0),
    firstSourcePTS: null,
    lastSourcePTS: null,
    highWaterSourcePTS: highWater === null ? null : pts(highWater),
    firstObservationTime,
    lastObservationTime,
  };
}

test('encoder startup across the first boundary retains mixed windows and requires two later steady windows', () => {
  const f = fixture();
  f.snapshot.completed[0].encodedVideo = emptyAggregate();
  f.snapshot.completed[1].encodedVideo = aggregate(210, 299, 10);
  f.snapshot.completed.push(window(15, 20, 450, 599));
  f.snapshot.current = window(20, 22, 600, 629, true);
  f.snapshot.captureDetachedAt = 22;
  for (const w of [...f.snapshot.completed.slice(1), f.snapshot.current])
    w.encodedVideo.firstObservationTime = 7;
  f.archiveIDs = ids(0, 749);
  f.liveIDs = ids(240, 629);
  const result = qualifyVideoObservation(f);
  assert.equal(result.fullyActiveAt, 7);
  assert.equal(result.windows[0].phase, 'beforeBothStagesActive');
  assert.equal(result.windows[1].phase, 'startupTransition');
  assert.equal(result.windows[1].encodedVideo.fps, 18);
  assert.equal(result.stableCompletedWindowCount, 2);
  assert.equal(result.windows[0].captureVideo.firstObservationTime, 1);
});

test('explicit capture detach inside a full window preserves its lower cadence without labeling it steady', () => {
  const f = fixture();
  f.snapshot.completed.push(window(15, 20, 450, 599), window(20, 25, 600, 689));
  f.snapshot.completed[4].captureVideo.lastObservationTime = 22.99;
  f.snapshot.completed[4].encodedVideo.lastObservationTime = 23.1;
  f.snapshot.current = {
    ...window(25, 26, 0, -1, true),
    captureVideo: emptyAggregate(1, 22.99, 689),
    encodedVideo: emptyAggregate(1, 23.1, 689),
  };
  f.snapshot.captureDetachedAt = 23;
  f.archiveIDs = ids(0, 779);
  f.liveIDs = ids(120, 689);
  const result = qualifyVideoObservation(f);
  assert.equal(result.captureDetachedAt, 23);
  assert.equal(result.stableCompletedWindowCount, 3);
  assert.equal(result.windows[4].phase, 'captureDetachTransition');
  assert.equal(result.windows[4].durationSeconds, 5);
  assert.equal(result.windows[4].captureVideo.fps, 18);
  assert.equal(result.windows[5].phase, 'finalPartial');
  assert.equal(result.windows[5].captureVideo.fps, 0);
  // A last callback at 23s must not redefine an explicit later detach and hide a stall.
  f.snapshot.captureDetachedAt = 25;
  assert.throws(() => qualifyVideoObservation(f), /24 fps/);
});

test('ten-minute observation history requires128 and preserves continuity and eviction checks', () => {
  const f = fixture();
  for (let i = 3; i < 120; i++)
    f.snapshot.completed.push(window(i * 5, (i + 1) * 5, i * 150, (i + 1) * 150 - 1));
  f.snapshot.current = window(600, 602, 18000, 18059, true);
  f.snapshot.captureDetachedAt = 602;
  f.archiveIDs = ids(0, 18209);
  f.liveIDs = ids(120, 18059);
  assert.throws(
    () => qualifyVideoObservation({ ...f, completedWindowLimit: 64 }),
    /Bounded completed history/,
  );
  assert.equal(qualifyVideoObservation({ ...f, completedWindowLimit: 128 }).windows.length, 121);
  f.snapshot.omittedCompletedWindowCount = '1';
  assert.throws(() => qualifyVideoObservation({ ...f, completedWindowLimit: 128 }), /evicted/);
  f.snapshot.omittedCompletedWindowCount = '0';
  f.snapshot.completed.splice(70, 1);
  assert.throws(() => qualifyVideoObservation({ ...f, completedWindowLimit: 128 }), /contiguous/);
});
