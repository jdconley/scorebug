import { nativeMeasuredFileSource } from './native-file-fixture.mjs';
import assert from 'node:assert/strict';
import { nativeMediaGeometry } from './native-live-profile.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
import { qualifyCandidateAVTransport } from './candidate-av-window.mjs';
import { nativeCandidateHeadroom } from './native-candidate-headroom.mjs';
import { nativeMeasuredTrial } from './native-measured-trial.mjs';
const rates = { '240p30': 350000, '360p30': 600000, '540p30': 1500000, '1080p30': 6000000 };
export function nativeCandidateProfile({
  environment,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds,
  liveProfile,
}) {
  if (
    environment.SCOREBUG_TEST_BANDWIDTH_PROBE === 'repeated' ||
    environment.SCOREBUG_TEST_MEASURED_RECOVERY === 'repeated'
  )
    assert.equal(
      nativeMeasuredTrial({
        environment,
        streaming,
        requireProcessing,
        requirePublication,
        holdSeconds,
        liveProfile,
      }),
      true,
    );
  const combined = nativeCandidateHeadroom(environment);
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
      (environment.SCOREBUG_TEST_FILE_INPUT !== undefined
        ? nativeMeasuredFileSource(environment)
        : environment.SCOREBUG_TEST_MOTION_FIXTURE === 'blocks16') &&
      environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1' &&
      (combined || environment.SCOREBUG_TEST_BANDWIDTH_PROBE === undefined) &&
      [
        'SCOREBUG_TEST_NATIVE_QUALITY',
        'SCOREBUG_TEST_NATIVE_CONFIRMATION',
        'SCOREBUG_TEST_ADAPTIVE_PROFILES',
        'SCOREBUG_TEST_PROFILE_TRANSITIONS',
        'SCOREBUG_TEST_SOURCE_CADENCE_PACING',
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
const candidateResourceLimits = Object.freeze({
  rawQueueCount: 4,
  unresolvedInputCount: 16,
  unresolvedRawBytes: 64 * 1024 * 1024,
  rawBytesPerInput: 16 * 1024 * 1024,
});
/** v1/v2 measure video only; v3 also replays complete A/V transport payload cost.
 * Neither asserts decoded candidate quality, spare capacity or device safety. */
export function qualifyNativeCandidateMeasurement(
  proof,
  { scope, profile, liveProfile, format, requiredFormatVersion = 1 },
) {
  assert.ok([1, 2, 3].includes(requiredFormatVersion));
  assert.equal(proof.formatVersion, requiredFormatVersion);
  const resources = proof.formatVersion >= 2;
  if (resources) assert.deepEqual(proof.resourceLimits, candidateResourceLimits);
  assert.equal(proof.isClosed, true);
  assert.equal(proof.invalidReason, null);
  assert.deepEqual(proof.scope, scope);
  assert.deepEqual(format.scope, scope);
  assert.ok(uuid(scope.publishingAttemptID));
  assert.equal(proof.liveProfile, liveProfile);
  assert.ok(rates[profile] > rates[liveProfile]);
  const live = nativeMediaGeometry(liveProfile, true);
  assert.equal(format.width, live.width);
  assert.equal(format.height, live.height);
  const m = proof.measurement;
  const cost = replayCandidateEncoding(m, {
    scope,
    profile,
    liveProfile,
    startedNotBefore: proof.publisherStartedAt,
    endedNotAfter: proof.closedAt,
    baselineFirstFrame: format.firstFrame,
    baselineLastFrame: format.lastFrame,
    resources,
  });
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
    ...(proof.formatVersion === 3
      ? {
          transport: replayCandidateTransport(m, {
            scope,
            profile,
            publishingGeneration: format.publishingGeneration,
          }),
        }
      : {}),
    ...cost,
  };
}

/** Replays original candidate encoding, raw resource lifetimes and A/V cost.
 * Expected bindings come from the caller's independently validated owner/source
 * history; resourceLimits are the pinned SDK contract, not observed telemetry.
 * Session checks establish internal consistency and exclude the live encoder;
 * this does not independently establish candidate session provenance.
 * Returns structural/cost evidence only: no pressure, admission, decoded quality,
 * capacity or recovery qualification. Whole-history joins remain the caller's job.
 */
export function qualifyRawNativeCandidateMeasurement(measurement, expected) {
  assert.deepEqual(
    Object.keys(expected).sort(),
    [
      'scope',
      'profile',
      'liveProfile',
      'publishingGeneration',
      'measurementID',
      'baselineEncoderSessionID',
      'startedNotBefore',
      'endedNotAfter',
      'baselineFirstFrame',
      'baselineLastFrame',
      'resourceLimits',
    ].sort(),
  );
  const {
    scope,
    profile,
    liveProfile,
    measurementID,
    baselineEncoderSessionID,
    startedNotBefore,
    endedNotAfter,
    baselineFirstFrame,
    baselineLastFrame,
    resourceLimits,
  } = expected;
  assert.ok(uuid(scope.publishingAttemptID));
  assert.ok(rates[profile] > rates[liveProfile]);
  assert.ok(uuid(measurementID));
  assert.ok(uuid(measurement.id));
  assert.equal(measurement.id.toLowerCase(), measurementID.toLowerCase());
  assert.ok(uuid(baselineEncoderSessionID));
  assert.ok(uuid(measurement.encoding.encoderSessionID));
  assert.notEqual(
    measurement.encoding.encoderSessionID.toLowerCase(),
    baselineEncoderSessionID.toLowerCase(),
  );
  assert.ok(finite(startedNotBefore) && finite(endedNotAfter) && endedNotAfter >= startedNotBefore);
  for (const frame of [baselineFirstFrame, baselineLastFrame])
    assert.ok(Number.isSafeInteger(frame) && frame >= 0 && frame <= 65535);
  assert.ok(baselineLastFrame >= baselineFirstFrame);
  assert.deepEqual(resourceLimits, candidateResourceLimits);
  const cost = replayCandidateEncoding(measurement, { ...expected, resources: true });
  return { transport: replayCandidateTransport(measurement, expected), ...cost };
}

function replayCandidateTransport(m, { scope, profile, publishingGeneration }) {
  return qualifyCandidateAVTransport(m.transport, {
    scope,
    profile,
    id: m.id,
    publishingGeneration,
    frames: m.encoding.frames,
    firstInputPTS: m.firstInputPTS,
    lastInputPTS: m.lastInputPTS,
    acceptedInputCount: m.acceptedInputCount,
    startedAt: m.startedAt,
    endedAt: m.endedAt,
  });
}

function replayCandidateEncoding(
  measurement,
  {
    scope,
    profile,
    liveProfile,
    startedNotBefore,
    endedNotAfter,
    baselineFirstFrame,
    baselineLastFrame,
    resources,
  },
) {
  const m = measurement,
    e = m.encoding;
  const geometry = nativeMediaGeometry(profile, true);
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
  for (const n of [startedNotBefore, endedNotAfter, m.startedAt, m.endedAt]) assert.ok(finite(n));
  assert.ok(
    m.startedAt >= startedNotBefore && m.endedAt >= m.startedAt && endedNotAfter >= m.endedAt,
  );
  assert.ok(Array.isArray(e.frames) && e.frames.length === 121);
  assert.equal(m.acceptedInputCount, 121);
  assert.equal(e.acceptedInputCount, 121);
  assert.equal(e.outputCount, 121);
  const firstFrame = fixtureFrameID(m.firstInputPTS),
    lastFrame = fixtureFrameID(m.lastInputPTS);
  assert.equal(lastFrame - firstFrame, 120);
  assert.ok(firstFrame >= baselineFirstFrame && lastFrame <= baselineLastFrame);
  let outstanding = [];
  const resourceEvents = [];
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
    if (!resources)
      assert.ok(outstanding.length <= 4, 'Impossible unresolved candidate input count');
    if (resources) {
      assert.ok(
        finite(f.admittedAt) && f.admittedAt >= m.startedAt && f.admittedAt <= f.submittedAt,
        'Raw admission must precede native submission within the current measurement',
      );
      if (previous) assert.ok(f.admittedAt > previous.admittedAt, 'Raw admissions must increase');
      assert.ok(
        Number.isSafeInteger(f.rawByteCount) &&
          f.rawByteCount > 0 &&
          f.rawByteCount <= 16 * 1024 * 1024,
        'Missing or invalid actual raw input byte count',
      );
      if (f.dequeuedAt > f.admittedAt) {
        resourceEvents.push({ at: f.admittedAt, count: 1, bytes: f.rawByteCount });
        resourceEvents.push({ at: f.dequeuedAt, count: -1, bytes: -f.rawByteCount });
      }
    }
    previous = f;
    bytes += f.byteCount;
    maximumFrameBytes = Math.max(maximumFrameBytes, f.byteCount);
    maximumLatency = Math.max(maximumLatency, f.dequeuedAt - f.submittedAt);
  }
  let maximumUnresolvedInputs = 0,
    maximumUnresolvedRawBytes = 0;
  if (resources) {
    resourceEvents.sort((a, b) => a.at - b.at || a.count - b.count);
    let count = 0,
      bytes = 0;
    for (const event of resourceEvents) {
      count += event.count;
      bytes += event.bytes;
      assert.ok(count >= 0 && count <= 16, 'Impossible unresolved candidate input count');
      assert.ok(
        bytes >= 0 && bytes <= 64 * 1024 * 1024,
        'Impossible unresolved candidate raw bytes',
      );
      maximumUnresolvedInputs = Math.max(maximumUnresolvedInputs, count);
      maximumUnresolvedRawBytes = Math.max(maximumUnresolvedRawBytes, bytes);
    }
    assert.equal(count, 0);
    assert.equal(bytes, 0);
  }
  const submissionDuration = e.frames.at(-1).submittedAt - e.frames[0].submittedAt;
  assert.ok(submissionDuration > 0 && 120 / submissionDuration >= 24 && maximumLatency <= 1.5);
  assert.ok(bytes <= 121 * 2 * 1024 * 1024);
  return {
    ...(resources ? { maximumUnresolvedInputs, maximumUnresolvedRawBytes } : {}),
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
