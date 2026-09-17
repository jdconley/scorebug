import assert from 'node:assert/strict';
import test from 'node:test';
import {
  nativeCandidateProfile,
  qualifyNativeCandidateMeasurement,
} from '../native-candidate-measurement.mjs';
const uuid = '00000000-0000-4000-8000-000000000001';
const scope = {
  recordingID: 'recording',
  matchID: 'match',
  broadcastGeneration: 1,
  publishingAttemptID: uuid,
  appliedProfileRevision: '1',
};
const pts = (frame) => ({ value: String(7395 + frame * 2), timescale: 60, epoch: '0', flags: 1 });
function fixture() {
  const pressure = (at) => ({
    observedAt: at,
    sampledAt: at - 0.1,
    thermal: 0,
    dropped: 0,
    rejected: 0,
    publishing: true,
  });
  const frames = Array.from({ length: 121 }, (_, i) => ({
    sourcePTS: pts(600 + i),
    outputPTS: pts(600 + i),
    encoderSessionID: uuid,
    submittedAt: 120 + i / 30,
    completedAt: 120 + i / 30 + 0.01,
    dequeuedAt: 120 + i / 30 + 0.02,
    byteCount: i === 0 ? 8000 : 1000,
    width: 960,
    height: 540,
    isSync: i % 60 === 0,
  }));
  return {
    formatVersion: 1,
    isClosed: true,
    scope,
    liveProfile: '240p30',
    publisherStartedAt: 100,
    closedAt: 180,
    invalidReason: null,
    pressureBaseline: pressure(119.99),
    pressureFinal: pressure(124.03),
    pressurePolls: 41,
    maximumThermal: 0,
    measurement: {
      id: uuid,
      scope,
      profile: '540p30',
      reason: 'completed',
      startedAt: 119.99,
      endedAt: 124.02,
      acceptedInputCount: 121,
      firstInputPTS: pts(600),
      lastInputPTS: pts(720),
      encoding: {
        id: uuid,
        outcome: 'completed',
        failure: null,
        nativeFailure: null,
        encoderSessionID: uuid,
        acceptedInputCount: 121,
        outputCount: 121,
        requested: {
          width: 960,
          height: 540,
          bitRate: 1500000,
          profileLevel: 'H264_High_AutoLevel',
          expectedFrameRate: 30,
          maxKeyFrameIntervalDuration: 2,
          allowFrameReordering: false,
        },
        frames,
      },
    },
  };
}
const expected = {
  scope,
  profile: '540p30',
  liveProfile: '240p30',
  format: { scope, width: 426, height: 240, firstFrame: 0, lastFrame: 2000 },
};
test('candidate fixture rejects implicit or conflicting options', () => {
  assert.equal(nativeCandidateProfile({ environment: {} }), null);
  const options = {
    environment: {
      SCOREBUG_TEST_CANDIDATE_PROFILE: '540p30',
      SCOREBUG_TEST_LIVE_PROFILE: '240p30',
      SCOREBUG_TEST_MOTION_FIXTURE: 'blocks16',
      SCOREBUG_TEST_DIRECT_RTMP_RECORDER: '1',
    },
    streaming: true,
    requireProcessing: true,
    requirePublication: true,
    holdSeconds: 90,
    liveProfile: '240p30',
  };
  assert.equal(nativeCandidateProfile(options), '540p30');
  for (const patch of [
    { SCOREBUG_TEST_CANDIDATE_PROFILE: '' },
    { SCOREBUG_TEST_CANDIDATE_PROFILE: '240p30' },
    { SCOREBUG_TEST_BANDWIDTH_PROBE: 'staged' },
    { SCOREBUG_TEST_ADAPTIVE_PROFILES: '1' },
    { SCOREBUG_TEST_UPLINK_PROXY_PORT: '1234' },
  ])
    assert.throws(() =>
      nativeCandidateProfile({ ...options, environment: { ...options.environment, ...patch } }),
    );
  for (const patch of [
    { holdSeconds: 89 },
    { streaming: false },
    { requirePublication: false },
    { liveProfile: '1080p30' },
  ])
    assert.throws(() => nativeCandidateProfile({ ...options, ...patch }));
});
test('reconstructs actual candidate bytes including startup keyframe', () => {
  const result = qualifyNativeCandidateMeasurement(fixture(), expected);
  assert.equal(result.frames, 121);
  assert.equal(result.sourceDuration, 4);
  assert.equal(result.bytes, 128000);
  assert.equal(result.sourceFPS, 30);
  assert.equal(result.firstFrame, 600);
  assert.equal(result.lastFrame, 720);
});
test('rejects incomplete contradictory or stale candidate evidence', () => {
  for (const mutate of [
    (p) => (p.isClosed = false),
    (p) => (p.invalidReason = 'ownerChanged'),
    (p) => (p.scope = { ...scope, recordingID: 'old' }),
    (p) => (p.measurement.scope = { ...scope, appliedProfileRevision: '2' }),
    (p) => (p.measurement.reason = 'pressure'),
    (p) => (p.measurement.encoding.outcome = 'failed'),
    (p) => (p.measurement.encoding.nativeFailure = 'failed'),
    (p) => (p.measurement.acceptedInputCount = 120),
    (p) => (p.measurement.encoding.outputCount = 120),
    (p) => (p.measurement.encoding.id = 'bad'),
    (p) => (p.measurement.encoding.frames[0].isSync = false),
    (p) => (p.measurement.encoding.frames[2].outputPTS = pts(900)),
    (p) => (p.measurement.encoding.frames[2].sourcePTS = pts(601)),
    (p) => (p.measurement.encoding.frames[0].byteCount = 0),
    (p) => (p.measurement.encoding.frames[0].width = 1920),
    (p) => (p.measurement.encoding.frames[0].encoderSessionID = 'bad'),
    (p) => (p.measurement.encoding.frames[0].submittedAt = 100),
    (p) => (p.measurement.encoding.frames[0].completedAt = 126),
    (p) => (p.measurement.encoding.frames[0].dequeuedAt = 119),
    (p) => (p.measurement.encoding.requested.allowFrameReordering = true),
    (p) => (p.measurement.encoding.requested.bitRate = 350000),
    (p) => (p.pressureFinal.dropped = 1),
    (p) => (p.pressureFinal.rejected = 1),
    (p) => (p.pressureFinal.thermal = 2),
    (p) => (p.pressureFinal.sampledAt = 100),
    (p) => (p.pressureBaseline.publishing = false),
    (p) => (p.pressurePolls = 0),
    (p) => (p.pressureFinal.observedAt = 123),
    (p) => (p.maximumThermal = 2),
    (p) => (p.measurement.lastInputPTS = pts(800)),
    (p) => (p.measurement.startedAt = 118),
    (p) => (p.measurement.endedAt = 123),
  ]) {
    const p = fixture();
    mutate(p);
    assert.throws(() => qualifyNativeCandidateMeasurement(p, expected));
  }
  assert.throws(() =>
    qualifyNativeCandidateMeasurement(fixture(), {
      ...expected,
      format: { ...expected.format, firstFrame: 700 },
    }),
  );
});

test('rejects impossible outstanding native submissions', () => {
  const proof = fixture();
  for (const frame of proof.measurement.encoding.frames.slice(0, 7)) {
    frame.completedAt = 120.22;
    frame.dequeuedAt = 120.23;
  }
  assert.throws(() => qualifyNativeCandidateMeasurement(proof, expected));
});
