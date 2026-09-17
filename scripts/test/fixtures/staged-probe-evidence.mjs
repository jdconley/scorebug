export function stagedProbeEvidence() {
  const attempt = '30000000-0000-4000-8000-00000000000c';
  const publisherId = '40000000-0000-4000-8000-00000000000b';
  const scope = {
    matchID: 'match',
    broadcastGeneration: 1,
    recordingID: 'archive',
    publishingAttemptID: attempt.toUpperCase(),
    appliedProfileRevision: '1',
  };
  const publication = {
    publicationId: publisherId,
    publishingAttemptId: attempt,
    gameId: 'match',
    generation: 1,
    recordingId: 'archive',
  };
  const workerPublication = {
    readerId: '20000000-0000-4000-8000-00000000000a',
    publisherId,
    publishingAttemptId: attempt,
    clock: { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '0' },
  };
  const worker = {
    workerEpoch: '10000000-0000-4000-8000-00000000000e',
    workerId: 'mac',
    workerAttempt: 1,
  };
  const events = [],
    records = [],
    intervals = [],
    stages = [];
  let priorBytes = 0;
  for (let index = 0; index < 3; index++) {
    const stage = index + 1,
      scale = 2 ** index,
      startedAt = 100 + index * 4;
    const id = `60000000-0000-4000-8000-00000000000${['d', 'e', 'f'][index]}`;
    const bitRate = 500_000 * scale;
    const snapshot = (seconds) => {
      const n = Math.round(seconds * 40 * scale);
      return {
        convention: 'mpegts-null-probe-v2',
        id,
        stage,
        publishingGeneration: '1',
        bitRate,
        deliveredMessages: String(n),
        deliveredPayloadBytes: String(n * 1316),
        nextSequence: String(n),
        pendingPackets: 0,
        totalDeliveredPayloadBytes: String(priorBytes + n * 1316),
        observedAtNanoseconds: String(Math.round((index * 4 + seconds) * 1e9)),
        firstDeliveredAtNanoseconds: String(Math.round((index * 4 + 0.025 / scale - 0.001) * 1e9)),
        lastDeliveredAtNanoseconds: String(Math.round((index * 4 + seconds - 0.001) * 1e9)),
      };
    };
    for (let i = 0; i <= 30; i++) {
      const at = startedAt + i * 0.1,
        bytes = i * 4 * scale * 1316;
      events.push({
        phase: i ? 'renewed' : index ? 'replaced' : 'began',
        observedAt: at,
        sample: {
          id,
          publishingGeneration: '1',
          stage,
          bitRate,
          startedAt,
          leaseDeadline: at + 0.3,
          acceptedPayloadBytes: String(bytes),
          totalAcceptedPayloadBytes: String(priorBytes + bytes),
          campaignStartedAt: 100,
          lastAcceptedAt: i ? at - 0.001 : null,
          reason: null,
        },
      });
    }
    const retired = { ...events.at(-1).sample, reason: 'cancelled' };
    events.push({
      phase: 'retired',
      observedAt: startedAt + 3.02,
      retirementRequestedAt: startedAt + 3.01,
      sample: retired,
    });
    stages.push({
      stage,
      id,
      publishingGeneration: '1',
      bitRate,
      startedAt,
      campaignStartedAt: 100,
      acceptedPayloadBytes: 120 * scale * 1316,
      totalAcceptedPayloadBytes: priorBytes + 120 * scale * 1316,
      lastAcceptedAt: startedAt + 3 - 0.001,
      retirementRequestedAt: startedAt + 3.01,
      retiredObservedAt: startedAt + 3.02,
      reason: 'cancelled',
    });
    for (const seconds of [1, 2, 3])
      records.push({
        publication: { ...publication },
        probe: snapshot(seconds),
        request: {
          startedAtMilliseconds: (index * 4 + seconds) * 1000 + 100,
          receivedAtMilliseconds: (index * 4 + seconds) * 1000 + 110,
        },
      });
    const count = 40 * scale;
    intervals.push({
      start: snapshot(1.1),
      end: snapshot(2.1),
      publication: { ...workerPublication },
      ...worker,
      durationNanoseconds: '1000000000',
      deliveredMessages: String(count),
      deliveredPayloadBytesLowerBound: String(count * 1316),
      payloadBitsPerSecondLowerBound: count * 1316 * 8,
      snapshotAgeUpperBoundMs: 28,
      lastDeliveryAgeUpperBoundMs: 29,
      acceptedPayloadBytes: String(84 * scale * 1316),
      nativeProbeId: id,
      nativeProbeStage: stage,
      nativePublishingGeneration: '1',
      requestDurationMs: 20,
      residenceDurationMs: 3,
      serverAgeUpperBoundMs: 5,
      requestStartedAt: startedAt + 2.09,
      responseReceivedAt: startedAt + 2.11,
      nativeReadStartedAt: startedAt + 2.11,
      nativeReadFinishedAt: startedAt + 2.112,
      evaluatedAt: startedAt + 2.113,
      nativeStartedAt: startedAt,
      nativeLeaseDeadline: startedAt + 2.1 + 0.3,
      nativeLastAcceptedAt: startedAt + 2.1 - 0.001,
    });
    priorBytes += 120 * scale * 1316;
  }
  events.push({ phase: 'final', observedAt: 120, sample: { ...events.at(-1).sample } });
  const nativeProof = {
    formatVersion: 2,
    isClosed: true,
    invalid: false,
    mode: 'staged',
    result: 'completed',
    scope,
    publishingGeneration: '1',
    events,
  };
  const accepted = {
    mode: 'staged',
    publishingGeneration: '1',
    acceptedPayloadBytes: priorBytes,
    totalAcceptedPayloadBytes: priorBytes,
    stages,
    eventCount: events.length,
    receiverCapacityQualified: false,
  };
  const workerRecords = [
    {
      gameId: 'match',
      generation: 1,
      recordingId: 'archive',
      workerId: worker.workerId,
      workerEpoch: worker.workerEpoch,
      attempt: 1,
      publication: workerPublication,
      completedWindows: [1, 2],
    },
  ];
  return {
    scope,
    nativeProof,
    accepted,
    records,
    workerRecords,
    proof: { formatVersion: 1, isClosed: true, invalid: false, scope, intervals },
  };
}
