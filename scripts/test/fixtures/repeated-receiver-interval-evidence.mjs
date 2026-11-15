import { createHmac } from 'node:crypto';
import { repeatedLifecycleFixture } from './repeated-lifecycle-evidence.mjs';
import { recordReceiverProbeEvidence } from '../../receiver-probe-evidence.mjs';
import { recordWorkerPublicationEvidence } from '../../worker-publication-evidence.mjs';

export function repeatedReceiverIntervalFixture() {
  const f = repeatedLifecycleFixture();
  // Leave the actual candidate A/V and stage-3 binding times intact. Extend the
  // preceding native stages backwards, retaining their original IDs/revisions.
  for (const [index, campaign] of f.probe.campaigns.entries()) {
    const origin = 113 + index * 60;
    campaign.context.healthyThrough = origin - 0.1;
    const earlier = [];
    let base = 0;
    for (const stage of [1, 2]) {
      const original = campaign.events.find((e) => e.sample.stage === stage).sample;
      const startedAt = origin + (stage - 1) * 2.25;
      const first = {
        ...original,
        startedAt,
        campaignStartedAt: origin,
        leaseDeadline: startedAt + 0.3,
        acceptedPayloadBytes: '0',
        totalAcceptedPayloadBytes: String(base),
        lastAcceptedAt: null,
      };
      earlier.push({
        phase: stage === 1 ? 'began' : 'replaced',
        observedAt: startedAt + 0.001,
        sample: first,
      });
      const perRenewal = stage === 1 ? 4 : 16;
      for (let n = 1; n <= 21; n++) {
        const at = startedAt + n * 0.1;
        earlier.push({
          phase: 'renewed',
          observedAt: at + 0.001,
          sample: {
            ...first,
            leaseDeadline: at + 0.3,
            acceptedPayloadBytes: String(n * perRenewal * 1316),
            totalAcceptedPayloadBytes: String(base + n * perRenewal * 1316),
            lastAcceptedAt: at - 0.01,
          },
        });
      }
      earlier.push({
        phase: 'retired',
        observedAt: startedAt + 2.12,
        retirementRequestedAt: startedAt + 2.11,
        sample: { ...earlier.at(-1).sample, reason: 'cancelled' },
      });
      base += 21 * perRenewal * 1316;
    }
    campaign.events = [...earlier, ...campaign.events.filter((e) => e.sample.stage === 3)];
  }
  // Scale every original stage-3 observation exactly once, including shared
  // lifecycle/quality objects. All independent consumers still replay raw proof.
  const visited = new WeakSet();
  function scale(value) {
    if (!value || typeof value !== 'object' || visited.has(value)) return;
    visited.add(value);
    if (value.stage === 3 && value.acceptedPayloadBytes !== undefined) {
      value.acceptedPayloadBytes = String(BigInt(value.acceptedPayloadBytes) * 90n);
      if ('totalAcceptedPayloadBytes' in value)
        value.totalAcceptedPayloadBytes = String(552720n + BigInt(value.acceptedPayloadBytes));
      if ('campaignStartedAt' in value)
        value.campaignStartedAt = 113 + (Number(value.campaign) - 1) * 60;
    }
    for (const child of Object.values(value)) scale(child);
  }
  scale(f);
  const secret = 'repeated-fixture-authentication-key';
  const selection = {
    workerId: 'worker',
    outputId: 'output',
    captureDeviceId: 'camera',
    recordingId: f.scope.recordingID,
  };
  const collectorScope = {
    gameId: f.scope.matchID,
    generation: f.scope.broadcastGeneration,
    selection,
  };
  const hmac = (value) => createHmac('sha256', secret).update(JSON.stringify(value)).digest('hex');
  const identity = JSON.stringify([
    f.scope.matchID,
    selection.workerId,
    selection.outputId,
    selection.captureDeviceId,
    f.scope.recordingID,
    f.scope.broadcastGeneration,
  ]);
  const path = `scorebug-${hmac(['scorebug-ingest-v1', 'installation', '']).slice(0, 16)}-${hmac(['scorebug-ingest-v1', 'path', identity]).slice(0, 32)}`;
  const attempt = f.scope.publishingAttemptID.toLowerCase();
  const publisherId = 'dddddddd-dddd-4ddd-8ddd-000000000001';
  const readerId = 'dddddddd-dddd-4ddd-8ddd-000000000002';
  const clock = { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '0' };
  const publication = { readerId, publisherId, publishingAttemptId: attempt, clock };
  const worker = {
    workerId: 'worker',
    workerEpoch: 'dddddddd-dddd-4ddd-8ddd-000000000003',
    workerAttempt: 1,
  };
  const publisher = {
    state: 'publish',
    id: publisherId,
    path,
    query: `sbp1=${attempt}.${hmac(['scorebug-publish-attempt-v1', path, attempt])}`,
    scorebugTransportClock: clock,
  };
  const listing = {
    pageCount: 1,
    itemCount: 2,
    items: [
      publisher,
      {
        state: 'read',
        id: readerId,
        path,
        query: 'sbw1=dddddddd-dddd-4ddd-8ddd-000000000004',
        scorebugReaderSource: { type: 'srtConn', id: publisherId },
      },
    ],
  };
  const workers = new Map();
  for (const sequence of [1, 2])
    recordWorkerPublicationEvidence(
      workers,
      {
        state: 'producing_output',
        gameId: f.scope.matchID,
        generation: f.scope.broadcastGeneration,
        workerId: worker.workerId,
        workerEpoch: worker.workerEpoch,
        publication,
        observation: {
          gameId: f.scope.matchID,
          generation: f.scope.broadcastGeneration,
          state: 'producing_output',
          attempt: 1,
          decodedVideo: {
            clock: 'mpegts-pts-90k-v1',
            ended: false,
            invalidReason: null,
            completed: {
              valid: true,
              durationMs: 5000,
              freshFrames: 150,
              duplicateFrames: 0,
              reorderedFrames: 0,
              sequence,
            },
          },
        },
      },
      listing,
      collectorScope,
      secret,
    );
  const records = new Map(),
    rows = [];
  let publicationBase = 0;
  for (const campaign of f.probe.campaigns) {
    let campaignBase = 0;
    for (const stage of [1, 2, 3]) {
      const events = campaign.events.filter((e) => e.sample.stage === stage);
      const first = events[0].sample;
      const final = events.at(-1).sample;
      const batch = [4, 16, 90][stage - 1];
      const snapshot = (at) => {
        const n = Math.min(
          stage === 3 ? 124 : 21,
          Math.max(0, Math.floor((at - first.startedAt - 0.02) * 10 + 1e-7)),
        );
        const count = n * batch,
          bytes = count * 1316;
        const ns = (t) => String(Math.round(t * 1e9));
        return {
          convention: 'mpegts-null-probe-v3',
          id: first.id.toLowerCase(),
          campaign: campaign.campaign,
          stage,
          publishingGeneration: f.probe.publishingGeneration,
          bitRate: first.bitRate,
          deliveredMessages: String(count),
          deliveredPayloadBytes: String(bytes),
          nextSequence: String(count),
          pendingPackets: 0,
          campaignDeliveredPayloadBytes: String(campaignBase + bytes),
          totalDeliveredPayloadBytes: String(publicationBase + campaignBase + bytes),
          observedAtNanoseconds: ns(at),
          ...(count
            ? {
                firstDeliveredAtNanoseconds: ns(first.startedAt + 0.12),
                lastDeliveredAtNanoseconds: ns(first.startedAt + n * 0.1 + 0.02),
              }
            : {}),
        };
      };
      const shift = (Number(campaign.campaign) - 1) * 60;
      const polls =
        stage === 3
          ? [127.2, 127.4, 128.4, 128.6, 129.6, 129.8, 129.94].map((at) => at + shift)
          : [0.2, 0.4, 1.4, 1.6, 2.13].map((t) => first.startedAt + t);
      for (const at of polls) {
        publisher.scorebugBandwidthProbe = snapshot(at);
        recordReceiverProbeEvidence(records, listing, collectorScope, secret, {
          startedAtMilliseconds: at * 1000 + 100,
          receivedAtMilliseconds: at * 1000 + 110,
        });
      }
      const endpoints =
        stage === 3
          ? [
              [127.3 + shift, 128.5 + shift],
              [128.5 + shift, 129.7 + shift],
            ]
          : [[first.startedAt + 0.3, first.startedAt + 1.5]];
      for (const [startAt, endAt] of endpoints) {
        const start = snapshot(startAt),
          end = snapshot(endAt);
        const native = events.findLast(
          (event) => event.observedAt <= endAt + 0.021 && event.sample.reason === null,
        ).sample;
        const count = Number(end.deliveredMessages) - Number(start.deliveredMessages);
        const duration = BigInt(end.observedAtNanoseconds) - BigInt(start.observedAtNanoseconds);
        rows.push({
          start,
          end,
          publication: structuredClone(publication),
          ...worker,
          durationNanoseconds: String(duration),
          deliveredMessages: String(count),
          deliveredPayloadBytesLowerBound: String(count * 1316),
          payloadBitsPerSecondLowerBound: (count * 1316 * 8e9) / Number(duration),
          snapshotAgeUpperBoundMs: 18,
          lastDeliveryAgeUpperBoundMs:
            18 +
            Number(BigInt(end.observedAtNanoseconds) - BigInt(end.lastDeliveredAtNanoseconds)) /
              1e6,
          acceptedPayloadBytes: native.acceptedPayloadBytes,
          nativeProbeId: first.id.toLowerCase(),
          nativeProbeStage: stage,
          nativeProbeCampaign: campaign.campaign,
          nativePublishingGeneration: f.probe.publishingGeneration,
          requestDurationMs: 10,
          residenceDurationMs: 3,
          serverAgeUpperBoundMs: 5,
          requestStartedAt: endAt + 0.01,
          responseReceivedAt: endAt + 0.02,
          nativeReadStartedAt: endAt + 0.021,
          nativeReadFinishedAt: endAt + 0.022,
          evaluatedAt: endAt + 0.023,
          nativeStartedAt: first.startedAt,
          nativeLeaseDeadline: native.leaseDeadline,
          nativeLastAcceptedAt: native.lastAcceptedAt,
        });
      }
      campaignBase += Number(final.acceptedPayloadBytes);
    }
    publicationBase += campaignBase;
  }
  return {
    ...f,
    intervals: {
      formatVersion: 1,
      isClosed: true,
      invalid: false,
      scope: f.scope,
      intervals: rows,
    },
    records: [...records.values()],
    workerRecords: [...workers.values()],
  };
}
