import assert from 'node:assert/strict';
import test from 'node:test';
import { saveNativeStatusEvidence } from '../native-status-evidence.mjs';

function fixture() {
  return {
    artifact: '/owned',
    decodedWindowLimit: 64,
    requirePublication: true,
    collectorError: undefined,
    publications: new Map([['a', { publicationId: 'a' }]]),
    workerPublications: new Map([['b', { attempt: 1 }]]),
    workerProcessing: new Map([['c', { sequence: 1 }]]),
    decodedWindows: new Map([['d', { completed: { sequence: 1 } }]]),
  };
}
test('persists all bounded histories including empty ones without mutating them', async () => {
  const f = fixture(),
    writes = new Map(),
    before = structuredClone(f);
  await saveNativeStatusEvidence(f, async (path, value) => writes.set(path, JSON.parse(value)));
  assert.equal(writes.size, 5);
  assert.deepEqual(writes.get('/owned/decoded-video-status.json'), [...f.decodedWindows.values()]);
  assert.deepEqual(writes.get('/owned/status-collector.json'), { stopped: true, failed: false });
  assert.deepEqual(f, before);
  f.requirePublication = false;
  for (const map of [f.publications, f.workerPublications, f.workerProcessing, f.decodedWindows])
    map.clear();
  writes.clear();
  await saveNativeStatusEvidence(f, async (path, value) => writes.set(path, JSON.parse(value)));
  assert.equal(writes.size, 4);
  assert.deepEqual(writes.get('/owned/worker-processing-status.json'), []);
  assert.deepEqual(writes.get('/owned/status-collector.json'), { stopped: true, failed: false });
});
test('attempts remaining histories when one write fails, then reports failure', async () => {
  const attempted = [],
    failure = new Error('disk failure');
  await assert.rejects(
    saveNativeStatusEvidence(fixture(), async (path) => {
      attempted.push(path);
      if (path.endsWith('publishing-attempt-status.json')) throw failure;
    }),
    (e) => e instanceof AggregateError && e.errors.includes(failure),
  );
  assert.equal(attempted.length, 5);
  assert.ok(attempted.some((p) => p.endsWith('decoded-video-status.json')));
});
test('retains collector and write failures while serializing only a failure flag', async () => {
  const f = fixture(),
    original = new Error('private collector detail'),
    disk = new Error('disk');
  f.collectorError = original;
  const saved = new Map();
  await assert.rejects(
    saveNativeStatusEvidence(f, async (path, value) => {
      saved.set(path, value);
      if (path.endsWith('publishing-attempt-status.json')) throw disk;
    }),
    (e) => e instanceof AggregateError && e.errors[0] === original && e.errors.includes(disk),
  );
  assert.equal(saved.size, 5);
  assert.ok([...saved.values()].every((v) => !v.includes('private collector detail')));
  assert.deepEqual(JSON.parse(saved.get('/owned/status-collector.json')), {
    stopped: true,
    failed: true,
  });
});
test('refuses count/byte overflow while preserving the other bounded files', async () => {
  for (const corrupt of [
    (f) => (f.publications = new Map(Array.from({ length: 17 }, (_, i) => [i, {}]))),
    (f) => (f.decodedWindows = new Map(Array.from({ length: 65 }, (_, i) => [i, {}]))),
    (f) => f.workerProcessing.set('huge', { text: 'x'.repeat(4 * 1024 * 1024) }),
  ]) {
    const f = fixture(),
      attempted = [];
    corrupt(f);
    await assert.rejects(
      saveNativeStatusEvidence(f, async (path) => attempted.push(path)),
      AggregateError,
    );
    assert.equal(attempted.length, 4);
    assert.ok(attempted.includes('/owned/status-collector.json'));
  }
});
test('receiver probe evidence is retained alongside other histories on collector failure', async () => {
  const f = fixture(),
    writes = new Map();
  f.requireReceiverProbe = true;
  f.receiverProbes = new Map([[0, { probe: { id: 'probe' } }]]);
  f.collectorError = new Error('probe validation failed');
  await assert.rejects(
    saveNativeStatusEvidence(f, async (path, value) => writes.set(path, JSON.parse(value))),
    AggregateError,
  );
  assert.deepEqual(writes.get('/owned/receiver-probe-status.json'), [...f.receiverProbes.values()]);
  assert.equal(writes.get('/owned/status-collector.json').failed, true);
});
