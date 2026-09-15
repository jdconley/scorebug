import assert from 'node:assert/strict';
import { createHmac, timingSafeEqual } from 'node:crypto';

const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;
const validUUID = (value) => typeof value === 'string' && value.length === 36 && uuid.test(value);
const validId = (value) =>
  typeof value === 'string' &&
  value.length > 0 &&
  value.length <= 128 &&
  !/[^A-Za-z0-9_-]/.test(value);

/** Independent finite-fixture oracle; never persists private relay query/user/address. */
export function recordPublishingAttemptEvidence(evidence, listing, scope, secret) {
  assert.ok(evidence instanceof Map && evidence.size <= 16, 'Publication collection bound');
  assert.ok(typeof secret === 'string' && secret.length >= 16, 'Invalid fixture secret');
  const { gameId, generation, selection } = scope;
  assert.ok(
    selection &&
      [
        gameId,
        selection.workerId,
        selection.outputId,
        selection.captureDeviceId,
        selection.recordingId,
      ].every(validId),
    'Invalid publication scope',
  );
  assert.ok(Number.isSafeInteger(generation) && generation > 0, 'Invalid publication generation');
  const hmac = (value) => createHmac('sha256', secret).update(JSON.stringify(value)).digest('hex');
  const identity = JSON.stringify([
    gameId,
    selection.workerId,
    selection.outputId,
    selection.captureDeviceId,
    selection.recordingId,
    generation,
  ]);
  const path = `scorebug-${hmac(['scorebug-ingest-v1', 'installation', '']).slice(0, 16)}-${hmac(['scorebug-ingest-v1', 'path', identity]).slice(0, 32)}`;
  assert.ok(listing && [0, 1].includes(listing.pageCount), 'Incomplete relay connection list');
  assert.ok(Array.isArray(listing.items) && listing.items.length <= 100, 'Connection list bound');
  assert.equal(listing.itemCount, listing.items.length, 'Incomplete relay connection count');
  for (const connection of listing.items) {
    if (connection.state !== 'publish') continue;
    assert.ok(validUUID(connection.id), 'Invalid publication ID');
    assert.equal(connection.path, path, 'Publisher path differs from authorized scope');
    assert.ok(
      typeof connection.query === 'string' && connection.query.length === 106,
      'Missing bounded attempt proof',
    );
    const matched = /^sbp1=([0-9a-f-]{36})\.([0-9a-f]{64})$/.exec(connection.query);
    assert.ok(matched && validUUID(matched[1]), 'Malformed attempt proof');
    const publishingAttemptId = matched[1];
    const expected = hmac(['scorebug-publish-attempt-v1', path, publishingAttemptId]);
    assert.ok(
      timingSafeEqual(Buffer.from(expected, 'hex'), Buffer.from(matched[2], 'hex')),
      'Unverified publishing attempt',
    );
    const record = {
      publicationId: connection.id,
      path,
      gameId,
      generation,
      recordingId: selection.recordingId,
      publishingAttemptId,
    };
    const prior = evidence.get(record.publicationId);
    if (prior) assert.deepEqual(record, prior, 'Publication identity changed');
    else {
      assert.ok(evidence.size < 16, 'Publication collection bound');
      evidence.set(record.publicationId, record);
    }
  }
}

/** Match privately verified relay evidence to the independently exported native scope. */
export function qualifyPublishingAttemptEvidence(records, nativeScope) {
  assert.ok(
    Array.isArray(records) && records.length > 0 && records.length <= 16,
    'Missing bounded relay attempt evidence',
  );
  assert.ok(
    typeof nativeScope.publishingAttemptID === 'string' &&
      validUUID(nativeScope.publishingAttemptID.toLowerCase()),
    'Invalid native attempt',
  );
  for (const record of records) {
    assert.equal(
      record.publishingAttemptId,
      nativeScope.publishingAttemptID.toLowerCase(),
      'Relay/native attempt mismatch',
    );
    assert.equal(record.gameId, nativeScope.matchID, 'Relay/native match mismatch');
    assert.equal(record.recordingId, nativeScope.recordingID, 'Relay/native recording mismatch');
    assert.equal(
      record.generation,
      nativeScope.broadcastGeneration,
      'Relay/native generation mismatch',
    );
  }
  return structuredClone(records);
}
