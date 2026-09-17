import assert from 'node:assert/strict';
import { candidateHeadroomStageRates } from './native-candidate-headroom.mjs';
import {
  recordPublishingAttemptEvidence,
  qualifyPublishingAttemptEvidence,
} from './publishing-attempt-evidence.mjs';
const uuid = (value) =>
  typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value);
function integer(value, max = 18446744073709551615n) {
  assert.ok(
    typeof value === 'string' && value.length <= 20 && /^(0|[1-9][0-9]*)$/.test(value),
    'Invalid receiver integer',
  );
  const n = BigInt(value);
  assert.ok(n <= max);
  return n;
}
export function validateReceiverProbeSnapshot(p) {
  assert.ok(p && typeof p === 'object');
  const staged = p.convention === 'mpegts-null-probe-v2';
  assert.ok(staged || p.convention === 'mpegts-null-probe-v1');
  if (staged) assert.ok(Number.isInteger(p.stage) && p.stage >= 1 && p.stage <= 32);
  else {
    assert.equal(p.stage, undefined);
    assert.equal(p.totalDeliveredPayloadBytes, undefined);
  }
  assert.ok(uuid(p.id) && p.id !== '00000000-0000-0000-0000-000000000000');
  assert.ok(integer(p.publishingGeneration) > 0n);
  assert.ok(
    Number.isSafeInteger(p.bitRate) && p.bitRate > 0 && p.bitRate <= (staged ? 12000000 : 2000000),
  );
  assert.equal(p.invalidReason, undefined, 'Invalid receiver proof');
  const messages = integer(p.deliveredMessages, BigInt(Math.floor((16 * 1024 * 1024) / 1316)));
  assert.equal(integer(p.deliveredPayloadBytes, 16n * 1024n * 1024n), messages * 1316n);
  assert.equal(integer(p.nextSequence), messages);
  assert.ok(Number.isInteger(p.pendingPackets) && p.pendingPackets >= 0 && p.pendingPackets <= 6);
  if (staged) {
    const total = integer(p.totalDeliveredPayloadBytes, 16n * 1024n * 1024n);
    assert.equal(total % 1316n, 0n);
    assert.ok(total >= messages * 1316n);
    assert.ok(total + (p.pendingPackets ? 1316n : 0n) <= 16n * 1024n * 1024n);
  }
  const at = integer(p.observedAtNanoseconds, 86400000000000n);
  if (messages > 0n) {
    const first = integer(p.firstDeliveredAtNanoseconds, at),
      last = integer(p.lastDeliveredAtNanoseconds, at);
    assert.ok(first <= last);
    if (staged && messages === 1n) assert.equal(first, last);
  } else {
    assert.equal(p.firstDeliveredAtNanoseconds, undefined);
    assert.equal(p.lastDeliveredAtNanoseconds, undefined);
  }
  return Object.fromEntries(
    [
      'convention',
      'stage',
      'totalDeliveredPayloadBytes',
      'id',
      'publishingGeneration',
      'bitRate',
      'deliveredMessages',
      'deliveredPayloadBytes',
      'nextSequence',
      'pendingPackets',
      'observedAtNanoseconds',
      'firstDeliveredAtNanoseconds',
      'lastDeliveredAtNanoseconds',
    ]
      .filter((k) => p[k] !== undefined)
      .map((k) => [k, p[k]]),
  );
}
/** Same-stage history, usable with independently polled and app interval samples. */
export function assertReceiverProbeProgress(p, previous) {
  assert.equal(p.convention, previous.convention);
  for (const key of ['id', 'publishingGeneration', 'bitRate', 'stage'])
    assert.equal(p[key], previous[key]);
  assert.ok(BigInt(p.observedAtNanoseconds) >= BigInt(previous.observedAtNanoseconds));
  if (p.observedAtNanoseconds === previous.observedAtNanoseconds)
    assert.deepEqual(p, previous, 'Conflicting snapshots at the same receiver instant');
  if (p.convention === 'mpegts-null-probe-v2')
    assert.equal(
      BigInt(p.totalDeliveredPayloadBytes) - BigInt(previous.totalDeliveredPayloadBytes),
      BigInt(p.deliveredPayloadBytes) - BigInt(previous.deliveredPayloadBytes),
    );
  assert.ok(BigInt(p.deliveredMessages) >= BigInt(previous.deliveredMessages));
  const completed = BigInt(p.deliveredMessages),
    previousCompleted = BigInt(previous.deliveredMessages);
  assert.ok(
    completed * 7n + BigInt(p.pendingPackets) >=
      previousCompleted * 7n + BigInt(previous.pendingPackets),
    'Receiver packet progress reversed',
  );
  if (completed > previousCompleted) {
    assert.ok(
      BigInt(p.lastDeliveredAtNanoseconds) >= BigInt(previous.observedAtNanoseconds),
      'New receiver delivery predates prior observation',
    );
    if (previousCompleted === 0n)
      assert.ok(
        BigInt(p.firstDeliveredAtNanoseconds) >= BigInt(previous.observedAtNanoseconds),
        'First receiver delivery predates prior observation',
      );
  }

  if (previous.firstDeliveredAtNanoseconds !== undefined) {
    assert.equal(p.firstDeliveredAtNanoseconds, previous.firstDeliveredAtNanoseconds);
    assert.ok(BigInt(p.lastDeliveredAtNanoseconds) >= BigInt(previous.lastDeliveredAtNanoseconds));
    if (p.deliveredMessages === previous.deliveredMessages)
      assert.equal(p.lastDeliveredAtNanoseconds, previous.lastDeliveredAtNanoseconds);
  }
}
function requestBounds(r) {
  for (const key of ['startedAtMilliseconds', 'receivedAtMilliseconds'])
    assert.ok(Number.isFinite(r?.[key]) && r[key] >= 0);
  assert.ok(
    r.receivedAtMilliseconds >= r.startedAtMilliseconds &&
      r.receivedAtMilliseconds - r.startedAtMilliseconds <= 1500,
    'Receiver request exceeded bound',
  );
  return {
    startedAtMilliseconds: r.startedAtMilliseconds,
    receivedAtMilliseconds: r.receivedAtMilliseconds,
  };
}
/** Finite fixture collector. Authentication is independently checked before redaction. */
export function recordReceiverProbeEvidence(evidence, listing, scope, secret, request) {
  assert.ok(evidence instanceof Map && evidence.size <= 2048);
  const verified = new Map();
  recordPublishingAttemptEvidence(verified, listing, scope, secret);
  const ids = listing.items.map((c) => c.id).filter((id) => id !== undefined);
  assert.equal(new Set(ids).size, ids.length, 'Ambiguous relay identity');
  for (const connection of listing.items) {
    if (connection.state !== 'publish' || connection.scorebugBandwidthProbe === undefined) continue;
    const publication = verified.get(connection.id);
    assert.ok(publication);
    const record = {
      publication: { ...publication },
      probe: validateReceiverProbeSnapshot(connection.scorebugBandwidthProbe),
      request: requestBounds(request),
    };
    assert.ok(evidence.size < 2048, 'Receiver history exhausted');
    evidence.set(evidence.size, record);
  }
}
/** Delivered payload reconciliation only; not fresh capacity or upgrade admission. */
export function qualifyReceiverProbeEvidence(records, nativeScope, accepted) {
  assert.ok(
    Array.isArray(records) && records.length > 0 && records.length <= 2048,
    'Missing receiver evidence',
  );
  const staged = accepted.mode === 'staged';
  assert.ok(
    accepted.schedule === undefined || (staged && accepted.schedule === 'candidate-headroom-v1'),
  );
  let stages;
  if (staged) {
    assert.equal(accepted.stages?.length, 3);
    let total = 0;
    stages = accepted.stages.map((stage, i) => {
      assert.equal(stage.stage, i + 1);
      assert.ok(uuid(stage.id) && stage.id !== '00000000-0000-0000-0000-000000000000');
      assert.equal(stage.publishingGeneration, accepted.publishingGeneration);
      assert.equal(
        stage.bitRate,
        accepted.schedule === 'candidate-headroom-v1'
          ? candidateHeadroomStageRates[i]
          : 500000 * 2 ** i,
      );
      assert.ok(Number.isSafeInteger(stage.acceptedPayloadBytes) && stage.acceptedPayloadBytes > 0);
      assert.equal(stage.acceptedPayloadBytes % 1316, 0);
      const base = total;
      total += stage.acceptedPayloadBytes;
      assert.equal(stage.totalAcceptedPayloadBytes, total);
      return { ...stage, base };
    });
    assert.ok(total <= 16 * 1024 * 1024);
    assert.equal(accepted.acceptedPayloadBytes, total);
    assert.equal(accepted.totalAcceptedPayloadBytes, total);
  }
  assert.ok(
    staged ||
      (uuid(accepted.id?.toLowerCase()) &&
        Number.isSafeInteger(accepted.acceptedPayloadBytes) &&
        accepted.acceptedPayloadBytes > 0),
  );
  let prior,
    identity,
    offsetLower = -Infinity,
    offsetUpper = Infinity;
  for (const record of records) {
    const p = validateReceiverProbeSnapshot(record.probe),
      request = requestBounds(record.request);
    qualifyPublishingAttemptEvidence([record.publication], nativeScope);
    if (identity) assert.deepEqual(record.publication, identity, 'Receiver publication changed');
    else identity = record.publication;
    const stage = staged ? stages[p.stage - 1] : accepted;
    assert.ok(stage, 'Unknown probe stage');
    assert.equal(p.convention, staged ? 'mpegts-null-probe-v2' : 'mpegts-null-probe-v1');
    assert.equal(p.id, stage.id.toLowerCase());
    assert.equal(p.publishingGeneration, accepted.publishingGeneration);
    assert.equal(p.bitRate, staged ? stage.bitRate : 1000000);
    assert.ok(
      Number(p.deliveredPayloadBytes) <= stage.acceptedPayloadBytes,
      'Receiver exceeded native acceptance',
    );
    if (staged) {
      assert.equal(
        Number(p.totalDeliveredPayloadBytes) - Number(p.deliveredPayloadBytes),
        stage.base,
      );
      assert.ok(
        Number(p.deliveredPayloadBytes) + (p.pendingPackets ? 1316 : 0) <=
          stage.acceptedPayloadBytes,
      );
      assert.ok(Number(p.totalDeliveredPayloadBytes) <= stage.totalAcceptedPayloadBytes);
      if (!prior) assert.equal(p.stage, 1);
      else assert.ok(p.stage === prior.probe.stage || p.stage === prior.probe.stage + 1);
    }
    const at = Number(p.observedAtNanoseconds) / 1e6;
    // One receiver clock offset must fit every authenticated request/response interval.
    // This rejects cached, reversed and discontinuous receiver timestamps.
    offsetLower = Math.max(offsetLower, request.startedAtMilliseconds - at);
    offsetUpper = Math.min(offsetUpper, request.receivedAtMilliseconds - at);
    assert.ok(offsetLower <= offsetUpper, 'Receiver clock does not fit observation bounds');
    if (prior) {
      assert.ok(request.startedAtMilliseconds >= prior.request.receivedAtMilliseconds);
      assert.ok(BigInt(p.observedAtNanoseconds) >= BigInt(prior.probe.observedAtNanoseconds));
      if (staged && p.stage !== prior.probe.stage) {
        if (p.firstDeliveredAtNanoseconds !== undefined)
          assert.ok(
            BigInt(p.firstDeliveredAtNanoseconds) >= BigInt(prior.probe.observedAtNanoseconds),
          );
      } else {
        assertReceiverProbeProgress(p, prior.probe);
      }
    }
    prior = { probe: p, request };
  }
  const p = prior.probe;
  if (staged) assert.equal(p.stage, 3);
  assert.equal(p.pendingPackets, 0, 'Incomplete terminal probe message');
  assert.equal(
    Number(staged ? p.totalDeliveredPayloadBytes : p.deliveredPayloadBytes),
    accepted.acceptedPayloadBytes,
    'Receiver did not deliver all accepted probe messages',
  );
  const seconds =
    Number(BigInt(p.lastDeliveredAtNanoseconds) - BigInt(p.firstDeliveredAtNanoseconds)) / 1e9;
  const messages = Number(p.deliveredMessages);
  return {
    ...(staged ? { stageCount: 3 } : {}),
    probeId: p.id,
    publishingGeneration: p.publishingGeneration,
    publicationId: identity.publicationId,
    deliveredMessages: staged ? accepted.acceptedPayloadBytes / 1316 : messages,
    deliveredPayloadBytes: staged ? accepted.acceptedPayloadBytes : Number(p.deliveredPayloadBytes),
    observationCount: records.length,
    receiverReadSpanSeconds: staged ? null : seconds,
    averageDeliveredPayloadMbps:
      !staged && seconds > 0 ? ((messages - 1) * 1316 * 8) / seconds / 1e6 : null,
    clockOffsetBoundMilliseconds: [offsetLower, offsetUpper],
    receiverCapacityQualified: false,
  };
}
