import assert from 'node:assert/strict';
import { nativeMediaGeometry } from './native-live-profile.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
const rates = { '240p30': 350000, '360p30': 600000, '540p30': 1500000, '1080p30': 6000000 };
export function nativeCandidateProfile({
  environment,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds,
  liveProfile,
}) {
  const profile = environment.SCOREBUG_TEST_CANDIDATE_PROFILE;
  if (profile === undefined) return null;
  assert.ok(
    Object.hasOwn(rates, profile) &&
      Object.hasOwn(rates, liveProfile) &&
      rates[profile] > rates[liveProfile] &&
      environment.SCOREBUG_TEST_LIVE_PROFILE === liveProfile &&
      streaming &&
      requireProcessing &&
      requirePublication &&
      Number.isSafeInteger(holdSeconds) &&
      holdSeconds >= 90 &&
      holdSeconds <= 600 &&
      environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16' &&
      environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1' &&
      [
        'SCOREBUG_TEST_NATIVE_QUALITY',
        'SCOREBUG_TEST_NATIVE_CONFIRMATION',
        'SCOREBUG_TEST_ADAPTIVE_PROFILES',
        'SCOREBUG_TEST_PROFILE_TRANSITIONS',
        'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
        'SCOREBUG_TEST_BANDWIDTH_PROBE',
        'SCOREBUG_TEST_UPLINK_PROXY_PORT',
        'SCOREBUG_TEST_DECODER_STALL',
      ].every((key) => environment[key] === undefined),
    'Candidate sampling requires exclusive full-pipeline fixed-profile structured-motion qualification',
  );
  return profile;
}
const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e12;
const uuid = (s) =>
  typeof s === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(s);
/** Measures actual pre-mux video payload only. Does not assert candidate pixel
 * quality, available network capacity, audio/mux costs or physical-device safety. */
