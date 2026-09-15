import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHmac } from 'node:crypto';
import {
  recordWorkerPublicationEvidence,
  qualifyWorkerPublicationEvidence,
} from '../worker-publication-evidence.mjs';
const secret = 'fixture-installation-secret';
const scope = {
  gameId: 'match',
  generation: 1,
  selection: {
    workerId: 'mac',
    outputId: 'local',
    captureDeviceId: 'phone',
    recordingId: 'archive',
  },
};
const hmac = (v) => createHmac('sha256', secret).update(JSON.stringify(v)).digest('hex');
const path = `scorebug-${hmac(['scorebug-ingest-v1', 'installation', '']).slice(0, 16)}-${hmac(['scorebug-ingest-v1', 'path', JSON.stringify(['match', 'mac', 'local', 'phone', 'archive', 1])]).slice(0, 32)}`;
const readerId = '11111111-1111-4111-8111-111111111111',
  publisherId = '22222222-2222-4222-8222-222222222222',
  attempt = '33333333-3333-4333-8333-333333333333',
  epoch = '44444444-4444-4444-8444-444444444444',
  readId = '55555555-5555-4555-8555-555555555555';
const clock = { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '9000' };
const status = () => ({
  gameId: 'match',
  generation: 1,
  workerId: 'mac',
  workerEpoch: epoch,
  state: 'producing_output',
  publication: { readerId, publisherId, publishingAttemptId: attempt, clock },
  observation: {
    gameId: 'match',
    generation: 1,
    attempt: 1,
    state: 'producing_output',
    decodedVideo: {
      clock: 'mpegts-pts-90k-v1',
      ended: false,
      invalidReason: null,
      completed: {
        sequence: 1,
        durationMs: 5000,
        freshFrames: 150,
        duplicateFrames: 0,
        reorderedFrames: 0,
        valid: true,
      },
    },
  },
});
const listing = () => ({
  pageCount: 1,
  itemCount: 2,
  items: [
    {
      id: readerId,
      path,
      state: 'read',
      query: 'sbw1=' + readId,
      scorebugReaderSource: { type: 'srtConn', id: publisherId },
      remoteAddr: 'private-address',
    },
    {
      id: publisherId,
      path,
      state: 'publish',
      query: `sbp1=${attempt}.${hmac(['scorebug-publish-attempt-v1', path, attempt])}`,
      scorebugTransportClock: clock,
    },
  ],
});
const native = {
  matchID: 'match',
  broadcastGeneration: 1,
  recordingID: 'archive',
  publishingAttemptID: attempt.toUpperCase(),
};
function record(evidence, s = status(), l = listing()) {
  recordWorkerPublicationEvidence(evidence, s, l, scope, secret);
}
test('requires actual private reader/source/origin and native scope while retaining only public fields', () => {
  const evidence = new Map();
  record(evidence);
  const next = status();
  next.observation.decodedVideo.completed.sequence = 2;
  record(evidence, next);
  const rows = qualifyWorkerPublicationEvidence([...evidence.values()], native);
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].completedWindows, [1, 2]);
  assert.equal(rows[0].publication.publisherId, publisherId);
  const encoded = JSON.stringify(rows);
  for (const value of ['sbw1=', 'sbp1=', 'private-address', readId, secret])
    assert.ok(!encoded.includes(value));
});
for (const [name, mutate] of Object.entries({
  source: (s, l) => (l.items[0].scorebugReaderSource.id = readerId),
  path: (s, l) => (l.items[0].path += 'x'),
  origin: (s, l) => (l.items[1].scorebugTransportClock = { ...clock, originPTS: '9001' }),
  signature: (s, l) => (l.items[1].query = l.items[1].query.slice(0, -1) + 'z'),
  nonce: (s, l) => (l.items[0].query = 'sbr1=' + readId),
  epoch: (s) => (s.workerEpoch += '\n'),
  attempt: (s) => (s.publication.publishingAttemptId = readerId),
  observation: (s) => (s.observation.generation = 2),
  duplicate: (s, l) => {
    l.items.push({ ...l.items[0] });
    l.itemCount++;
  },
  incomplete: (s, l) => (l.pageCount = 2),
  worker: (s) => (s.workerId = 'other'),
  clock: (s) => (s.publication.clock = { ...clock, originPTS: '09000' }),
}))
  test('rejects ' + name, () => {
    const s = structuredClone(status()),
      l = structuredClone(listing());
    mutate(s, l);
    assert.throws(() => record(new Map(), s, l));
  });
test('ignores absent mapping, stopped status or connections gone between the two observations', () => {
  for (const s of [
    { ...status(), publication: undefined },
    { ...status(), state: 'stale' },
  ]) {
    const m = new Map();
    record(m, s);
    assert.equal(m.size, 0);
  }
  const m = new Map();
  record(m, status(), { pageCount: 0, itemCount: 0, items: [] });
  assert.equal(m.size, 0);
});
test('rejects missing/insufficient windows and wrong native attempt', () => {
  assert.throws(() => qualifyWorkerPublicationEvidence([], native));
  const m = new Map();
  record(m);
  assert.throws(() => qualifyWorkerPublicationEvidence([...m.values()], native));
  const next = status();
  next.observation.decodedVideo.completed.sequence = 2;
  record(m, next);
  assert.throws(() =>
    qualifyWorkerPublicationEvidence([...m.values()], { ...native, publishingAttemptID: readerId }),
  );
});
test('does not accept changed publication inside one worker attempt or exceed bounded collection', () => {
  const m = new Map();
  record(m);
  const s = status(),
    l = listing();
  s.publication.readerId = readId;
  l.items[0].id = readId;
  assert.throws(() => record(m, s, l));
  const full = new Map(Array.from({ length: 16 }, (_, i) => [i, {}]));
  assert.throws(() => record(full));
});
test('final artifact qualification rejects duplicated windows and malformed identity', () => {
  const map = new Map();
  record(map);
  const next = status();
  next.observation.decodedVideo.completed.sequence = 2;
  record(map, next);
  const rows = [...map.values()];
  for (const mutate of [
    (r) => {
      r.completedWindows = [1, 1];
    },
    (r) => {
      r.workerEpoch = 'invalid';
    },
    (r) => {
      r.publication.clock.originPTS = '09000';
    },
    (r) => {
      r.completedWindows = [1, 1.5];
    },
  ]) {
    const changed = structuredClone(rows);
    mutate(changed[0]);
    assert.throws(() => qualifyWorkerPublicationEvidence(changed, native));
  }
  assert.throws(() => qualifyWorkerPublicationEvidence([...rows, ...rows], native));
});
