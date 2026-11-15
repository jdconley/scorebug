import assert from 'node:assert/strict';
import { qualifyRepeatedNativeBandwidthProbe } from './repeated-native-bandwidth-probe.mjs';
import { qualifyPublishingAttemptEvidence } from './publishing-attempt-evidence.mjs';
import {
  assertReceiverProbeProgress,
  validateReceiverProbeSnapshot,
} from './receiver-probe-evidence.mjs';

const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value);

/** Reconcile delivered padding against raw native v3 acceptance. Records must
 * come from recordReceiverProbeEvidence, which authenticates the private relay
 * listing before redaction. This replay binds that redacted ownership to scope;
 * it does not recreate authentication from a persisted, secret-free record.
 * Delivery never grants capacity, candidate admission, or upgrade permission. */
export function qualifyRepeatedReceiverProbeEvidence(records, scope, nativeProof) {
  assert.ok(
    Array.isArray(records) && records.length > 0 && records.length <= 2048,
    'Missing bounded repeated receiver evidence',
  );
  const accepted = qualifyRepeatedNativeBandwidthProbe(nativeProof, {
    scope,
    publishingGeneration: nativeProof?.publishingGeneration,
  });
  let publicationBase = 0;
  const stages = accepted.campaigns.flatMap((campaign) => {
    let campaignBase = 0;
    const result = campaign.stages.map((stage) => {
      const row = { ...stage, campaignBase, publicationBase, observationCount: 0 };
      campaignBase += stage.acceptedPayloadBytes;
      return row;
    });
    publicationBase += campaign.acceptedPayloadBytes;
    return result;
  });
  let identity,
    prior,
    currentIndex = -1,
    offsetLower = -Infinity,
    offsetUpper = Infinity;
  for (const record of records) {
    const p = validateReceiverProbeSnapshot(record?.probe);
    assert.equal(p.convention, 'mpegts-null-probe-v3', 'Repeated receiver requires v3');
    const request = record.request;
    for (const key of ['startedAtMilliseconds', 'receivedAtMilliseconds'])
      assert.ok(Number.isFinite(request?.[key]) && request[key] >= 0, 'Invalid receiver request');
    assert.ok(
      request.receivedAtMilliseconds >= request.startedAtMilliseconds &&
        request.receivedAtMilliseconds - request.startedAtMilliseconds <= 1500,
      'Receiver request exceeded bound',
    );
    const publication = record.publication;
    assert.ok(uuid(publication?.publicationId), 'Missing receiver publication identity');
    assert.ok(
      typeof publication.path === 'string' &&
        /^scorebug-[0-9a-f]{16}-[0-9a-f]{32}$/.test(publication.path),
      'Missing authenticated receiver publication path',
    );
    qualifyPublishingAttemptEvidence([publication], scope);
    if (identity) assert.deepEqual(publication, identity, 'Receiver publication changed');
    else identity = publication;

    const index = stages.findIndex(
      (stage) => stage.campaign === p.campaign && stage.stage === p.stage,
    );
    assert.ok(index >= 0, 'Unknown repeated receiver campaign or stage');
    assert.ok(
      index === currentIndex || index === currentIndex + 1,
      'Missing or reordered repeated receiver stage',
    );
    currentIndex = index;
    const stage = stages[index];
    assert.equal(p.id, stage.id, 'Receiver/native stage identity mismatch');
    assert.equal(p.publishingGeneration, accepted.publishingGeneration);
    assert.equal(p.bitRate, stage.bitRate);
    const delivered = Number(p.deliveredPayloadBytes);
    const reserved = p.pendingPackets > 0 ? 1316 : 0;
    assert.ok(
      delivered + reserved <= stage.acceptedPayloadBytes,
      'Receiver delivered or pending bytes exceed native acceptance',
    );
    // Exact bases account for every earlier stage, including terminal deliveries
    // between polls. Campaign bytes restart; publication bytes never restart.
    assert.equal(
      Number(p.campaignDeliveredPayloadBytes),
      stage.campaignBase + delivered,
      'Receiver campaign base differs from native acceptance',
    );
    assert.equal(
      Number(p.totalDeliveredPayloadBytes),
      stage.publicationBase + stage.campaignBase + delivered,
      'Receiver publication base differs from native acceptance',
    );
    const at = Number(p.observedAtNanoseconds) / 1e6;
    offsetLower = Math.max(offsetLower, request.startedAtMilliseconds - at);
    offsetUpper = Math.min(offsetUpper, request.receivedAtMilliseconds - at);
    assert.ok(offsetLower <= offsetUpper, 'Receiver clock does not fit observation bounds');
    if (prior) {
      assert.ok(
        request.startedAtMilliseconds >= prior.request.receivedAtMilliseconds,
        'Receiver requests overlap or regress',
      );
      assertReceiverProbeProgress(p, prior.probe);
    }
    stage.observationCount++;
    prior = { probe: p, request };
  }
  assert.equal(currentIndex, stages.length - 1, 'Missing terminal repeated receiver stage');
  assert.equal(prior.probe.pendingPackets, 0, 'Incomplete terminal repeated probe message');
  assert.equal(
    Number(prior.probe.totalDeliveredPayloadBytes),
    publicationBase,
    'Receiver did not deliver all accepted repeated probe messages',
  );
  const campaigns = accepted.campaigns.map((campaign) => ({
    campaign: campaign.campaign,
    appliedRevision: campaign.context.appliedRevision,
    publishingGeneration: accepted.publishingGeneration,
    deliveredMessages: campaign.acceptedPayloadBytes / 1316,
    deliveredPayloadBytes: campaign.acceptedPayloadBytes,
    stages: stages
      .filter((stage) => stage.campaign === campaign.campaign)
      .map((stage) => ({
        campaign: stage.campaign,
        stage: stage.stage,
        id: stage.id,
        bitRate: stage.bitRate,
        deliveredMessages: stage.acceptedPayloadBytes / 1316,
        deliveredPayloadBytes: stage.acceptedPayloadBytes,
        campaignDeliveredPayloadBytes: stage.campaignBase + stage.acceptedPayloadBytes,
        totalDeliveredPayloadBytes:
          stage.publicationBase + stage.campaignBase + stage.acceptedPayloadBytes,
        observationCount: stage.observationCount,
      })),
  }));
  return {
    mode: 'repeated',
    scope: structuredClone(scope),
    publishingGeneration: accepted.publishingGeneration,
    publicationId: identity.publicationId,
    campaignCount: campaigns.length,
    stageCount: stages.length,
    campaigns,
    deliveredMessages: publicationBase / 1316,
    deliveredPayloadBytes: publicationBase,
    observationCount: records.length,
    clockOffsetBoundMilliseconds: [offsetLower, offsetUpper],
    receiverCapacityQualified: false,
    repeatedPolicyQualified: false,
  };
}
