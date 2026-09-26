export const pipelineReadKey = 'a'.repeat(64);
const uuid = (n) => `${String(n).padStart(8, '0')}-0000-4000-8000-000000000000`;
export function ordinary720Fixture() {
  const values = [
    ['initial-minimum', 1010, 1, 1005, 1, false, '240p30', 350000],
    ['initial-360-probation', 1055, 2, 1048, 3, true, '360p30', 600000],
    ['initial-360-confirmed', 1066, 2, 1048, 5, false, '360p30', 600000],
    ['initial-720-probation', 1100, 3, 1093, 7, true, '720p30', 3000000],
    ['initial-720-confirmed', 1111, 3, 1093, 9, false, '720p30', 3000000],
    ['fallback-acknowledged', 1125, 5, 1118, 11, false, '240p30', 350000],
    ['recovery-360-probation', 1175, 6, 1168, 21, true, '360p30', 600000],
    ['recovery-360-confirmed', 1186, 6, 1168, 23, false, '360p30', 600000],
    ['recovery-720-probation', 1220, 7, 1213, 25, true, '720p30', 3000000],
    ['recovery-720-confirmed', 1231, 7, 1213, 27, false, '720p30', 3000000],
  ];
  const samples = values.map(([phase, time, revision, ack, seq, trial, profile, bitrate]) => {
    const pts = (time - 1000) * 90000;
    const format =
      profile === '720p30' ? [1280, 720] : profile === '360p30' ? [640, 360] : [426, 240];
    const d = {
      sessionObservedAtUptimeSeconds: String(time - 0.15),
      observedAtUptimeSeconds: String(time - 0.1),
      sessionBusy: 'false',
      sessionClosed: 'false',
      driverClosed: 'false',
      policyOwnerKey: String(revision).repeat(64),
      policySourceScopeKey: 'b'.repeat(64),
      policyAttemptID: uuid(99),
      policyPipelineReadKey: pipelineReadKey,
      policyAcknowledgedAtUptimeSeconds: String(ack),
      policyAppliedRevision: String(revision),
      policyAppliedProfile: profile,
      policyAppliedBitrate: String(bitrate),
      policyTrialActive: String(trial),
      ...(trial ? { policyTrialRollbackRequired: 'false' } : {}),
      policyRecommendationPending: 'false',
      policyApplicationPending: 'false',
      policyMinimumResetRequired: 'false',
      policyAcceptedSourceSequence: String(seq),
      policyAcceptedSourceWindowEnd: String(time - 0.2),
      policyDecodedPreviousPTS: String(pts - 450000),
      policyDecodedFirstPTS: String(pts - 447000),
      policyDecodedLastPTS: String(pts),
      policyDecodedFrameCount: '150',
    };
    if (revision !== 1)
      d.appliedTransition = JSON.stringify({
        revision: String(revision),
        fromRevision: String(revision - 1),
        attemptID: uuid(99),
        kind: profile === '240p30' ? 'reset' : 'trial',
        profile,
        bitrate: String(bitrate),
        ackAt: String(ack),
        nativeAt: String(ack - 0.1),
        profileNativeAt: String(ack - 0.2),
        formatWidth: String(format[0]),
        formatHeight: String(format[1]),
        profileGeneration: '7',
        oldEncoder: uuid(revision - 1),
        newEncoder: uuid(revision),
        oldPTS: `${(ack - 1000) * 90000 - 3000}/90000`,
        newPTS: `${(ack - 1000) * 90000}/90000`,
        rateEncoder: uuid(revision),
        rateGeneration: '7',
        nativeBitrate: String(bitrate),
        ratePTS: `${(ack - 1000) * 90000 + 3000}/90000`,
      });
    return {
      phase,
      readStartedUptimeSeconds: time,
      readEndedUptimeSeconds: time + 0.1,
      diagnostic: d,
    };
  });
  const gates = [
    ['initial-minimum', 1001, 10],
    ['initial-360-increase', 1010.1, 150],
    ['initial-360-confirmation', 1055.1, 30],
    ['initial-720-increase', 1066.1, 150],
    ['initial-720-confirmation', 1100.1, 30],
    ['fallback', 1111.3, 60],
    ['recovery-360-increase', 1125.3, 150],
    ['recovery-360-confirmation', 1175.1, 30],
    ['recovery-720-increase', 1186.1, 150],
    ['recovery-720-confirmation', 1220.1, 30],
  ].map(([phase, startedUptimeSeconds, limitSeconds]) => ({
    phase,
    startedUptimeSeconds,
    limitSeconds,
  }));
  const exchanges = [
    ['constrain', 1111.2, 80000, 750000, 'constrained', 20],
    ['restore', 1125.2, 94000, null, 'restored', 500],
  ].map(([operation, t, appliedAt, rateBitsPerSecond, phase, forwardOperationOrdinal], i) => ({
    sequence: i + 1,
    operation,
    requestStartedUptimeSeconds: t,
    responseEndedUptimeSeconds: t + 0.1,
    response: {
      runID: 'run',
      sequence: i + 1,
      phase,
      rateBitsPerSecond,
      appliedAt,
      forwardOperationOrdinal,
    },
  }));
  const native = {
    formatVersion: 2,
    contract: 'recovery720',
    recordingStartedUptimeSeconds: 1000,
    recordingDeadlineUptimeSeconds: 1540,
    samples,
    gates,
    exchanges,
    milestones: [
      ...values.map(([phase], sampleIndex) => ({ phase, sampleIndex })),
      ...[
        ['initial-360', 1],
        ['initial-720', 3],
        ['recovery-360', 6],
        ['recovery-720', 8],
      ].map(([prefix, sampleIndex]) => ({ phase: prefix + '-increase-acknowledged', sampleIndex })),
    ],
  };
  const audit = {
    formatVersion: 1,
    closed: true,
    hostClock: 'performance.now milliseconds',
    runID: 'run',
    records: exchanges.map((e, i) => ({
      runID: 'run',
      sequence: i + 1,
      operation: e.operation,
      diagnostic: structuredClone(samples[i === 0 ? 4 : 5].diagnostic),
      receivedAtHost: e.response.appliedAt - 1,
      respondedAtHost: e.response.appliedAt + 1,
      receipt: {
        phase: e.response.phase,
        appliedAt: e.response.appliedAt,
        rateBitsPerSecond: e.response.rateBitsPerSecond,
        forward: { queue: { rateLedgerOperationOrdinal: e.response.forwardOperationOrdinal } },
      },
    })),
  };
  return { native, audit };
}
export function ordinary720GeometryFixture() {
  const input = ordinary720Fixture();
  const boundaries = [0, 48 * 30, 93 * 30, 118 * 30, 168 * 30, 213 * 30, 240 * 30 + 1];
  const dimensions = [
    [426, 240],
    [640, 360],
    [1280, 720],
    [426, 240],
    [640, 360],
    [1280, 720],
  ];
  const scope = { pipelineReadKey, gameId: 'game', generation: 2, pipelineOrdinal: 7 };
  const total = boundaries.at(-1);
  const workerRows = dimensions.map(([width, height], runIndex) => ({
    msg: 'worker_decoded_geometry',
    ...scope,
    formatVersion: 1,
    diagnosticOnly: true,
    timeBase: '1/90000',
    maximumRuns: 64,
    ended: true,
    invalidReason: null,
    observedFrames: total,
    runCount: 6,
    runIndex,
    width,
    height,
    firstOrdinal: boundaries[runIndex],
    lastOrdinal: boundaries[runIndex + 1] - 1,
    firstPTS: boundaries[runIndex] * 3000,
    lastPTS: (boundaries[runIndex + 1] - 1) * 3000,
    frames: boundaries[runIndex + 1] - boundaries[runIndex],
    maximumPTSDelta: 3000,
  }));
  workerRows.push({
    msg: 'worker_pipeline_terminal',
    ...scope,
    telemetryEOF: true,
    encoderExit: { code: 255, signal: null },
    diagnostics: { ended: true, pipeError: false, drainTimedOut: false, incompleteLine: false },
    decodedVideo: {
      acceptedFrames: total,
      freshFrames: total,
      duplicateFrames: 0,
      reorderedFrames: 0,
      firstPTS: 0,
      lastPTS: (total - 1) * 3000,
      highestPTS: (total - 1) * 3000,
      timeBase: '1/90000',
      invalidReason: null,
      ended: true,
    },
  });
  return { ...input, workerRows, expectedGameId: 'game', expectedGeneration: 2 };
}
