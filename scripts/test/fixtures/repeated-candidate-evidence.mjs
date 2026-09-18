import { replayCandidateTransportCost } from '../../candidate-transport-cost.mjs';

const pts = (n) => ({ value: String(7395 + 2 * n), timescale: 60, epoch: '0', flags: 1 });
const ids = [
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
];
function mediaFixture(phaseCount = 3, adaptive = false) {
  const scope = {
    recordingID: 'recording',
    matchID: 'match',
    broadcastGeneration: 1,
    publishingAttemptID: 'attempt',
    appliedProfileRevision: '1',
  };
  const indices = Array.from({ length: phaseCount }, (_, n) => n);
  const sessionIDs = indices.map(
    (n) => ids[n] ?? `${String(n + 1).padStart(8, '0')}-4444-4444-8444-444444444444`,
  );
  const phases = indices.map((n) => ({
    width: n % 2 ? 960 : 1920,
    height: n % 2 ? 540 : 1080,
    frames: 900,
    firstSourcePTS: pts(n * 900),
    lastSourcePTS: pts(n * 900 + 899),
    maximumSourceGapSeconds: 1 / 30,
    firstObservedAt: 100.01 + n * 30,
    lastObservedAt: 100.01 + n * 30 + 899 / 30,
    maximumObservationGapSeconds: 1 / 30,
  }));
  const format = {
    formatVersion: adaptive ? 3 : 2,
    scope,
    isClosed: true,
    invalid: false,
    frames: 900 * phaseCount,
    publishingGeneration: '2',
    phases,
    encoderSessions: phases.map((p, n) => ({
      encoderSessionID: sessionIDs[n],
      frames: p.frames,
      firstSourcePTS: p.firstSourcePTS,
      lastSourcePTS: p.lastSourcePTS,
      firstCompletedAt: 100 + n * 30,
      lastCompletedAt: 100 + n * 30 + 899 / 30,
      maximumCompletionGapSeconds: 1 / 30,
      maximumEncodeLatencySeconds: 0.2,
    })),
    receipts: indices.slice(1).map((n) => ({
      profile: n % 2 ? '540p30' : '1080p30',
      publishingGeneration: '2',
      previousEncoderSessionID: sessionIDs[n - 1],
      encoderSessionID: sessionIDs[n],
      lastOldSourcePTS: pts(n * 900 - 1),
      firstNewSourcePTS: pts(n * 900),
      width: phases[n].width,
      height: phases[n].height,
      rawVideoFramesDropped: '0',
      acknowledgedAt: 100 + n * 30 + 0.1,
    })),
  };
  const snapshot = {
    scope,
    isClosed: true,
    monotonicAnchor: 99,
    captureDetachedAt: 101 + 30 * phaseCount,
    omittedCompletedWindowCount: '0',
    publishingClockObservation: { publishingGeneration: '2' },
    completed: [
      {
        encodedVideo: {
          callbackCount: String(900 * phaseCount),
          firstSourcePTS: pts(0),
          lastSourcePTS: pts(900 * phaseCount - 1),
        },
      },
    ],
    current: { encodedVideo: { callbackCount: '0' } },
  };
  return {
    format,
    snapshot,
    liveIDs: Array.from({ length: 900 * phaseCount - 30 }, (_, n) => n + 30),
  };
}
function measuredFixture(phaseCount = 3) {
  const f = mediaFixture(phaseCount);
  f.format.formatVersion = 8;
  f.format.sequence = 'measured240';
  for (const [i, phase] of f.format.phases.entries()) {
    phase.width = i === 1 ? 640 : 426;
    phase.height = i === 1 ? 360 : 240;
  }
  f.format.receipts.forEach((r, i) => {
    r.profile = i === 0 ? '360p30' : '240p30';
    r.width = f.format.phases[i + 1].width;
    r.height = f.format.phases[i + 1].height;
  });
  f.format.compressedFrames = f.format.phases.flatMap((p, phase) =>
    Array.from({ length: p.frames }, (_, n) => ({
      sourcePTS: pts(phase * 900 + n),
      observedAt: p.firstObservedAt + n / 30,
      byteCount: n % 60 === 0 ? 4000 : 1000,
      isSync: n % 60 === 0,
    })),
  );
  return f;
}
function repeatedMeasuredFixture() {
  const f = measuredFixture(5);
  f.format.formatVersion = 9;
  f.format.sequence = 'repeated240';
  f.format.phases.forEach((phase, i) => {
    phase.width = i % 2 ? 640 : 426;
    phase.height = i % 2 ? 360 : 240;
  });
  f.format.receipts.forEach((receipt, i) => {
    receipt.profile = i % 2 ? '240p30' : '360p30';
    receipt.width = f.format.phases[i + 1].width;
    receipt.height = f.format.phases[i + 1].height;
  });
  return f;
}
const uuid = '00000000-0000-4000-8000-000000000001';
const scope = {
  recordingID: 'recording',
  matchID: 'match',
  broadcastGeneration: 1,
  publishingAttemptID: uuid,
  appliedProfileRevision: '1',
};
const candidatePTS = (frame) => ({
  value: String(7395 + frame * 2),
  timescale: 60,
  epoch: '0',
  flags: 1,
});
function candidateFixture() {
  const pressure = (at) => ({
    observedAt: at,
    sampledAt: at - 0.1,
    thermal: 0,
    dropped: 0,
    rejected: 0,
    publishing: true,
  });
  const frames = Array.from({ length: 121 }, (_, i) => ({
    sourcePTS: candidatePTS(600 + i),
    outputPTS: candidatePTS(600 + i),
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
      firstInputPTS: candidatePTS(600),
      lastInputPTS: candidatePTS(720),
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
const limitsV2 = {
  rawQueueCount: 4,
  unresolvedInputCount: 16,
  unresolvedRawBytes: 64 * 1024 * 1024,
  rawBytesPerInput: 16 * 1024 * 1024,
};
function fixtureV2(latency = 0.45) {
  const p = candidateFixture();
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

/** Synthetic raw exports retain the same fields as the native serializers. */
export function repeatedCandidateFixture() {
  const media = repeatedMeasuredFixture();
  const scope = { ...media.format.scope, publishingAttemptID: uuid, appliedProfileRevision: '0' };
  media.format.scope = scope;
  media.snapshot.scope = scope;
  const generation = media.format.publishingGeneration;
  const probeID = (n) => `bbbbbbbb-bbbb-4bbb-8bbb-${String(n).padStart(12, '0')}`;
  const nativeProbe = {
    formatVersion: 3,
    isClosed: true,
    invalid: false,
    mode: 'repeated',
    result: 'completed',
    scope,
    publishingGeneration: generation,
    campaigns: [1, 2].map((ordinal) => {
      const origin = 117 + (ordinal - 1) * 60;
      const events = [];
      let total = 0;
      for (let stage = 1; stage <= 3; stage++) {
        const startedAt = origin + (stage - 1) * 0.25;
        const first = {
          id: probeID(ordinal * 10 + stage),
          publishingGeneration: generation,
          campaign: String(ordinal),
          stage,
          bitRate: [500000, 2000000, 12000000][stage - 1],
          startedAt,
          campaignStartedAt: origin,
          leaseDeadline: startedAt + 0.3,
          acceptedPayloadBytes: '0',
          totalAcceptedPayloadBytes: String(total),
          lastAcceptedAt: null,
          reason: null,
        };
        events.push({
          phase: stage === 1 ? 'began' : 'replaced',
          observedAt: startedAt + 0.001,
          sample: first,
        });
        const renewals = stage === 3 ? 80 : 2;
        for (let n = 1; n <= renewals; n++) {
          const at = startedAt + n * (stage === 3 ? 0.1 : 0.09);
          events.push({
            phase: 'renewed',
            observedAt: at + 0.001,
            sample: {
              ...first,
              leaseDeadline: at + 0.3,
              acceptedPayloadBytes: String(n * 1316),
              totalAcceptedPayloadBytes: String(total + n * 1316),
              lastAcceptedAt: at - 0.01,
            },
          });
        }
        const retiredAt = startedAt + (stage === 3 ? 8.1 : 0.21);
        events.push({
          phase: 'retired',
          observedAt: retiredAt,
          retirementRequestedAt: retiredAt - 0.01,
          sample: { ...events.at(-1).sample, reason: 'cancelled' },
        });
        total += renewals * 1316;
      }
      return {
        campaign: String(ordinal),
        status: 'completed',
        isJoined: true,
        context: {
          appliedRevision: String((ordinal - 1) * 2),
          publishingGeneration: generation,
          targetProfile: '360p30',
          targetBitRate: 600000,
          baselineProfile: '240p30',
          baselineBitRate: 350000,
          encoderSessionID: media.format.encoderSessions[(ordinal - 1) * 2].encoderSessionID,
          configurationID: probeID(100 + ordinal),
          acknowledgedAt: 100 + (ordinal - 1) * 60 + 0.1,
          healthySince: origin - 10,
          healthyThrough: origin - 0.1,
          healthSequence: String(ordinal * 100),
        },
        events,
      };
    }),
  };
  const campaigns = [1, 2].map((ordinal) => {
    const measurement = fixtureV3();
    const offset = (ordinal - 1) * 60;
    function shift(value, key = '') {
      if (Array.isArray(value)) return value.map((v) => shift(v));
      if (value && typeof value === 'object') {
        if ('timescale' in value && 'value' in value)
          return {
            ...value,
            value: String(BigInt(value.value) + BigInt(offset * value.timescale)),
          };
        return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, shift(v, k)]));
      }
      if (typeof value === 'number' && key.endsWith('At')) return value + offset;
      return value;
    }
    const p = shift(measurement);
    p.scope = scope;
    p.publisherStartedAt = 100;
    p.closedAt = p.measurement.endedAt + 0.03;
    p.measurement.scope = scope;
    p.measurement.profile = '360p30';
    p.measurement.id = probeID(300 + ordinal);
    const e = p.measurement.encoding;
    e.id = p.measurement.id;
    e.encoderSessionID = probeID(400 + ordinal);
    Object.assign(e.requested, { width: 640, height: 360, bitRate: 600000 });
    for (const frame of e.frames)
      Object.assign(frame, { encoderSessionID: e.encoderSessionID, width: 640, height: 360 });
    const t = p.measurement.transport;
    Object.assign(t, {
      scope,
      profile: '360p30',
      id: p.measurement.id,
      publishingGeneration: generation,
    });
    for (const a of [...t.audio, t.followingAudio]) a.publishingGeneration = generation;
    const events = nativeProbe.campaigns[ordinal - 1].events.filter(
      (e) => e.sample.stage === 3 && e.phase === 'renewed',
    );
    const observation = (event) => {
      const { campaignStartedAt, totalAcceptedPayloadBytes, ...sample } = event.sample;
      return { ...sample, observedAt: event.observedAt };
    };
    p.probeBinding = {
      boundAt: events[6].observedAt,
      completedAt: events[69].observedAt + 0.001,
      initial: observation(events[6]),
      final: observation(events[69]),
    };
    p.closedAt = p.probeBinding.completedAt + 0.01;
    return {
      campaign: String(ordinal),
      appliedRevision: String((ordinal - 1) * 2),
      started: true,
      measurement: p,
    };
  });
  return {
    proof: { formatVersion: 4, isClosed: true, scope, maximumCampaigns: 2, campaigns },
    options: { scope, nativeProbe, ...media },
  };
}
