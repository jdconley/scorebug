import assert from 'node:assert/strict';
import { qualifyOwnedNativeProbes } from './owned-native-probes.mjs';
import { qualifyPublishingAttemptEvidence } from './publishing-attempt-evidence.mjs';
import {
  assertReceiverProbeProgress,
  validateReceiverProbeSnapshot,
} from './receiver-probe-evidence.mjs';

const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value);

/** Delivery conservation over the complete original owned audit, including failed
 * attempts. Records must come from recordReceiverProbeEvidence's independently
 * authenticated, redacted relay collection. Persisted records cannot recreate
 * that authentication. This bounded slice requires every returned native stage
 * to have an actual receiver row. A joined zero-acceptance stage may naturally
 * be invisible to the receiver: that is an unsupported conservation case here,
 * not a product delivery failure. No receiver row is synthesized for it.
 * This join grants no capacity, admission, retry, media, or recovery authority.
 */
export function qualifyOwnedReceiverProbeEvidence(records, rawOwned, options = {}) {
  assert.ok(
    Array.isArray(records) && records.length > 0 && records.length <= 2048,
    'Missing bounded owned receiver evidence',
  );
  // The native replay validates the explicit option whitelist, scope, trusted
  // timing selection, generation, and every original attempt/event first.
  const native = qualifyOwnedNativeProbes(rawOwned, options);
  const { scope, publishingGeneration } = options;
  let publicationBase = 0;
  const stages = [];
  const attempts = native.attempts.map((attempt, attemptIndex) => {
    let campaignBase = 0;
    const joined = {
      ...attempt,
      attemptIndex,
      publishingGeneration,
      deliveredPayloadBytes: attempt.acceptedPayloadBytes,
      deliveredMessages: attempt.acceptedPayloadBytes / 1316,
      stages: attempt.stages.map((stage) => {
        const row = {
          ...stage,
          attemptIndex,
          campaign: attempt.campaign,
          publishingGeneration,
          deliveredPayloadBytes: stage.acceptedPayloadBytes,
          deliveredMessages: stage.acceptedPayloadBytes / 1316,
          campaignDeliveredPayloadBytes: campaignBase + stage.acceptedPayloadBytes,
          totalDeliveredPayloadBytes: publicationBase + campaignBase + stage.acceptedPayloadBytes,
          receiverRecordIndices: [],
          observationCount: 0,
        };
        stages.push({ row, campaignBase, publicationBase });
        campaignBase += stage.acceptedPayloadBytes;
        return row;
      }),
    };
    publicationBase += attempt.acceptedPayloadBytes;
    return joined;
  });
  for (const { row } of stages) {
    assert.ok(
      row.acceptedPayloadBytes > 0 || records.some((record) => record?.probe?.id === row.id),
      'Unsupported conservation: unobserved zero-acceptance native stage',
    );
  }
  let identity,
    prior,
    currentIndex = -1,
    offsetLower = -Infinity,
    offsetUpper = Infinity;
  for (const [recordIndex, record] of records.entries()) {
    const p = validateReceiverProbeSnapshot(record?.probe);
    assert.equal(p.convention, 'mpegts-null-probe-v3', 'Owned receiver requires v3');
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
      ({ row }) => row.campaign === p.campaign && row.stage === p.stage,
    );
    assert.ok(index >= 0, 'Unknown owned receiver campaign or stage');
    // The shared progress helper permits increasing, non-contiguous ordinals.
    // This slice separately requires every original native stage to be observed.
    assert.ok(
      index === currentIndex || index === currentIndex + 1,
      'Missing or reordered owned receiver stage',
    );
    currentIndex = index;
    const { row, campaignBase, publicationBase: base } = stages[index];
    assert.equal(p.id, row.id, 'Receiver/native stage identity mismatch');
    assert.equal(
      p.publishingGeneration,
      publishingGeneration,
      'Receiver/native generation mismatch',
    );
    assert.equal(p.bitRate, row.bitRate, 'Receiver/native rate mismatch');
    const delivered = Number(p.deliveredPayloadBytes);
    assert.ok(
      delivered + (p.pendingPackets > 0 ? 1316 : 0) <= row.acceptedPayloadBytes,
      'Receiver delivered or pending bytes exceed native acceptance',
    );
    // A later stage's exact native carry proves prior terminal delivery even
    // when it occurred between polls. Publication carry includes failed owners.
    assert.equal(
      Number(p.campaignDeliveredPayloadBytes),
      campaignBase + delivered,
      'Receiver campaign base differs from native acceptance',
    );
    assert.equal(
      Number(p.totalDeliveredPayloadBytes),
      base + campaignBase + delivered,
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
    row.receiverRecordIndices.push(recordIndex);
    row.observationCount++;
    prior = { probe: p, request };
  }
  assert.equal(currentIndex, stages.length - 1, 'Missing terminal owned receiver stage');
  assert.equal(prior.probe.pendingPackets, 0, 'Incomplete terminal owned probe message');
  assert.equal(
    Number(prior.probe.totalDeliveredPayloadBytes),
    publicationBase,
    'Receiver did not deliver all accepted owned probe messages',
  );
  return {
    ...native,
    mode: 'owned',
    scope: structuredClone(scope),
    publishingGeneration,
    publicationId: identity.publicationId,
    campaignCount: attempts.filter((attempt) => attempt.campaign !== null).length,
    stageCount: stages.length,
    attempts,
    deliveredMessages: publicationBase / 1316,
    deliveredPayloadBytes: publicationBase,
    observationCount: records.length,
    clockOffsetBoundMilliseconds: [offsetLower, offsetUpper],
    receiverConservationQualified: true,
    receiverCapacityQualified: false,
    candidateAdmissionQualified: false,
    retryPolicyQualified: false,
    mediaQualified: false,
    recoveryQualified: false,
  };
}
