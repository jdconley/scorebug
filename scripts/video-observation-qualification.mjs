import assert from 'node:assert/strict';

function finite(value, label) {
  assert.ok(typeof value === 'number' && Number.isFinite(value), `${label} must be finite`);
  return value;
}
function integer(value, label, { signed = false } = {}) {
  assert.ok(
    typeof value === 'string' && (signed ? /^-?(0|[1-9]\d*)$/ : /^(0|[1-9]\d*)$/).test(value),
    `${label} must be a decimal string`,
  );
  const parsed = BigInt(value);
  assert.ok(
    parsed >= (signed ? -(1n << 63n) : 0n) &&
      parsed <= (signed ? (1n << 63n) - 1n : (1n << 64n) - 1n),
    `${label} out of 64-bit range`,
  );
  return parsed;
}
function count(value, label) {
  const parsed = integer(value, label);
  assert.ok(parsed <= BigInt(Number.MAX_SAFE_INTEGER), `${label} exceeds qualification bound`);
  return Number(parsed);
}

/** Known FixtureCameraSource clock only: 7395/60 + frameID/30.
 * Rational arithmetic never passes a CMTime Int64 through a JavaScript Number. */
export function fixtureFrameID(pts) {
  assert.ok(pts && typeof pts === 'object', 'Missing source PTS');
  const value = integer(pts.value, 'PTS value', { signed: true });
  assert.equal(
    integer(pts.epoch, 'PTS epoch', { signed: true }),
    0n,
    'Fixture PTS epoch must be zero',
  );
  assert.ok(
    Number.isInteger(pts.timescale) && pts.timescale > 0 && pts.timescale <= 2147483647,
    'Invalid PTS timescale',
  );
  assert.equal(pts.flags, 1, 'Fixture PTS must be valid numeric time without rounding');
  const scale = BigInt(pts.timescale);
  const numerator = value * 60n - 7395n * scale;
  const denominator = scale * 2n;
  assert.equal(numerator % denominator, 0n, 'PTS must map to an integer fixture frame');
  const frame = numerator / denominator;
  assert.ok(frame >= 0n && frame < 65536n, 'PTS outside 16-bit fixture range');
  return Number(frame);
}

/** Decode the existing top-of-image 16-bit fixture identity artifact. */
export function decodeFixtureBarcodes(bytes) {
  assert.ok(bytes.length > 0 && bytes.length % 16 === 0, 'Malformed decoded barcode artifact');
  return Array.from({ length: bytes.length / 16 }, (_, frame) => {
    let code = 0;
    for (let bit = 0; bit < 16; bit++) if (bytes[frame * 16 + bit] > 145) code |= 1 << bit;
    return code;
  });
}
function range(first, last) {
  return first <= last
    ? { firstSourceFrame: first, lastSourceFrame: last, sourceFrames: last - first + 1 }
    : null;
}

/** Offline fixture comparison, not a production loss estimator. All runtime
 * cadence uses the entire monotonic window, including startup and drain. */
