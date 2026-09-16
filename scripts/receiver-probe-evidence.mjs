import assert from 'node:assert/strict';
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
function probeSnapshot(p) {
  assert.ok(p && typeof p === 'object');
  assert.equal(p.convention, 'mpegts-null-probe-v1');
  assert.ok(uuid(p.id) && p.id !== '00000000-0000-0000-0000-000000000000');
  assert.ok(integer(p.publishingGeneration) > 0n);
  assert.ok(Number.isSafeInteger(p.bitRate) && p.bitRate > 0 && p.bitRate <= 2000000);
  assert.equal(p.invalidReason, undefined, 'Invalid receiver proof');
  const messages = integer(p.deliveredMessages, BigInt(Math.floor((16 * 1024 * 1024) / 1316)));
  assert.equal(integer(p.deliveredPayloadBytes, 16n * 1024n * 1024n), messages * 1316n);
  assert.equal(integer(p.nextSequence), messages);
  assert.ok(Number.isInteger(p.pendingPackets) && p.pendingPackets >= 0 && p.pendingPackets <= 6);
  const at = integer(p.observedAtNanoseconds, 86400000000000n);
  if (messages > 0n) {
    const first = integer(p.firstDeliveredAtNanoseconds, at),
      last = integer(p.lastDeliveredAtNanoseconds, at);
    assert.ok(first <= last);
  } else {
    assert.equal(p.firstDeliveredAtNanoseconds, undefined);
    assert.equal(p.lastDeliveredAtNanoseconds, undefined);
  }
  return Object.fromEntries(
    [
      'convention',
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
      probe: probeSnapshot(connection.scorebugBandwidthProbe),
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
  assert.ok(
    uuid(accepted.id?.toLowerCase()) &&
      Number.isSafeInteger(accepted.acceptedPayloadBytes) &&
      accepted.acceptedPayloadBytes > 0,
  );
  let prior,
    identity,
    offsetLower = -Infinity,
    offsetUpper = Infinity;
  for (const record of records) {
    const p = probeSnapshot(record.probe),
      request = requestBounds(record.request);
    qualifyPublishingAttemptEvidence([record.publication], nativeScope);
    if (identity) assert.deepEqual(record.publication, identity, 'Receiver publication changed');
    else identity = record.publication;
    assert.equal(p.id, accepted.id.toLowerCase());
    assert.equal(p.publishingGeneration, accepted.publishingGeneration);
    assert.equal(p.bitRate, 1000000);
    assert.ok(
      Number(p.deliveredPayloadBytes) <= accepted.acceptedPayloadBytes,
      'Receiver exceeded native acceptance',
    );
    const at = Number(p.observedAtNanoseconds) / 1e6;
    // One receiver clock offset must fit every authenticated request/response interval.
    // This rejects cached, reversed and discontinuous receiver timestamps.
    offsetLower = Math.max(offsetLower, request.startedAtMilliseconds - at);
    offsetUpper = Math.min(offsetUpper, request.receivedAtMilliseconds - at);
    assert.ok(offsetLower <= offsetUpper, 'Receiver clock does not fit observation bounds');
    if (prior) {
      assert.ok(request.startedAtMilliseconds >= prior.request.receivedAtMilliseconds);
      assert.ok(BigInt(p.observedAtNanoseconds) >= BigInt(prior.probe.observedAtNanoseconds));
      assert.ok(BigInt(p.deliveredMessages) >= BigInt(prior.probe.deliveredMessages));
      const completed = BigInt(p.deliveredMessages),
        previousCompleted = BigInt(prior.probe.deliveredMessages);
      assert.ok(
        completed * 7n + BigInt(p.pendingPackets) >=
          previousCompleted * 7n + BigInt(prior.probe.pendingPackets),
        'Receiver packet progress reversed',
      );
      if (completed > previousCompleted) {
        assert.ok(
          BigInt(p.lastDeliveredAtNanoseconds) >= BigInt(prior.probe.observedAtNanoseconds),
          'New receiver delivery predates prior observation',
        );
        if (previousCompleted === 0n)
          assert.ok(
            BigInt(p.firstDeliveredAtNanoseconds) >= BigInt(prior.probe.observedAtNanoseconds),
            'First receiver delivery predates prior observation',
          );
      }

      if (prior.probe.firstDeliveredAtNanoseconds !== undefined) {
        assert.equal(p.firstDeliveredAtNanoseconds, prior.probe.firstDeliveredAtNanoseconds);
        assert.ok(
          BigInt(p.lastDeliveredAtNanoseconds) >= BigInt(prior.probe.lastDeliveredAtNanoseconds),
        );
        if (p.deliveredMessages === prior.probe.deliveredMessages)
          assert.equal(p.lastDeliveredAtNanoseconds, prior.probe.lastDeliveredAtNanoseconds);
      }
    }
    prior = { probe: p, request };
  }
  const p = prior.probe;
  assert.equal(p.pendingPackets, 0, 'Incomplete terminal probe message');
  assert.equal(
    Number(p.deliveredPayloadBytes),
    accepted.acceptedPayloadBytes,
    'Receiver did not deliver all accepted probe messages',
  );
  const seconds =
    Number(BigInt(p.lastDeliveredAtNanoseconds) - BigInt(p.firstDeliveredAtNanoseconds)) / 1e9;
  const messages = Number(p.deliveredMessages);
  return {
    probeId: p.id,
    publishingGeneration: p.publishingGeneration,
    publicationId: identity.publicationId,
    deliveredMessages: messages,
    deliveredPayloadBytes: Number(p.deliveredPayloadBytes),
    observationCount: records.length,
    receiverReadSpanSeconds: seconds,
    averageDeliveredPayloadMbps: seconds > 0 ? ((messages - 1) * 1316 * 8) / seconds / 1e6 : null,
    clockOffsetBoundMilliseconds: [offsetLower, offsetUpper],
    receiverCapacityQualified: false,
  };
}
