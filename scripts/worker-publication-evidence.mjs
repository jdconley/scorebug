import assert from 'node:assert/strict';
import {
  recordPublishingAttemptEvidence,
  qualifyPublishingAttemptEvidence,
} from './publishing-attempt-evidence.mjs';
const uuid = (value) =>
  typeof value === 'string' &&
  value.length === 36 &&
  /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value);

/** Independent bounded fixture oracle. Never saves the private read nonce or signed query. */
export function recordWorkerPublicationEvidence(evidence, status, listing, scope, secret) {
  assert.ok(evidence instanceof Map && evidence.size <= 16, 'Worker publication collection bound');
  if (!status.publication || !['starting', 'producing_output'].includes(status.state)) return;
  const { publication, observation } = status;
  assert.ok(uuid(status.workerEpoch), 'Invalid reporting epoch');
  assert.equal(status.gameId, scope.gameId);
  assert.equal(status.generation, scope.generation);
  assert.equal(status.workerId, scope.selection.workerId);
  assert.equal(observation?.gameId, status.gameId);
  assert.equal(observation?.generation, status.generation);
  assert.equal(observation?.state, status.state);
  assert.ok(Number.isSafeInteger(observation?.attempt) && observation.attempt > 0);
  for (const value of [
    publication.readerId,
    publication.publisherId,
    publication.publishingAttemptId,
  ])
    assert.ok(uuid(value), 'Invalid publication UUID');
  assert.notEqual(publication.readerId, publication.publisherId);
  const verified = new Map();
  recordPublishingAttemptEvidence(verified, listing, scope, secret);
  const readers = listing.items.filter((item) => item.id === publication.readerId);
  const publishers = listing.items.filter((item) => item.id === publication.publisherId);
  // Status and private inventory are sequential observations; a connection may finish between them.
  if (!readers.length || !publishers.length) return;
  assert.equal(readers.length, 1, 'Ambiguous reader');
  assert.equal(publishers.length, 1, 'Ambiguous publisher');
  const reader = readers[0],
    publisher = publishers[0],
    proof = verified.get(publication.publisherId);
  assert.ok(proof, 'Missing authenticated native publication');
  assert.equal(reader.state, 'read');
  assert.equal(reader.path, proof.path);
  assert.equal(
    listing.items.filter((item) => item.state === 'read' && item.path === proof.path).length,
    1,
    'Fixture must own exactly one worker reader',
  );
  assert.ok(
    typeof reader.query === 'string' &&
      reader.query.length === 41 &&
      reader.query.startsWith('sbw1=') &&
      uuid(reader.query.slice(5)),
    'Missing actual worker read marker',
  );
  assert.deepEqual(reader.scorebugReaderSource, { type: 'srtConn', id: publication.publisherId });
  assert.equal(publication.publishingAttemptId, proof.publishingAttemptId);
  assert.deepEqual(publication.clock, publisher.scorebugTransportClock);
  assert.equal(publication.clock.convention, 'mpegts-ingress-origin-90k-v1');
  const origin = publication.clock.originPTS;
  assert.ok(
    typeof origin === 'string' &&
      origin.length <= 10 &&
      /^(0|[1-9][0-9]*)$/.test(origin) &&
      String(Number(origin)) === origin &&
      Number(origin) < 2 ** 33,
  );
  const record = {
    gameId: status.gameId,
    generation: status.generation,
    recordingId: proof.recordingId,
    workerId: status.workerId,
    workerEpoch: status.workerEpoch,
    attempt: observation.attempt,
    publication: {
      readerId: publication.readerId,
      publisherId: publication.publisherId,
      publishingAttemptId: publication.publishingAttemptId,
      clock: { ...publication.clock },
    },
  };
  const key = JSON.stringify([
    record.gameId,
    record.generation,
    record.workerId,
    record.workerEpoch,
    record.attempt,
  ]);
  const previous = evidence.get(key);
  if (previous) {
    const { completedWindows, ...prior } = previous;
    assert.deepEqual(record, prior, 'Publication changed within one worker attempt');
  } else assert.ok(evidence.size < 16, 'Worker publication collection bound');
  const completedWindows = [...(previous?.completedWindows ?? [])];
  const video = observation.decodedVideo,
    window = video?.completed;
  if (
    status.state === 'producing_output' &&
    video?.clock === 'mpegts-pts-90k-v1' &&
    !video.ended &&
    video.invalidReason === null &&
    window?.valid &&
    window.durationMs === 5000 &&
    window.freshFrames >= 120 &&
    window.duplicateFrames === 0 &&
    window.reorderedFrames === 0
  ) {
    assert.ok(Number.isSafeInteger(window.sequence) && window.sequence > 0);
    if (!completedWindows.includes(window.sequence)) {
      assert.ok(completedWindows.length < 128);
      completedWindows.push(window.sequence);
    }
  }
  evidence.set(key, { ...record, completedWindows });
}

export function qualifyWorkerPublicationEvidence(records, nativeScope) {
  assert.ok(
    Array.isArray(records) && records.length > 0 && records.length <= 16,
    'Missing bounded worker publication evidence',
  );
  const scopes = new Set();
  for (const record of records) {
    assert.ok(record && typeof record === 'object');
    for (const id of [
      record.workerEpoch,
      record.publication?.readerId,
      record.publication?.publisherId,
      record.publication?.publishingAttemptId,
    ])
      assert.ok(uuid(id));
    assert.notEqual(record.publication.readerId, record.publication.publisherId);
    assert.ok(
      typeof record.workerId === 'string' &&
        record.workerId.length > 0 &&
        record.workerId.length <= 128 &&
        !/[^A-Za-z0-9_-]/.test(record.workerId),
    );
    assert.ok(Number.isSafeInteger(record.attempt) && record.attempt > 0);
    const origin = record.publication.clock?.originPTS;
    assert.equal(record.publication.clock?.convention, 'mpegts-ingress-origin-90k-v1');
    assert.ok(
      typeof origin === 'string' &&
        origin.length <= 10 &&
        /^(0|[1-9][0-9]*)$/.test(origin) &&
        String(Number(origin)) === origin &&
        Number(origin) < 2 ** 33,
    );
    assert.ok(Array.isArray(record.completedWindows) && record.completedWindows.length <= 128);
    assert.ok(
      record.completedWindows.every((sequence) => Number.isSafeInteger(sequence) && sequence > 0),
    );
    assert.equal(new Set(record.completedWindows).size, record.completedWindows.length);
    const scope = JSON.stringify([
      record.gameId,
      record.generation,
      record.workerId,
      record.workerEpoch,
      record.attempt,
    ]);
    assert.ok(!scopes.has(scope));
    scopes.add(scope);
  }
  assert.ok(
    records.some((record) => record.completedWindows.length >= 2),
    'Need two decoded windows associated with the actual publication',
  );
  qualifyPublishingAttemptEvidence(
    records.map((record) => ({
      publicationId: record.publication.publisherId,
      gameId: record.gameId,
      generation: record.generation,
      recordingId: record.recordingId,
      publishingAttemptId: record.publication.publishingAttemptId,
    })),
    nativeScope,
  );
  return structuredClone(records);
}
