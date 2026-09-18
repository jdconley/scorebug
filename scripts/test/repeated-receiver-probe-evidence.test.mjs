import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import test from 'node:test';
import { recordReceiverProbeEvidence } from '../receiver-probe-evidence.mjs';
import {
  repeatedProbeScope,
  repeatedNativeProbeEvidence,
} from './fixtures/repeated-probe-evidence.mjs';

const implementation = await import('../repeated-receiver-probe-evidence.mjs').catch((error) => {
  if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error;
  return {};
});
function fixture(ending = 'observed') {
  const nativeProof = repeatedNativeProbeEvidence(ending);
  const scope = { ...repeatedProbeScope };
  const secret = 'fixture-private-authentication-key';
  const selection = {
    workerId: 'worker',
    outputId: 'output',
    captureDeviceId: 'camera',
    recordingId: scope.recordingID,
  };
  const collectionScope = {
    gameId: scope.matchID,
    generation: scope.broadcastGeneration,
    selection,
  };
  const hmac = (value) => createHmac('sha256', secret).update(JSON.stringify(value)).digest('hex');
  const identity = JSON.stringify([
    scope.matchID,
    selection.workerId,
    selection.outputId,
    selection.captureDeviceId,
    scope.recordingID,
    scope.broadcastGeneration,
  ]);
  const path = `scorebug-${hmac(['scorebug-ingest-v1', 'installation', '']).slice(0, 16)}-${hmac(['scorebug-ingest-v1', 'path', identity]).slice(0, 32)}`;
  const attempt = scope.publishingAttemptID.toLowerCase();
  const connection = {
    state: 'publish',
    id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    path,
    query: `sbp1=${attempt}.${hmac(['scorebug-publish-attempt-v1', path, attempt])}`,
  };
  const evidence = new Map();
  for (const campaign of nativeProof.campaigns) {
    for (const event of campaign.events.filter((e) => ['began', 'replaced'].includes(e.phase))) {
      const s = event.sample;
      for (const messages of [0, 1, 2]) {
        const observedSeconds = s.startedAt + [0.02, 0.18, 0.21][messages];
        const nanoseconds = (value) => String(Math.round(value * 1e9));
        const campaignBytes = (s.stage - 1) * 2632 + messages * 1316;
        const probe = {
          convention: 'mpegts-null-probe-v3',
          id: s.id,
          campaign: campaign.campaign,
          stage: s.stage,
          publishingGeneration: '7',
          bitRate: s.bitRate,
          deliveredMessages: String(messages),
          nextSequence: String(messages),
          deliveredPayloadBytes: String(messages * 1316),
          pendingPackets: messages === 1 ? 3 : 0,
          campaignDeliveredPayloadBytes: String(campaignBytes),
          totalDeliveredPayloadBytes: String(
            (Number(campaign.campaign) - 1) * 7896 + campaignBytes,
          ),
          observedAtNanoseconds: nanoseconds(observedSeconds),
          ...(messages
            ? {
                firstDeliveredAtNanoseconds: nanoseconds(s.startedAt + 0.1),
                lastDeliveredAtNanoseconds: nanoseconds(s.startedAt + (messages === 1 ? 0.1 : 0.2)),
              }
            : {}),
        };
        recordReceiverProbeEvidence(
          evidence,
          {
            pageCount: 1,
            itemCount: 1,
            items: [{ ...connection, scorebugBandwidthProbe: probe }],
          },
          collectionScope,
          secret,
          {
            startedAtMilliseconds: observedSeconds * 1000 + 100,
            receivedAtMilliseconds: observedSeconds * 1000 + 110,
          },
        );
      }
    }
  }
  return { scope, nativeProof, records: [...evidence.values()] };
}
function qualify(f) {
  assert.equal(
    typeof implementation.qualifyRepeatedReceiverProbeEvidence,
    'function',
    'repeated receiver verifier must be implemented',
  );
  return implementation.qualifyRepeatedReceiverProbeEvidence(f.records, f.scope, f.nativeProof);
}
for (const ending of ['observed', 'renewed', 'retired'])
  test(`reconciles six authenticated stages from original native ${ending} proof`, () => {
    const f = fixture(ending),
      before = structuredClone(f),
      result = qualify(f);
    assert.deepEqual(f, before);
    assert.equal(result.mode, 'repeated');
    assert.equal(result.stageCount, 6);
    assert.equal(result.campaignCount, 2);
    assert.equal(result.publishingGeneration, '7');
    assert.equal(result.publicationId, f.records[0].publication.publicationId);
    assert.equal(result.deliveredPayloadBytes, 15792);
    assert.equal(result.deliveredMessages, 12);
    assert.equal(result.observationCount, 18);
    assert.deepEqual(result.clockOffsetBoundMilliseconds.map(Math.round), [100, 110]);
    assert.equal(result.receiverCapacityQualified, false);
    assert.equal(result.repeatedPolicyQualified, false);
    assert.deepEqual(
      result.campaigns.map((c) => [c.campaign, c.appliedRevision, c.deliveredPayloadBytes]),
      [
        ['1', '0', 7896],
        ['2', '2', 7896],
      ],
    );
    for (const campaign of result.campaigns) {
      assert.equal(campaign.deliveredMessages, 6);
      assert.deepEqual(
        campaign.stages.map((s) => s.stage),
        [1, 2, 3],
      );
      assert.deepEqual(
        campaign.stages.map((s) => s.deliveredPayloadBytes),
        [2632, 2632, 2632],
      );
      assert.ok(campaign.stages.every((s) => s.campaign === campaign.campaign));
    }
  });
