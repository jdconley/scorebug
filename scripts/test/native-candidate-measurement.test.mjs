import assert from 'node:assert/strict';
import test from 'node:test';
import { replayCandidateTransportCost } from '../candidate-transport-cost.mjs';
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

const limitsV2 = {
  rawQueueCount: 4,
  unresolvedInputCount: 16,
  unresolvedRawBytes: 64 * 1024 * 1024,
  rawBytesPerInput: 16 * 1024 * 1024,
};
const expectedV2 = { ...expected, requiredFormatVersion: 2 };
function fixtureV2(latency = 0.45) {
  const p = fixture();
  p.formatVersion = 2;
  p.resourceLimits = { ...limitsV2 };
  for (const f of p.measurement.encoding.frames) {
    f.admittedAt = f.submittedAt - 0.001;
    f.rawByteCount = 3114720;
    f.completedAt = f.submittedAt + latency - 0.001;
    f.dequeuedAt = f.submittedAt + latency;
  }
  p.measurement.endedAt = 124 + latency;
  p.pressureFinal.observedAt = p.measurement.endedAt + 0.01;
  p.pressureFinal.sampledAt = p.pressureFinal.observedAt - 0.1;
  return p;
}
test('v2 qualifies measured fourteen-input buffering with independent byte accounting', () => {
  const r = qualifyNativeCandidateMeasurement(fixtureV2(), expectedV2);
  assert.equal(r.maximumUnresolvedInputs, 14);
  assert.equal(r.maximumUnresolvedRawBytes, 14 * 3114720);
  assert.equal(r.bytes, 128000);
});
test('v2 allows sixteen unresolved inputs while preserving historical v1 four-input semantics', () => {
  assert.equal(
    qualifyNativeCandidateMeasurement(fixtureV2(0.51), expectedV2).maximumUnresolvedInputs,
    16,
  );
  assert.equal(qualifyNativeCandidateMeasurement(fixture(), expected).frames, 121);
  assert.throws(() => qualifyNativeCandidateMeasurement(fixture(), expectedV2));
  assert.throws(() => qualifyNativeCandidateMeasurement(fixtureV2(), expected));
});
test('v2 accounts from raw admission, including time waiting for native submission', () => {
  const p = fixtureV2(0.51);
  p.measurement.startedAt -= 0.07;
  p.pressureBaseline.observedAt -= 0.07;
  p.pressureBaseline.sampledAt -= 0.07;
  for (const f of p.measurement.encoding.frames) f.admittedAt -= 0.07;
  assert.throws(() => qualifyNativeCandidateMeasurement(p, expectedV2));
});
test('v2 releases byte credit on dequeue and permits a larger cumulative finite window', () => {
  const p = fixtureV2(0.02);
  for (const f of p.measurement.encoding.frames) f.rawByteCount = 16 * 1024 * 1024;
  const r = qualifyNativeCandidateMeasurement(p, expectedV2);
  assert.equal(r.maximumUnresolvedInputs, 1);
  assert.equal(r.maximumUnresolvedRawBytes, 16 * 1024 * 1024);
});
const resourceFaults = {
  'seventeen outstanding': (p) => {
    for (const f of p.measurement.encoding.frames) {
      f.completedAt = f.submittedAt + 0.54;
      f.dequeuedAt = f.submittedAt + 0.55;
    }
    p.measurement.endedAt = 124.55;
    p.pressureFinal.observedAt = 124.56;
    p.pressureFinal.sampledAt = 124.46;
  },
  'byte overflow below count bound': (p) => {
    for (const f of p.measurement.encoding.frames) f.rawByteCount = 5 * 1024 * 1024;
  },
  'callbacks cannot release raw credit': (p) => {
    for (const f of p.measurement.encoding.frames) {
      f.completedAt = f.submittedAt + 0.01;
      f.rawByteCount = 5 * 1024 * 1024;
    }
  },
  'missing raw byte count': (p) => {
    delete p.measurement.encoding.frames[0].rawByteCount;
  },
  'zero raw bytes': (p) => {
    p.measurement.encoding.frames[0].rawByteCount = 0;
  },
  'fractional raw bytes': (p) => {
    p.measurement.encoding.frames[0].rawByteCount = 1.5;
  },
  'oversized raw input': (p) => {
    p.measurement.encoding.frames[0].rawByteCount = 16 * 1024 * 1024 + 1;
  },
  'missing admission': (p) => {
    delete p.measurement.encoding.frames[0].admittedAt;
  },
  'nonfinite admission': (p) => {
    p.measurement.encoding.frames[0].admittedAt = Infinity;
  },
  'admission before owner': (p) => {
    p.measurement.encoding.frames[0].admittedAt = 100;
  },
  'admission after native submission': (p) => {
    p.measurement.encoding.frames[0].admittedAt = 120.1;
  },
  'out of order admission': (p) => {
    p.measurement.encoding.frames[1].admittedAt = 119.995;
  },
  'false count declaration': (p) => {
    p.resourceLimits.unresolvedInputCount = 17;
  },
  'false byte declaration': (p) => {
    p.resourceLimits.unresolvedRawBytes += 1;
  },
  'false ingress declaration': (p) => {
    p.resourceLimits.rawQueueCount = 16;
  },
  'false per input declaration': (p) => {
    p.resourceLimits.rawBytesPerInput += 1;
  },
  'missing limits': (p) => {
    delete p.resourceLimits;
  },
};
for (const [name, mutate] of Object.entries(resourceFaults))
  test(`v2 rejects ${name}`, () => {
    const p = fixtureV2();
    mutate(p);
    assert.throws(() => qualifyNativeCandidateMeasurement(p, expectedV2));
  });