export function qualifyVideoObservation({ snapshot, expectedScope, archiveIDs, liveIDs }) {
  assert.equal(snapshot.formatVersion, 1, 'Unsupported observation format');
  for (const key of ['recordingID', 'matchID', 'broadcastGeneration']) {
    assert.notEqual(expectedScope[key], undefined, `Missing expected scope ${key}`);
    assert.equal(snapshot.scope[key], expectedScope[key], `Observation scope ${key} mismatch`);
  }
  assert.match(
    snapshot.scope.publishingAttemptID,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    'Publishing attempt must be a fresh UUID',
  );
  assert.equal(snapshot.scope.appliedProfileRevision, '1', 'Expected fixed profile revision 1');
  assert.equal(snapshot.isClosed, true, 'Observation owner must be closed');
  assert.equal(snapshot.invalidity, 0, 'Owner invalidity');
  assert.equal(
    count(snapshot.rejectedClockOperationCount, 'rejected clock count'),
    0,
    'Rejected clock operations',
  );
  assert.equal(
    count(snapshot.omittedCompletedWindowCount, 'evicted history count'),
    0,
    'Observation history was evicted',
  );
  assert.equal(snapshot.omittedThroughMonotonicTime, null, 'Observation history was evicted');
  assert.equal(snapshot.windowDuration, 5, 'Expected production five-second windows');
  const anchor = finite(snapshot.monotonicAnchor, 'anchor');
  assert.ok(anchor >= 0 && anchor <= 1e12, 'Invalid monotonic anchor');
  const closedAt = finite(snapshot.current.monotonicEnd, 'closed window end');
  const captureDetachedAt = finite(snapshot.captureDetachedAt, 'capture detach time');
  assert.ok(
    captureDetachedAt >= anchor && captureDetachedAt <= closedAt,
    'Capture detach must lie within the closed owner interval',
  );
  // First observation time persists across window rotation. Encoder startup may
  // cross several windows; no such interval is a fully active steady window.
  const fullyActiveAt = Math.max(
    finite(snapshot.current.captureVideo.firstObservationTime, 'first capture observation'),
    finite(snapshot.current.encodedVideo.firstObservationTime, 'first encoded observation'),
  );
  assert.ok(
    Array.isArray(snapshot.completed) && snapshot.completed.length <= 8,
    'Bounded completed history required',
  );
  assert.ok(
    archiveIDs.length > 0 && archiveIDs.length <= 65536,
    'Bounded archive identities required',
  );
  archiveIDs.forEach((id, i) =>
    assert.equal(id, i, 'Complete archive must contain contiguous fixture identities from zero'),
  );
  assert.ok(
    liveIDs.length > 0 && liveIDs.length <= archiveIDs.length,
    'Bounded decoded live identities required',
  );
  liveIDs.forEach((id, i) => {
    assert.ok(
      Number.isInteger(id) && id >= 0 && id <= archiveIDs.at(-1),
      'Decoded live frame outside archive',
    );
    if (i) assert.ok(id > liveIDs[i - 1], 'Duplicate or reordered decoded live identity');
  });
  const liveSet = new Set(liveIDs);
  const totals = { captureVideo: 0, encodedVideo: 0 };
  const observedRanges = { captureVideo: null, encodedVideo: null };
  const aligned = [];
  const uncomparedWindows = [];
  let previousEnd = anchor;
  let stable = 0;
  const windows = [...snapshot.completed, snapshot.current].map((window, index) => {
    const terminal = index === snapshot.completed.length;
    const start = finite(window.monotonicStart, 'window start');
    const end = finite(window.monotonicEnd, 'window end');
    const scheduled = finite(window.scheduledMonotonicEnd, 'scheduled window end');
    assert.equal(start, previousEnd, 'Monotonic windows must be contiguous from owner anchor');
    assert.ok(end >= start && end <= 1e12, 'Invalid monotonic interval');
    const covered = count(window.coveredWindowCount, 'covered window count');
    assert.ok(covered >= 1, 'Window must cover at least one interval');
    assert.equal(scheduled, start + 5 * covered, 'Scheduled full window duration mismatch');
    assert.equal(window.isPartial, terminal, 'Only terminal window may be partial');
    assert.equal(
      window.isClosed,
      terminal,
      'Terminal window must be closed; completed windows retain closure state',
    );
    assert.ok(typeof window.isCoalescedEmptyGap === 'boolean', 'Missing gap flag');
    if (!terminal) assert.equal(end, scheduled, 'Completed full window duration mismatch');
    else
      assert.ok(
        end < scheduled && covered === 1 && !window.isCoalescedEmptyGap,
        'Invalid terminal partial interval',
      );
    previousEnd = end;
    const durationSeconds = end - start;
    const result = {
      index,
      monotonicStart: start,
      monotonicEnd: end,
      durationSeconds,
      scheduledMonotonicEnd: scheduled,
      coveredWindowCount: covered,
      isCoalescedEmptyGap: window.isCoalescedEmptyGap,
      isPartial: terminal,
      isClosed: window.isClosed,
      phase: terminal
        ? 'finalPartial'
        : end <= fullyActiveAt
          ? 'beforeBothStagesActive'
          : start < fullyActiveAt
            ? 'startupTransition'
            : end <= captureDetachedAt
              ? 'steady'
              : start < captureDetachedAt
                ? 'captureDetachTransition'
                : 'afterCaptureDetach',
    };
    for (const stage of ['captureVideo', 'encodedVideo']) {
      const aggregate = window[stage];
      assert.equal(aggregate.invalidity, 0, `${stage} invalidity`);
      const callbacks = count(aggregate.callbackCount, `${stage} callback count`);
      assert.equal(
        callbacks,
        count(aggregate.advancingSourcePTSCount, `${stage} advancing count`),
        `${stage} count must equal advancing count`,
      );
      for (const key of [
        'duplicateSourcePTSCount',
        'reorderedSourcePTSCount',
        'invalidSourcePTSCount',
        'discontinuousSourcePTSCount',
      ])
        assert.equal(count(aggregate[key], `${stage} ${key}`), 0, `${stage} ${key} must be zero`);
      for (const key of ['firstObservationTime', 'lastObservationTime']) {
        if (aggregate[key] !== null) {
          const time = finite(aggregate[key], key);
          assert.ok(time >= anchor && time <= end, `${key} outside owner interval`);
        }
      }
      let sourceRange = null;
      if (callbacks) {
        assert.ok(durationSeconds > 0, 'Nonempty window must have duration');
        const first = fixtureFrameID(aggregate.firstSourcePTS),
          last = fixtureFrameID(aggregate.lastSourcePTS);
        assert.equal(
          fixtureFrameID(aggregate.highWaterSourcePTS),
          last,
          `${stage} high water mismatch`,
        );
        assert.equal(
          last - first + 1,
          callbacks,
          `${stage} count differs from contiguous fixture PTS span`,
        );
        assert.ok(
          first <= last && last <= archiveIDs.at(-1),
          `${stage} PTS bounds outside archive`,
        );
        assert.ok(
          aggregate.firstObservationTime !== null && aggregate.lastObservationTime !== null,
          'Missing observation times',
        );
        assert.ok(
          aggregate.firstObservationTime <= aggregate.lastObservationTime &&
            aggregate.lastObservationTime >= start,
          'Observation time outside nonempty window',
        );
        const prior = observedRanges[stage];
        if (prior)
          assert.equal(
            first,
            prior.lastSourceFrame + 1,
            `${stage} counts omit fixture source identities between windows`,
          );
        observedRanges[stage] = range(prior?.firstSourceFrame ?? first, last);
        sourceRange = range(first, last);
      } else {
        assert.equal(aggregate.firstSourcePTS, null, 'Empty window has first PTS');
        assert.equal(aggregate.lastSourcePTS, null, 'Empty window has last PTS');
        if (aggregate.highWaterSourcePTS !== null) fixtureFrameID(aggregate.highWaterSourcePTS);
      }
      if (window.isCoalescedEmptyGap) assert.equal(callbacks, 0, 'Coalesced gap must be empty');
      totals[stage] += callbacks;
      result[stage] = {
        callbackCount: callbacks,
        advancingSourcePTSCount: callbacks,
        fps: durationSeconds ? callbacks / durationSeconds : null,
        sourceRange,
        firstObservationTime: aggregate.firstObservationTime,
        lastObservationTime: aggregate.lastObservationTime,
      };
    }
    if (result.phase === 'steady') {
      for (const stage of ['captureVideo', 'encodedVideo'])
        assert.ok(result[stage].fps >= 24, `${stage} steady full window fell below 24 fps`);
      stable++;
    }
    const encoded = result.encodedVideo;
    if (
      encoded.sourceRange &&
      encoded.sourceRange.firstSourceFrame >= liveIDs[0] &&
      encoded.sourceRange.lastSourceFrame <= liveIDs.at(-1)
    ) {
      const { firstSourceFrame, lastSourceFrame } = encoded.sourceRange;
      let decodedCount = 0;
      for (let id = firstSourceFrame; id <= lastSourceFrame; id++)
        if (liveSet.has(id)) decodedCount++;
      assert.equal(
        decodedCount,
        encoded.callbackCount,
        'Aligned decoded live identities differ from local encoded count',
      );
      aligned.push({
        index,
        ...encoded.sourceRange,
        localEncodedCount: encoded.callbackCount,
        decodedCount,
      });
    } else
      uncomparedWindows.push({
        index,
        sourceRange: encoded.sourceRange,
        reason: encoded.sourceRange ? 'outside decoded live range' : 'no encoded callbacks',
      });
    return result;
  });
  assert.ok(stable >= 2, 'Qualification requires at least two stable completed windows');
  assert.ok(aligned.length >= 1, 'Qualification requires at least one aligned encoded window');
  const capture = observedRanges.captureVideo,
    encoded = observedRanges.encodedVideo;
  assert.ok(
    capture &&
      encoded &&
      encoded.firstSourceFrame >= capture.firstSourceFrame &&
      encoded.lastSourceFrame <= capture.lastSourceFrame,
    'Encoded bounds must belong to observed capture range',
  );
  return {
    formatVersion: 1,
    scope: snapshot.scope,
    monotonicAnchor: anchor,
    fullyActiveAt,
    captureDetachedAt,
    isClosed: true,
    totals,
    sourceRanges: observedRanges,
    stableCompletedWindowCount: stable,
    windows,
    alignedComparison: {
      method: 'Known fixture source PTS bounds wholly covered by decoded live range',
      windows: aligned,
    },
    uncompared: {
      windows: uncomparedWindows,
      acquisition: range(
        encoded.firstSourceFrame,
        Math.min(encoded.lastSourceFrame, liveIDs[0] - 1),
      ),
      encodedTail: range(
        Math.max(encoded.firstSourceFrame, liveIDs.at(-1) + 1),
        encoded.lastSourceFrame,
      ),
      archiveBeforeObservation: range(0, capture.firstSourceFrame - 1),
      archiveAfterObservation: range(capture.lastSourceFrame + 1, archiveIDs.at(-1)),
    },
  };
}
