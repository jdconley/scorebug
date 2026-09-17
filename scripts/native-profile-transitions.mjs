import assert from 'node:assert/strict';
import { qualifyNativeCompressedFrames } from './native-compressed-frames.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';

export function nativeAdaptiveProfiles({
  environment,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds,
}) {
  const flag = environment.SCOREBUG_TEST_ADAPTIVE_PROFILES;
  if (flag === undefined) return false;
  assert.ok(
    flag === '1' &&
      streaming &&
      requireProcessing &&
      requirePublication &&
      Number.isSafeInteger(holdSeconds) &&
      holdSeconds >= 240 &&
      holdSeconds <= 600 &&
      environment.SCOREBUG_TEST_NATIVE_QUALITY === '1' &&
      environment.SCOREBUG_TEST_NATIVE_CONFIRMATION === '1' &&
      environment.SCOREBUG_TEST_UPLINK_PROFILE === 'rate4m' &&
      environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1' &&
      environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16' &&
      environment.SCOREBUG_TEST_PROFILE_TRANSITIONS === undefined &&
      environment.SCOREBUG_TEST_LIVE_PROFILE === undefined,
    'Adaptive profiles require explicit isolated rate4m quality confirmation, full-pipeline structured motion and 240–600s hold',
  );
  return true;
}

export function nativeProfileTransitions({
  environment,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds,
}) {
  const flag = environment.SCOREBUG_TEST_PROFILE_TRANSITIONS;
  if (flag === undefined) return false;
  assert.ok(
    ['1', 'low240'].includes(flag) &&
      streaming &&
      requireProcessing &&
      requirePublication &&
      Number.isSafeInteger(holdSeconds) &&
      holdSeconds >= 90 &&
      holdSeconds <= 600 &&
      environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1' &&
      environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16' &&
      environment.SCOREBUG_TEST_NATIVE_QUALITY === undefined &&
      environment.SCOREBUG_TEST_NATIVE_CONFIRMATION === undefined &&
      environment.SCOREBUG_TEST_LIVE_PROFILE === undefined &&
      environment.SCOREBUG_TEST_ADAPTIVE_PROFILES === undefined &&
      environment.SCOREBUG_TEST_UPLINK_PROFILE === undefined,
    'Profile transitions require explicit standalone structured-motion qualification, processing/publication, direct recorder and 90–600s hold',
  );
  return true;
}