test('v2 accepts the exact aggregate byte boundary independently of the sixteen-frame limit', () => {
  const p = fixtureV2(0.11);
  for (const f of p.measurement.encoding.frames) f.rawByteCount = 16 * 1024 * 1024;
  const r = qualifyNativeCandidateMeasurement(p, expectedV2);
  assert.equal(r.maximumUnresolvedInputs, 4);
  assert.equal(r.maximumUnresolvedRawBytes, 64 * 1024 * 1024);
});
test('v2 releases a prior raw reservation at an equal admission timestamp', () => {
  const p = fixtureV2(0.032);
  const frames = p.measurement.encoding.frames;
  for (let i = 0; i < frames.length - 1; i++) {
    frames[i].dequeuedAt = frames[i + 1].admittedAt;
    frames[i].completedAt = frames[i].dequeuedAt - 0.001;
  }
  assert.equal(qualifyNativeCandidateMeasurement(p, expectedV2).maximumUnresolvedInputs, 1);
});

// v3 preserves video/resource gates and adds independently replayed full A/V cost.
function fixtureV3() {
  const p = fixtureV2();
  p.formatVersion = 3;
  const m = p.measurement,
    e = m.encoding;
  const time = (n) => ({ value: String(n), timescale: 48000, epoch: '0', flags: 1 });
  const audio = Array.from({ length: 188 }, (_, i) => ({
    sourcePTS: time(6876000 + i * 1024),
    publishingGeneration: '1',
    wasEncoded: true,
    valid: true,
    observedAt: 120 + (i * 1024) / 48000,
    consumedAt: 120 + (i * 1024) / 48000 + 0.001,
    byteCount: 100,
    sampleRate: 48000,
    channelCount: 2,
    framesPerPacket: 1024,
    audioObjectType: 2,
  }));
  const followingAudio = {
    ...audio.at(-1),
    sourcePTS: time(6876000 + 188 * 1024),
    observedAt: 124.010666667,
    consumedAt: 124.010666667,
  };
  const inputs = [
    ...e.frames.map((f) => ({
      media: 'video',
      sourcePTS: f.sourcePTS,
      decodePTS: null,
      byteCount: f.byteCount,
      isSync: f.isSync,
      parameterSetBytes: f.isSync ? 34 : 0,
      _at: f.dequeuedAt,
    })),
    ...audio.map((a) => ({
      media: 'audio',
      sourcePTS: a.sourcePTS,
      decodePTS: null,
      byteCount: a.byteCount,
      isSync: true,
      parameterSetBytes: 0,
      _at: a.consumedAt,
    })),
  ]
    .sort((a, b) => a._at - b._at)
    .map(({ _at, ...input }) => input);
  const { writes, programWrites, pcrCount, ...totals } = replayCandidateTransportCost(inputs);
  m.transport = {
    scope,
    profile: m.profile,
    id: m.id,
    outcome: 'completed',
    failure: null,
    publishingGeneration: '1',
    startedAt: 119.999,
    closedAt: 124.001,
    endedAt: 124.45,
    rawInputCount: 121,
    firstRawPTS: m.firstInputPTS,
    lastRawPTS: m.lastInputPTS,
    audio,
    followingAudio,
    maximumPendingCount: 1,
    maximumPendingBytes: 100,
    mux: {
      ...totals,
      inputs,
      outcome: 'completed',
      failure: null,
      firstVideoPTS: m.firstInputPTS,
      lastVideoPTS: m.lastInputPTS,
      firstAudioPTS: audio[0].sourcePTS,
      lastAudioPTS: audio.at(-1).sourcePTS,
    },
  };
  return p;
}
const expectedV3 = {
  ...expectedV2,
  requiredFormatVersion: 3,
  format: { ...expected.format, publishingGeneration: '1' },
};
test('v3 joins live AAC and native candidate frames with full MPEG-TS cost', () => {
  const p = fixtureV3(),
    r = qualifyNativeCandidateMeasurement(p, expectedV3);
  assert.equal(r.bytes, 128000);
  assert.equal(r.transport.transportBytes, p.measurement.transport.mux.transportBytes);
  assert.equal(r.transport.audioInputCount, 188);
  assert.ok(r.transport.applicationPayloadBitsPerSecond > r.payloadBitsPerSecond);
});
test('v3 requires full fresh transport evidence while historical v1/v2 remain video-only', () => {
  for (const mutate of [
    (p) => delete p.measurement.transport,
    (p) => (p.measurement.transport.publishingGeneration = '2'),
    (p) => p.measurement.transport.mux.transportBytes++,
    (p) => (p.measurement.transport.audio[5].wasEncoded = false),
    (p) => (p.resourceLimits.rawQueueCount = 5),
  ]) {
    const p = fixtureV3();
    mutate(p);
    assert.throws(() => qualifyNativeCandidateMeasurement(p, expectedV3));
  }
  assert.equal(qualifyNativeCandidateMeasurement(fixtureV2(), expectedV2).transport, undefined);
  assert.equal(qualifyNativeCandidateMeasurement(fixture(), expected).transport, undefined);
});
