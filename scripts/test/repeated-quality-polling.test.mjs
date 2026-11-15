import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { repeatedMeasuredPolicyFixture } from './fixtures/repeated-measured-policy-evidence.mjs';
const {
  RepeatedQualityPolling,
  readRepeatedCheckpoint,
  repeatedFaultStatusReady,
  repeatedFaultOwnerMatches,
} = await import('../repeated-quality-polling.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
function fixture() {
  const f = repeatedMeasuredPolicyFixture();
  const checkpoint = (revision, end) => {
    const length = revision
      ? f.quality.events.findIndex((e) => e.revision === revision && e.window?.end === end) + 1
      : f.quality.events.length;
    return {
      formatVersion: 1,
      mode: 'repeated',
      publishingAttemptID: f.scope.publishingAttemptID,
      eventCount: length,
      closed: !revision,
      quality: {
        ...structuredClone(f.quality),
        events: structuredClone(f.quality.events.slice(0, length)),
      },
    };
  };
  let value = checkpoint('1', 154),
    now = 0,
    reads = 0;
  const abort = new AbortController();
  const options = {
    publishingAttemptID: f.scope.publishingAttemptID,
    sourceOwner: (() => {
      const source = value.quality.events.at(-1).source;
      return Object.fromEntries(
        ['workerID', 'workerEpoch', 'workerAttempt', 'readerID'].map((key) => [key, source[key]]),
      );
    })(),
    matchID: f.scope.matchID,
    broadcastGeneration: f.scope.broadcastGeneration,
    signal: abort.signal,
    read: async () => {
      reads++;
      return value;
    },
    now: () => now,
    wait: async (ms) => {
      now += ms;
    },
  };
  return {
    f,
    checkpoint,
    options,
    abort,
    set: (v) => {
      value = v;
    },
    time: (v) => {
      now = v;
    },
    reads: () => reads,
  };
}
test('polls missing checkpoints then joins two original claims and terminal history', async () => {
  assert.equal(typeof RepeatedQualityPolling, 'function');
  const x = fixture();
  let calls = 0;
  const session = new RepeatedQualityPolling({
    ...x.options,
    read: async () =>
      ++calls === 1 ? null : x.checkpoint(calls < 4 ? '1' : '3', calls < 4 ? 154 : 214),
  });
  const first = await session.awaitReady('1');
  assert.equal(first.campaign, '1');
  assert.deepEqual(session.scope, x.f.scope);
  await session.validateReady(first);
  const second = await session.awaitReady('2');
  assert.equal(second.campaign, '2');
  assert.equal(session.reconcile(x.checkpoint(), x.f.quality).liveCheckpointReconciled, true);
});
test('deadline is shared by both campaigns and cannot reset on missing files', async () => {
  const x = fixture();
  let reads = 0;
  const session = new RepeatedQualityPolling({
    ...x.options,
    read: async () => {
      reads++;
      return null;
    },
  });
  await assert.rejects(session.awaitReady('1'), /timed out/);
  assert.equal(reads, 1800);
});
test('aborted readiness does not read or claim', async () => {
  const x = fixture();
  x.abort.abort();
  const session = new RepeatedQualityPolling(x.options);
  await assert.rejects(session.awaitReady('1'), /abort/i);
  assert.equal(x.reads(), 0);
});
test('cancellation while a checkpoint read is in flight cannot claim it', async () => {
  const x = fixture();
  const session = new RepeatedQualityPolling({
    ...x.options,
    read: async () => {
      x.abort.abort();
      return x.checkpoint('1', 154);
    },
  });
  await assert.rejects(session.awaitReady('1'), /abort/i);
});
for (const [name, mutate] of [
  ['match', (s) => (s.matchID = 'foreign')],
  ['generation', (s) => s.broadcastGeneration++],
  ['attempt', (s) => (s.publishingAttemptID = 'ffffffff-ffff-4fff-8fff-ffffffffffff')],
  ['missing recording', (s) => delete s.recordingID],
  ['malformed revision', (s) => (s.appliedProfileRevision = '01')],
])
  test(`rejects live scope ${name}`, async () => {
    const x = fixture();
    const value = x.checkpoint('1', 154);
    mutate(value.quality.events.at(-1).evidence.queue.scope);
    x.set(value);
    await assert.rejects(new RepeatedQualityPolling(x.options).awaitReady('1'));
  });
test('terminal history before readiness fails immediately', async () => {
  const x = fixture();
  x.set(x.checkpoint());
  await assert.rejects(new RepeatedQualityPolling(x.options).awaitReady('1'), /closed/);
});
test('only consecutive campaigns can be requested', async () => {
  const x = fixture();
  const session = new RepeatedQualityPolling(x.options);
  await assert.rejects(session.awaitReady('2'), /campaign/);
  await session.awaitReady('1');
  await assert.rejects(session.awaitReady('1'), /campaign/);
});
for (const mutation of ['revision', 'unhealthy', 'terminal', 'foreignClaim'])
  test(`revalidates a ready claim before pause: ${mutation}`, async () => {
    const x = fixture();
    const session = new RepeatedQualityPolling(x.options);
    const claim = await session.awaitReady('1');
    if (mutation === 'foreignClaim') claim.candidateID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    else if (mutation === 'terminal') x.set(x.checkpoint());
    else {
      const value = x.checkpoint('1', 154);
      const last = structuredClone(value.quality.events.at(-1));
      last.at++;
      if (mutation === 'revision') last.revision = '2';
      else last.state = 'unhealthy';
      value.quality.events.push(last);
      value.eventCount++;
      x.set(value);
    }
    await assert.rejects(session.validateReady(claim));
  });
test('scope and claim return values cannot mutate polling ownership', async () => {
  const x = fixture();
  const session = new RepeatedQualityPolling(x.options);
  const claim = await session.awaitReady('1');
  session.scope.recordingID = 'bad';
  await session.validateReady(claim);
  assert.deepEqual(session.scope, x.f.scope);
});
test('hard file read errors are not treated as absent checkpoint', async () => {
  const x = fixture();
  const session = new RepeatedQualityPolling({
    ...x.options,
    read: async () => {
      throw new Error('broken reader');
    },
  });
  await assert.rejects(session.awaitReady('1'), /broken reader/);
});
test('file reader bounds bytes before parsing, permits absent startup file, rejects links', async () => {
  assert.equal(typeof readRepeatedCheckpoint, 'function');
  const dir = await mkdtemp(join(tmpdir(), 'scorebug-live-checkpoint-'));
  try {
    const path = join(dir, 'quality.json');
    assert.equal(await readRepeatedCheckpoint(path), null);
    await writeFile(path, JSON.stringify({ example: true }));
    assert.deepEqual(await readRepeatedCheckpoint(path), { example: true });
    const link = join(dir, 'link.json');
    await symlink(path, link);
    await assert.rejects(readRepeatedCheckpoint(link));
    await writeFile(path, Buffer.alloc(8 * 1024 * 1024 + 1));
    await assert.rejects(readRepeatedCheckpoint(path), /Oversized/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('second campaign inherits the first campaign deadline', async () => {
  const x = fixture();
  const session = new RepeatedQualityPolling(x.options);
  await session.awaitReady('1');
  x.time(180000);
  x.set(x.checkpoint('3', 214));
  await assert.rejects(session.awaitReady('2'), /timed out/);
  assert.equal(x.reads(), 1);
});
for (const field of [
  'receipt',
  'application',
  'sourceAttempt',
  'sourceWorker',
  'sourceWindow',
  'queueScope',
]) {
  test(`ready revalidation rejects appended ownership change: ${field}`, async () => {
    const x = fixture(),
      session = new RepeatedQualityPolling(x.options);
    const claim = await session.awaitReady('1');
    const value = x.checkpoint('1', 154),
      last = structuredClone(value.quality.events.at(-1));
    last.at++;
    if (field === 'receipt') last.receipt.configurationID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    if (field === 'application') last.application.id = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    if (field === 'sourceAttempt') last.source.attemptID = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
    if (field === 'sourceWorker') last.source.workerID = 'foreign';
    if (field === 'sourceWindow') last.source.end++;
    if (field === 'queueScope') last.evidence.queue.scope.recordingID = 'foreign';
    value.quality.events.push(last);
    value.eventCount++;
    x.set(value);
    await assert.rejects(session.validateReady(claim));
  });
}

test('dispatch waits for correlated publication and current decoder context', () => {
  assert.equal(typeof repeatedFaultStatusReady, 'function');
  const f = repeatedMeasuredPolicyFixture(),
    sample = f.faults.campaigns[0].beforePauseSample.value;
  const status = {
    ...sample.context,
    state: 'producing_output',
    observation: { attempt: sample.context.attempt, decoderCadence: sample.decoderCadence },
  };
  assert.equal(repeatedFaultStatusReady(status, f.scope.matchID), true);
  for (const mutate of [
    (s) => delete s.publication,
    (s) => delete s.observation,
    (s) => delete s.observation.decoderCadence,
    (s) => (s.gameId = 'foreign'),
    (s) => (s.generation = 0),
    (s) => (s.publication.publishingAttemptId = 'bad'),
    (s) => (s.observation.decoderCadence.ended = true),
    (s) => (s.observation.decoderCadence.invalidReason = 'invalid'),
    (s) => (s.workerId = ''),
    (s) => (s.workerEpoch = 'bad'),
    (s) => (s.observation.attempt = 0),
    (s) => (s.publication.readerId = 'bad'),
    (s) => (s.publication.publisherId = 'bad'),
  ]) {
    const changed = structuredClone(status);
    mutate(changed);
    assert.equal(repeatedFaultStatusReady(changed, f.scope.matchID), false);
  }
});

for (const field of ['workerID', 'workerEpoch', 'workerAttempt', 'readerID'])
  test(`first ready source must belong to fixture worker: ${field}`, async () => {
    const x = fixture(),
      value = x.checkpoint('1', 154);
    value.quality.events.at(-1).source[field] = field === 'workerAttempt' ? 2 : 'foreign';
    x.set(value);
    await assert.rejects(new RepeatedQualityPolling(x.options).awaitReady('1'));
  });
test('native UUID casing preserves raw scope while joining lowercase worker identity', async () => {
  const x = fixture(),
    old = x.f.scope.publishingAttemptID,
    nativeAttempt = 'AB000000-0000-4000-8000-000000000001';
  x.f.quality = JSON.parse(JSON.stringify(x.f.quality).replaceAll(old, nativeAttempt));
  x.f.scope.publishingAttemptID = nativeAttempt;
  x.options.publishingAttemptID = nativeAttempt.toLowerCase();
  const value = x.checkpoint('1', 154);
  value.publishingAttemptID = nativeAttempt.toLowerCase();
  value.quality.events.at(-1).source.workerEpoch = value.quality.events
    .at(-1)
    .source.workerEpoch.toUpperCase();
  value.quality.events.at(-1).source.readerID = value.quality.events
    .at(-1)
    .source.readerID.toUpperCase();
  x.set(value);
  const session = new RepeatedQualityPolling(x.options),
    claim = await session.awaitReady('1');
  await session.validateReady(claim);
  assert.deepEqual(session.scope, x.f.scope);
});

test('pre-pause status cannot adopt another pipeline reader or attempt', () => {
  assert.equal(typeof repeatedFaultOwnerMatches, 'function');
  const f = repeatedMeasuredPolicyFixture(),
    sample = f.faults.campaigns[0].beforePauseSample.value;
  const status = {
    ...sample.context,
    state: 'producing_output',
    observation: { attempt: sample.context.attempt, decoderCadence: sample.decoderCadence },
  };
  assert.equal(repeatedFaultOwnerMatches(structuredClone(status), status), true);
  for (const mutate of [
    (s) => s.observation.attempt++,
    (s) => (s.observation.decoderCadence.scopeID = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
    (s) => (s.publication.readerId = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
    (s) => (s.publication.publisherId = 'ffffffff-ffff-4fff-8fff-ffffffffffff'),
    (s) => (s.publication.transportClock = { convention: 'foreign', originPTS: '0' }),
  ]) {
    const next = structuredClone(status);
    mutate(next);
    assert.equal(repeatedFaultOwnerMatches(next, status), false);
  }
});
test('original capture scope revision one is distinct from policy bootstrap revision zero', async () => {
  const x = fixture(),
    value = x.checkpoint('1', 154);
  for (const event of value.quality.events)
    if (event.evidence?.queue?.scope) event.evidence.queue.scope.appliedProfileRevision = '1';
  x.set(value);
  const session = new RepeatedQualityPolling(x.options);
  const claim = await session.awaitReady('1');
  await session.validateReady(claim);
  assert.equal(session.scope.appliedProfileRevision, '1');
  assert.equal(value.quality.events[0].revision, '0');
});

test('later queue scope cannot change the original capture revision', async () => {
  const x = fixture(),
    value = x.checkpoint('1', 154),
    last = value.quality.events.at(-1);
  last.evidence.queue.scope = { ...last.evidence.queue.scope, appliedProfileRevision: '2' };
  x.set(value);
  await assert.rejects(new RepeatedQualityPolling(x.options).awaitReady('1'), /scope changed/);
});