export function qualifyNativeCandidateMeasurement(proof, { scope, profile, liveProfile, format }) {
  assert.equal(proof.formatVersion, 1);
  assert.equal(proof.isClosed, true);
  assert.equal(proof.invalidReason, null);
  assert.deepEqual(proof.scope, scope);
  assert.deepEqual(format.scope, scope);
  assert.ok(uuid(scope.publishingAttemptID));
  assert.equal(proof.liveProfile, liveProfile);
  assert.ok(rates[profile] > rates[liveProfile]);
  const geometry = nativeMediaGeometry(profile, true),
    live = nativeMediaGeometry(liveProfile, true);
  assert.equal(format.width, live.width);
  assert.equal(format.height, live.height);
  const m = proof.measurement,
    e = m.encoding;
  assert.deepEqual(m.scope, scope);
  assert.equal(m.profile, profile);
  assert.ok(uuid(m.id));
  assert.equal(m.reason, 'completed');
  assert.equal(e.outcome, 'completed');
  assert.equal(e.failure, null);
  assert.equal(e.nativeFailure, null);
  assert.equal(e.id, m.id);
  assert.ok(uuid(e.encoderSessionID));
  assert.deepEqual(e.requested, {
    width: geometry.width,
    height: geometry.height,
    bitRate: rates[profile],
    profileLevel: 'H264_High_AutoLevel',
    expectedFrameRate: 30,
    maxKeyFrameIntervalDuration: 2,
    allowFrameReordering: false,
  });
  for (const n of [proof.publisherStartedAt, proof.closedAt, m.startedAt, m.endedAt])
    assert.ok(finite(n));
  assert.ok(
    m.startedAt >= proof.publisherStartedAt &&
      m.endedAt >= m.startedAt &&
      proof.closedAt >= m.endedAt,
  );
  assert.ok(Array.isArray(e.frames) && e.frames.length === 121);
  assert.equal(m.acceptedInputCount, 121);
  assert.equal(e.acceptedInputCount, 121);
  assert.equal(e.outputCount, 121);
  const firstFrame = fixtureFrameID(m.firstInputPTS),
    lastFrame = fixtureFrameID(m.lastInputPTS);
  assert.equal(lastFrame - firstFrame, 120);
  assert.ok(firstFrame >= format.firstFrame && lastFrame <= format.lastFrame);
  let outstanding = [];
  let bytes = 0,
    previous,
    maximumFrameBytes = 0,
    maximumLatency = 0;
  for (const [index, f] of e.frames.entries()) {
    assert.equal(fixtureFrameID(f.sourcePTS), firstFrame + index);
    assert.equal(fixtureFrameID(f.outputPTS), firstFrame + index);
    assert.equal(f.encoderSessionID, e.encoderSessionID);
    assert.equal(f.width, geometry.width);
    assert.equal(f.height, geometry.height);
    assert.ok(
      Number.isSafeInteger(f.byteCount) && f.byteCount > 0 && f.byteCount <= 2 * 1024 * 1024,
    );
    assert.equal(typeof f.isSync, 'boolean');
    if (index === 0) assert.equal(f.isSync, true);
    for (const at of [f.submittedAt, f.completedAt, f.dequeuedAt]) assert.ok(finite(at));
    assert.ok(
      f.submittedAt >= m.startedAt &&
        f.submittedAt < m.startedAt + 5 &&
        f.completedAt >= f.submittedAt &&
        f.dequeuedAt >= f.completedAt &&
        f.dequeuedAt <= m.endedAt,
    );
    if (previous)
      assert.ok(f.submittedAt > previous.submittedAt && f.dequeuedAt >= previous.dequeuedAt);
    // SDK bounds include queued/native work until output dequeue. Even without
    // raw admission timestamps, native submissions cannot exceed that bound.
    outstanding = outstanding.filter((end) => end > f.submittedAt);
    outstanding.push(f.dequeuedAt);
    assert.ok(outstanding.length <= 4, 'Impossible unresolved candidate input count');
    previous = f;
    bytes += f.byteCount;
    maximumFrameBytes = Math.max(maximumFrameBytes, f.byteCount);
    maximumLatency = Math.max(maximumLatency, f.dequeuedAt - f.submittedAt);
  }
  const submissionDuration = e.frames.at(-1).submittedAt - e.frames[0].submittedAt;
  assert.ok(submissionDuration > 0 && 120 / submissionDuration >= 24 && maximumLatency <= 1.5);
  assert.ok(bytes <= 121 * 2 * 1024 * 1024);
  for (const p of [proof.pressureBaseline, proof.pressureFinal]) {
    assert.ok(
      finite(p.observedAt) &&
        finite(p.sampledAt) &&
        p.observedAt >= p.sampledAt &&
        p.observedAt - p.sampledAt <= 2,
    );
    assert.ok([0, 1].includes(p.thermal));
    assert.equal(p.publishing, true);
    assert.ok(
      Number.isSafeInteger(p.dropped) &&
        p.dropped >= 0 &&
        Number.isSafeInteger(p.rejected) &&
        p.rejected >= 0,
    );
  }
  const baseline = proof.pressureBaseline,
    final = proof.pressureFinal;
  assert.ok(
    baseline.observedAt >= proof.publisherStartedAt &&
      baseline.observedAt <= m.startedAt &&
      m.startedAt - baseline.observedAt <= 0.5,
  );
  assert.ok(
    final.observedAt >= m.endedAt &&
      final.observedAt <= proof.closedAt &&
      final.observedAt - m.endedAt <= 0.5,
  );
  assert.equal(final.dropped, baseline.dropped);
  assert.equal(final.rejected, baseline.rejected);
  assert.ok(
    Number.isSafeInteger(proof.pressurePolls) &&
      proof.pressurePolls > 0 &&
      proof.pressurePolls <= 50,
  );
  assert.ok(
    [0, 1].includes(proof.maximumThermal) &&
      proof.maximumThermal >= Math.max(baseline.thermal, final.thermal),
  );
  return {
    profile,
    liveProfile,
    scope,
    id: m.id,
    encoderSessionID: e.encoderSessionID,
    frames: 121,
    firstFrame,
    lastFrame,
    sourceDuration: 4,
    sourceFPS: 30,
    submissionDuration,
    bytes,
    maximumFrameBytes,
    maximumLatency,
    payloadBitsPerSecond: (bytes * 8) / Math.min(4, submissionDuration),
  };
}