export function qualifyNativeProfileTransitions(
  format,
  snapshot,
  liveIDs,
  {
    adaptive = false,
    requireFrameEvidence = false,
    requirePacingEvidence = false,
    sequence = '1',
  } = {},
) {
  assert.ok(
    !requirePacingEvidence || requireFrameEvidence,
    'Pacing requires current raw frame evidence',
  );
  assert.ok(
    ['1', 'low240', 'stall540', 'measured240'].includes(sequence),
    'Unknown transition sequence',
  );
  const measured = sequence === 'measured240';
  assert.ok(!measured || !adaptive, 'Measured trial has its own bounded sequence');
  const stallReset = sequence === 'stall540';
  assert.ok(!stallReset || !adaptive, 'Stall reset is one controlled downward transition');
  const minimum = sequence === 'low240';
  assert.ok(!minimum || !adaptive, 'Minimum sequence is a controlled experiment');
  if (minimum || stallReset || measured) assert.equal(format.sequence, sequence);
  else assert.equal(format.sequence, undefined);
  const hasFrameEvidence =
    format.formatVersion === (measured ? 8 : stallReset ? 7 : minimum ? 6 : adaptive ? 5 : 4);
  assert.ok(
    hasFrameEvidence ||
      (!minimum &&
        !measured &&
        !stallReset &&
        !requireFrameEvidence &&
        format.formatVersion === (adaptive ? 3 : 2)),
  );
  const compressedFrames = hasFrameEvidence
    ? qualifyNativeCompressedFrames(format, snapshot, { requirePacingEvidence, sequence })
    : undefined;
  assert.equal(format.isClosed, true);
  assert.equal(format.invalid, false);
  assert.equal(snapshot.isClosed, true);
  assert.deepEqual(format.scope, snapshot.scope);
  assert.equal(snapshot.omittedCompletedWindowCount, '0');
  assert.equal(
    format.publishingGeneration,
    snapshot.publishingClockObservation.publishingGeneration,
  );
  assert.match(format.publishingGeneration, /^[1-9]\d*$/);
  assert.ok(Number.isSafeInteger(format.frames) && format.frames > 0 && format.frames <= 25000);
  if (adaptive)
    assert.ok(
      format.phases.length >= 3 && format.phases.length <= 17 && format.phases.length % 2 === 1,
    );
  else if (measured) assert.ok(format.phases.length >= 1 && format.phases.length <= 3);
  else assert.equal(format.phases.length, stallReset ? 2 : 3);
  assert.equal(format.receipts.length, format.phases.length - 1);
  assert.equal(format.encoderSessions.length, format.phases.length);
  const clock = (value) =>
    assert.ok(
      Number.isFinite(value) &&
        value >= snapshot.monotonicAnchor &&
        value <= snapshot.captureDetachedAt + 2,
    );
  assert.ok(Number.isFinite(snapshot.monotonicAnchor) && snapshot.monotonicAnchor >= 0);
  assert.ok(
    Number.isFinite(snapshot.captureDetachedAt) &&
      snapshot.captureDetachedAt > snapshot.monotonicAnchor,
  );
  assert.ok(Array.isArray(liveIDs) && liveIDs.length > 0);
  liveIDs.forEach((id, n) =>
    assert.ok(Number.isSafeInteger(id) && id >= 0 && (n === 0 || id > liveIDs[n - 1])),
  );
  const rows = [...snapshot.completed, snapshot.current]
    .map((w) => w.encodedVideo)
    .filter((r) => BigInt(r.callbackCount) > 0n);
  assert.equal(
    BigInt(format.frames),
    rows.reduce((sum, r) => sum + BigInt(r.callbackCount), 0n),
    'Every encoded frame needs native format evidence',
  );
  const phases = format.phases.map((p, i) => {
    assert.equal(
      p.width,
      measured
        ? i === 1
          ? 640
          : 426
        : stallReset
          ? i === 0
            ? 960
            : 426
          : i % 2
            ? 960
            : minimum
              ? 426
              : 1920,
    );
    assert.equal(
      p.height,
      measured
        ? i === 1
          ? 360
          : 240
        : stallReset
          ? i === 0
            ? 540
            : 240
          : i % 2
            ? 540
            : minimum
              ? 240
              : 1080,
    );
    assert.ok(Number.isSafeInteger(p.frames) && p.frames > 0);
    const first = fixtureFrameID(p.firstSourcePTS),
      last = fixtureFrameID(p.lastSourcePTS);
    const encoder = format.encoderSessions[i];
    if (measured) {
      assert.match(encoder.encoderSessionID, /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i);
      assert.ok(
        !format.encoderSessions
          .slice(0, i)
          .some(
            (prior) =>
              prior.encoderSessionID.toLowerCase() === encoder.encoderSessionID.toLowerCase(),
          ),
        'Measured phases must have distinct native encoder identities',
      );
    }
    assert.equal(encoder.frames, p.frames);
    assert.equal(fixtureFrameID(encoder.firstSourcePTS), first);
    assert.equal(fixtureFrameID(encoder.lastSourcePTS), last);
    for (const at of [
      p.firstObservedAt,
      p.lastObservedAt,
      encoder.firstCompletedAt,
      encoder.lastCompletedAt,
    ])
      clock(at);
    assert.ok(
      p.lastObservedAt >= p.firstObservedAt && encoder.lastCompletedAt >= encoder.firstCompletedAt,
    );
    assert.ok(
      p.firstObservedAt >= encoder.firstCompletedAt && p.lastObservedAt >= encoder.lastCompletedAt,
    );
    for (const gap of [
      p.maximumObservationGapSeconds,
      encoder.maximumCompletionGapSeconds,
      encoder.maximumEncodeLatencySeconds,
    ]) {
      assert.ok(Number.isFinite(gap) && gap >= 0 && gap <= 1e12);
    }
    const shortTrial = adaptive && i > 0 && i % 2 === 0 && i < format.phases.length - 1;
    assert.ok(
      measured ? last >= first : last - first >= (shortTrial ? 1 : 15) * 30,
      'Insufficient native phase source coverage',
    );
    assert.ok(
      Number.isFinite(p.maximumSourceGapSeconds) &&
        (measured && p.frames === 1
          ? p.maximumSourceGapSeconds === 0
          : p.maximumSourceGapSeconds > 0) &&
        p.maximumSourceGapSeconds <= 0.5,
    );
    assert.ok(
      p.frames <= last - first + 1 && p.frames / (last - first + 1) >= 0.99,
      'Native phase loses more than one percent of source frames',
    );
    const decoded = liveIDs.filter((id) => id >= first && id <= last);
    assert.ok(decoded.length > 0);
    const acquisition = i === 0 ? decoded[0] - first : 0;
    assert.ok(acquisition >= 0 && acquisition <= 60);
    const expected = last - first + 1 - acquisition;
    assert.ok(
      decoded.length / expected >= 0.99,
      'Decoded phase loses more than one percent of source frames',
    );
    assert.equal(decoded.at(-1), last, 'Each native phase tail must arrive downstream');
    if (i > 0) assert.equal(decoded[0], first, 'First new-format frame must decode downstream');
    const freshFps = (decoded.length * 30) / expected;
    assert.ok(freshFps >= 24);
    for (let start = first + acquisition; start + 149 <= last; start += 150) {
      assert.ok(
        decoded.filter((id) => id >= start && id < start + 150).length >= 120,
        'Five-second phase cadence below 24fps',
      );
    }
    return {
      width: p.width,
      height: p.height,
      nativeFrames: p.frames,
      decodedFrames: decoded.length,
      firstFrame: first,
      lastFrame: last,
      freshFps,
      sourceLoss: 1 - decoded.length / expected,
      acquisitionFrames: acquisition,
      maximumSourceGapSeconds: p.maximumSourceGapSeconds,
      maximumCompressedOutputGapSeconds: p.maximumObservationGapSeconds,
      maximumNativeCompletionGapSeconds: encoder.maximumCompletionGapSeconds,
      maximumEncodeLatencySeconds: encoder.maximumEncodeLatencySeconds,
      encoderSessionID: encoder.encoderSessionID,
    };
  });
  assert.equal(
    phases.reduce((sum, p) => sum + p.nativeFrames, 0),
    format.frames,
  );
  assert.equal(
    phases[0].firstFrame,
    Math.min(...rows.map((r) => fixtureFrameID(r.firstSourcePTS))),
  );
  assert.equal(
    phases.at(-1).lastFrame,
    Math.max(...rows.map((r) => fixtureFrameID(r.lastSourcePTS))),
  );
  assert.ok(liveIDs[0] >= phases[0].firstFrame && liveIDs.at(-1) <= phases.at(-1).lastFrame);
  const sessions = new Set();
  const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  format.receipts.forEach((r, i) => {
    const before = phases[i],
      after = phases[i + 1];
    assert.equal(
      r.profile,
      measured
        ? i === 0
          ? '360p30'
          : '240p30'
        : stallReset
          ? '240p30'
          : i % 2 === 0
            ? '540p30'
            : minimum
              ? '240p30'
              : '1080p30',
    );
    assert.equal(r.publishingGeneration, format.publishingGeneration);
    assert.equal(
      r.previousEncoderSessionID.toLowerCase(),
      format.encoderSessions[i].encoderSessionID.toLowerCase(),
    );
    assert.equal(
      r.encoderSessionID.toLowerCase(),
      format.encoderSessions[i + 1].encoderSessionID.toLowerCase(),
    );
    clock(r.acknowledgedAt);
    assert.ok(
      r.acknowledgedAt >= format.encoderSessions[i + 1].firstCompletedAt,
      'Receipt precedes native completion',
    );
    assert.ok(
      r.acknowledgedAt >= format.phases[i + 1].firstObservedAt,
      'Receipt precedes compressed output observation',
    );
    assert.equal(r.width, after.width);
    assert.equal(r.height, after.height);
    assert.equal(fixtureFrameID(r.lastOldSourcePTS), before.lastFrame);
    assert.equal(fixtureFrameID(r.firstNewSourcePTS), after.firstFrame);
    assert.ok(
      after.firstFrame > before.lastFrame && after.firstFrame - before.lastFrame <= 15,
      'Transition source gap exceeds half a second',
    );
    assert.match(r.previousEncoderSessionID, uuid);
    assert.match(r.encoderSessionID, uuid);
    const oldID = r.previousEncoderSessionID.toLowerCase(),
      newID = r.encoderSessionID.toLowerCase();
    if (i === 0) sessions.add(oldID);
    else assert.equal(oldID, format.receipts[i - 1].encoderSessionID.toLowerCase());
    assert.ok(!sessions.has(newID), 'Replacement reuses an encoder identity');
    sessions.add(newID);
    assert.match(r.rawVideoFramesDropped, /^(0|[1-9]\d*)$/);
    assert.ok(BigInt(r.rawVideoFramesDropped) <= 25000n);
    assert.ok(
      Number.isFinite(r.acknowledgedAt) && r.acknowledgedAt >= 0 && r.acknowledgedAt <= 1e12,
    );
    if (i > 0) assert.ok(r.acknowledgedAt > format.receipts[i - 1].acknowledgedAt);
  });
  return {
    ...(minimum || stallReset || measured ? { sequence } : {}),
    ...(measured
      ? { trialConfirmed: false, mediaHealthQualified: false, upgradeAuthorized: false }
      : {}),
    ...(compressedFrames ? { compressedFrames } : {}),
    scope: format.scope,
    publishingGeneration: format.publishingGeneration,
    phases,
    receipts: format.receipts,
    transitions: format.receipts.map((_, i) => {
      const nativeCompletionGapSeconds =
        format.encoderSessions[i + 1].firstCompletedAt - format.encoderSessions[i].lastCompletedAt;
      const compressedOutputGapSeconds =
        format.phases[i + 1].firstObservedAt - format.phases[i].lastObservedAt;
      assert.ok(nativeCompletionGapSeconds >= 0 && compressedOutputGapSeconds >= 0);
      return { nativeCompletionGapSeconds, compressedOutputGapSeconds };
    }),
    note: measured
      ? 'Observed measured-trial formats only; admission, lifecycle, trial confirmation and receiver wall-clock continuity require separate qualification.'
      : stallReset
        ? 'One observed native reset; the scoped fault/controller qualification supplies causality, and receiver wall-clock continuity is not inferred.'
        : adaptive
          ? 'Adaptive native formats and saved source correspondence; pressure decisions require separate policy replay, and receiver wall-clock continuity is not inferred.'
          : 'Fixed scheduled transitions; automatic adaptation and receiver wall-clock continuity remain separate gates.',
  };
}