test('reconciles missed terminal polls through exact next-stage and next-campaign bases', () => {
  const f = fixture();
  f.records = f.records.filter((r, i) => i === 17 || r.probe.deliveredMessages !== '2');
  assert.equal(qualify(f).deliveredPayloadBytes, 15792);
});
test('accepts first observations after delivery without inventing empty snapshots', () => {
  const f = fixture();
  f.records = f.records.filter((r) => r.probe.deliveredMessages !== '0');
  assert.equal(qualify(f).observationCount, 12);
});
test('preserves original nonzero revisions', () => {
  const f = fixture();
  f.nativeProof.campaigns[0].context.appliedRevision = '4';
  f.nativeProof.campaigns[1].context.appliedRevision = '6';
  assert.deepEqual(
    qualify(f).campaigns.map((c) => c.appliedRevision),
    ['4', '6'],
  );
});
const mutations = {
  noRecords: (f) => {
    f.records = [];
  },
  oversizedHistory: (f) => {
    f.records = Array(2049).fill(f.records[0]);
  },
  summarizedNativeProof: (f) => {
    f.nativeProof = { ...f.nativeProof, formatVersion: undefined };
  },
  nativeScope: (f) => {
    f.nativeProof.scope.matchID = 'foreign';
  },
  nativeUnjoined: (f) => {
    f.nativeProof.campaigns[1].isJoined = false;
  },
  nativeStaleRevision: (f) => {
    f.nativeProof.campaigns[1].context.appliedRevision = '0';
  },
  nativeAcceptanceInflation: (f) => {
    f.nativeProof.campaigns[1].events[1].sample.acceptedPayloadBytes = '131600';
  },
  nativeHiddenEvent: (f) => {
    f.nativeProof.campaigns[1].events.push({ phase: 'ignored' });
  },
  missingCampaign: (f) => {
    f.records = f.records.filter((r) => r.probe.campaign === '1');
  },
  missingFirstStage: (f) => {
    f.records.splice(0, 3);
  },
  missingMiddleStage: (f) => {
    f.records.splice(12, 3);
  },
  missingFinalStage: (f) => {
    f.records.splice(15, 3);
  },
  crossedCampaign: (f) => {
    f.records[13].probe.campaign = '1';
  },
  unknownCampaign: (f) => {
    f.records[13].probe.campaign = '3';
  },
  unknownStage: (f) => {
    f.records[13].probe.stage = 4;
  },
  crossedId: (f) => {
    f.records[13].probe.id = f.records[4].probe.id;
  },
  changedRate: (f) => {
    f.records[13].probe.bitRate = 500000;
  },
  crossedNativeGeneration: (f) => {
    f.records[13].probe.publishingGeneration = '8';
  },
  changedPublication: (f) => {
    f.records[13].publication.publicationId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  },
  missingPublicationId: (f) => {
    for (const r of f.records) delete r.publication.publicationId;
  },
  missingAuthenticatedPath: (f) => {
    for (const r of f.records) delete r.publication.path;
  },
  changedAuthenticatedPath: (f) => {
    f.records[13].publication.path += 'a';
  },
  wrongAttempt: (f) => {
    f.records[13].publication.publishingAttemptId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  },
  wrongRecording: (f) => {
    f.records[13].publication.recordingId = 'foreign';
  },
  wrongMatch: (f) => {
    f.records[13].publication.gameId = 'foreign';
  },
  wrongBroadcast: (f) => {
    f.records[13].publication.generation = 2;
  },
  mixedVersion: (f) => {
    f.records[13].probe.convention = 'mpegts-null-probe-v2';
  },
  campaignCarryOver: (f) => {
    for (const r of f.records.slice(9))
      r.probe.campaignDeliveredPayloadBytes = r.probe.totalDeliveredPayloadBytes;
  },
  publicationReset: (f) => {
    for (const r of f.records.slice(9))
      r.probe.totalDeliveredPayloadBytes = r.probe.campaignDeliveredPayloadBytes;
  },
  inflatedCampaignBase: (f) => {
    f.records[13].probe.campaignDeliveredPayloadBytes = '5264';
  },
  inflatedPublicationBase: (f) => {
    f.records[13].probe.totalDeliveredPayloadBytes = '13160';
  },
  pendingBeyondAccepted: (f) => {
    f.records[2].probe.pendingPackets = 1;
  },
  missingFinalDelivery: (f) => {
    f.records.pop();
  },
  pendingFinal: (f) => {
    f.records.at(-1).probe.pendingPackets = 1;
  },
  packetRegression: (f) => {
    const r = structuredClone(f.records[13]);
    r.probe.pendingPackets = 2;
    r.probe.observedAtNanoseconds = String(BigInt(r.probe.observedAtNanoseconds) + 15000000n);
    r.request.startedAtMilliseconds += 15;
    r.request.receivedAtMilliseconds += 15;
    f.records.splice(14, 0, r);
  },
  deliveryBeforePriorObservation: (f) => {
    f.records[14].probe.lastDeliveredAtNanoseconds =
      f.records[13].probe.firstDeliveredAtNanoseconds;
  },
  changingFirstDelivery: (f) => {
    f.records[14].probe.firstDeliveredAtNanoseconds = String(
      BigInt(f.records[14].probe.firstDeliveredAtNanoseconds) + 1n,
    );
  },
  firstDeliveryBeforeRestart: (f) => {
    f.records[13].probe.firstDeliveredAtNanoseconds =
      f.records[13].probe.lastDeliveredAtNanoseconds =
        f.records[11].probe.firstDeliveredAtNanoseconds;
  },
  reversedRecords: (f) => {
    f.records.reverse();
  },
  receiverClockJump: (f) => {
    for (const r of f.records.slice(9)) r.request.startedAtMilliseconds += 100;
  },
  changedReceiverClockOffset: (f) => {
    for (const r of f.records.slice(9)) {
      r.request.startedAtMilliseconds += 1000;
      r.request.receivedAtMilliseconds += 1000;
    }
  },
  overlappingRequests: (f) => {
    f.records[13].request.startedAtMilliseconds = f.records[12].request.startedAtMilliseconds;
  },
  unboundedRequest: (f) => {
    f.records[13].request.receivedAtMilliseconds += 2000;
  },
  malformedRequest: (f) => {
    f.records[13].request.startedAtMilliseconds = NaN;
  },
  invalidProbe: (f) => {
    f.records[13].probe.invalidReason = 'invalid';
  },
};
for (const [name, mutate] of Object.entries(mutations))
  test(`rejects repeated receiver ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.equal(
      typeof implementation.qualifyRepeatedReceiverProbeEvidence,
      'function',
      'repeated receiver verifier must be implemented',
    );
    assert.throws(() => qualify(f));
  });
