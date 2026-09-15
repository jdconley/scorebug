import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHmac } from 'node:crypto';
import {
  recordPublishingAttemptEvidence,
  qualifyPublishingAttemptEvidence,
} from '../publishing-attempt-evidence.mjs';

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
const attempt = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
const native = {
  matchID: 'match',
  broadcastGeneration: 1,
  recordingID: 'archive',
  publishingAttemptID: attempt.toUpperCase(),
  appliedProfileRevision: 1,
};
const hmac = (value) => createHmac('sha256', secret).update(JSON.stringify(value)).digest('hex');
const identity = JSON.stringify(['match', 'mac', 'local', 'phone', 'archive', 1]);
const path = `scorebug-${hmac(['scorebug-ingest-v1', 'installation', '']).slice(0, 16)}-${hmac(['scorebug-ingest-v1', 'path', identity]).slice(0, 32)}`;
const connection = () => ({
  id: '11111111-2222-4333-8444-555555555555',
  state: 'publish',
  path,
  query: `sbp1=${attempt}.${hmac(['scorebug-publish-attempt-v1', path, attempt])}`,
  user: 'private-user',
  remoteAddr: 'private-address',
});
const list = (items) => ({ pageCount: 1, itemCount: items.length, items });

test('retains only independently verified scope and connection identity, idempotently', () => {
  const evidence = new Map();
  recordPublishingAttemptEvidence(evidence, list([connection(), { state: 'read' }]), scope, secret);
  recordPublishingAttemptEvidence(evidence, list([connection()]), scope, secret);
  assert.equal(evidence.size, 1);
  const records = [...evidence.values()];
  assert.deepEqual(records, [
    {
      publicationId: connection().id,
      path,
      gameId: 'match',
      generation: 1,
      recordingId: 'archive',
      publishingAttemptId: attempt,
    },
  ]);
  assert.deepEqual(qualifyPublishingAttemptEvidence(records, native), records);
  assert.ok(!JSON.stringify(records).includes('private'));
  assert.ok(!JSON.stringify(records).includes('sbp1='));
});

for (const change of [
  (c) => ({ ...c, query: undefined }),
  (c) => ({ ...c, query: c.query + '\n' }),
  (c) => ({ ...c, query: c.query.replace(attempt, c.id) }),
  (c) => ({ ...c, query: c.query + '&extra=1' }),
  (c) => ({ ...c, path: c.path + 'x' }),
  (c) => ({ ...c, id: 'invalid' }),
  (c) => ({ ...c, query: 'x'.repeat(10000) }),
])
  test('rejects missing, tampered, unscoped or oversized connection evidence', () => {
    assert.throws(() =>
      recordPublishingAttemptEvidence(new Map(), list([change(connection())]), scope, secret),
    );
  });

test('rejects wrong signing secret, generation, recording and selected capture', () => {
  assert.throws(() =>
    recordPublishingAttemptEvidence(
      new Map(),
      list([connection()]),
      scope,
      'another-fixture-secret',
    ),
  );
  for (const changed of [
    { ...scope, generation: 2 },
    { ...scope, gameId: 'other' },
    { ...scope, selection: { ...scope.selection, recordingId: 'other' } },
    { ...scope, selection: { ...scope.selection, captureDeviceId: 'other' } },
  ])
    assert.throws(() =>
      recordPublishingAttemptEvidence(new Map(), list([connection()]), changed, secret),
    );
});

test('rejects incomplete listings, changed publication and collection overflow', () => {
  for (const invalid of [
    { ...list([]), pageCount: 2 },
    { ...list([]), itemCount: 1 },
    { pageCount: 1, itemCount: 101, items: Array(101).fill(connection()) },
  ])
    assert.throws(() => recordPublishingAttemptEvidence(new Map(), invalid, scope, secret));
  const evidence = new Map();
  recordPublishingAttemptEvidence(evidence, list([connection()]), scope, secret);
  const other = 'bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee';
  assert.throws(() =>
    recordPublishingAttemptEvidence(
      evidence,
      list([
        {
          ...connection(),
          query: `sbp1=${other}.${hmac(['scorebug-publish-attempt-v1', path, other])}`,
        },
      ]),
      scope,
      secret,
    ),
  );
  for (let i = 1; i < 16; i++)
    recordPublishingAttemptEvidence(
      evidence,
      list([
        { ...connection(), id: `${i.toString(16).padStart(8, '0')}-2222-4333-8444-555555555555` },
      ]),
      scope,
      secret,
    );
  assert.throws(() =>
    recordPublishingAttemptEvidence(
      evidence,
      list([{ ...connection(), id: 'ffffffff-2222-4333-8444-555555555555' }]),
      scope,
      secret,
    ),
  );
});

test('requires actual evidence matching the exported native attempt, generation and recording', () => {
  assert.throws(() => qualifyPublishingAttemptEvidence([], native));
  const evidence = new Map();
  recordPublishingAttemptEvidence(evidence, list([connection()]), scope, secret);
  for (const changed of [
    { ...native, publishingAttemptID: connection().id },
    { ...native, broadcastGeneration: 2 },
    { ...native, recordingID: 'other' },
    { ...native, matchID: 'other' },
  ])
    assert.throws(() => qualifyPublishingAttemptEvidence([...evidence.values()], changed));
});
