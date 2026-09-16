import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { validateArchiveDiagnostics } from '../archive-diagnostics-validation.mjs';

const fixture = async () =>
  JSON.parse(
    await readFile(new URL('./fixtures/archive-diagnostics-swift.json', import.meta.url), 'utf8'),
  );
const validate = (snapshot) =>
  validateArchiveDiagnostics({ snapshot, recordingID: 'encoded-fixture' });

test('accepts actual Swift Codable closed snapshot with omitted optional fields', async () => {
  const snapshot = await fixture();
  assert.equal(Object.hasOwn(snapshot.observations, 'activeProducer'), false);
  assert.equal(validate(snapshot).recordingID, 'encoded-fixture');
});

test('rejects wrong recording identity, nonterminal state and missing component coverage', async () => {
  for (const mutate of [
    (s) => {
      s.recordingID = 'other';
    },
    (s) => {
      s.closed = false;
    },
    (s) => {
      delete s.terminal;
    },
    (s) => {
      s.terminal.state = 'recording';
    },
    (s) => {
      s.coverage.producer = false;
    },
    (s) => {
      s.coverage.session = false;
    },
    (s) => {
      s.coverage.persistence = false;
    },
    (s) => {
      delete s.profile;
    },
    (s) => {
      delete s.queueLimits;
    },
  ]) {
    const snapshot = await fixture();
    mutate(snapshot);
    assert.throws(() => validate(snapshot));
  }
});

test('validates bounded completed and active operation histories at final and failure freeze', async () => {
  const producer = {
    frameIndex: '0',
    deadline: 0,
    generationStart: 0,
    generationEnd: 0,
    callbackStart: 0,
    callbackEnd: 0,
  };
  const consumer = {
    sample: {
      kind: 'video',
      pts: { value: '7395', timescale: 60, epoch: '0', flags: 1 },
      bytes: '10',
    },
    started: 0,
    ended: 0,
    phase: 'completed',
    phaseStarted: 0,
    attemptCount: '1',
    falseCount: '0',
    appendElapsed: 0,
    appendMaximum: 0,
    retryWaitElapsed: 0,
    lastAppendResult: 'accepted',
  };
  const persistence = {
    token: '1',
    kind: 'media',
    bytes: '5',
    started: 0,
    ended: 0,
    elapsed: 0,
    result: 'success',
  };
  for (const failure of [false, true]) {
    for (const [key, item, bound] of [
      ['producers', producer, 32],
      ['consumers', consumer, 64],
      ['persistences', persistence, 32],
    ]) {
      const snapshot = await fixture();
      const observations = failure ? snapshot.firstFailure.observations : snapshot.observations;
      observations[key].completed = Array(bound).fill(item);
      assert.doesNotThrow(() => validate(snapshot));
      observations[key].completed.push(item);
      assert.throws(() => validate(snapshot));
    }
    const snapshot = await fixture();
    const observations = failure ? snapshot.firstFailure.observations : snapshot.observations;
    observations.activePersistences = Array(4).fill({
      token: '1',
      kind: 'media',
      bytes: '5',
      started: 0,
      elapsed: 0,
    });
    assert.doesNotThrow(() => validate(snapshot));
    observations.activePersistences.push(observations.activePersistences[0]);
    assert.throws(() => validate(snapshot));
    observations.activePersistences = [];
    observations.activeProducer = [producer];
    assert.throws(() => validate(snapshot));
    delete observations.activeProducer;
    observations.activeConsumer = [consumer];
    assert.throws(() => validate(snapshot));
  }
});

test('rejects malformed wide counters, PTS, nonfinite timing and arbitrary error codes', async () => {
  for (const mutate of [
    (s) => {
      s.observations.audioAccepted = 1;
    },
    (s) => {
      s.observations.videoRejected = '-1';
    },
    (s) => {
      s.terminal.writtenSamples = '1e30';
    },
    (s) => {
      s.queueLimits.maxBytes = '1.5';
    },
    (s) => {
      s.observedAt = Infinity;
    },
    (s) => {
      s.firstFailure.detectedAt = -1;
    },
    (s) => {
      s.observations.producers.oldestRetainedTime = 1e12 + 1;
    },
    (s) => {
      s.firstFailure.reason = 'private error text';
    },
    (s) => {
      s.terminal.failure = 'private error text';
    },
    (s) => {
      s.firstFailure.rejection = 'private error text';
    },
    (s) => {
      s.firstFailure.sample = {
        kind: 'video',
        bytes: '5',
        pts: { value: 5, timescale: 30, epoch: '0', flags: 1 },
      };
    },
  ]) {
    const snapshot = await fixture();
    mutate(snapshot);
    assert.throws(() => validate(snapshot));
  }
});

test('unknown timing remains valid shape and diagnostic invalidity is not a performance verdict', async () => {
  const snapshot = await fixture();
  delete snapshot.observedAt;
  snapshot.validity.timingValid = false;
  snapshot.coverage.persistenceComplete = false;
  snapshot.observations.omittedActivePersistences = '18446744073709551615';
  assert.equal(validate(snapshot).timingValid, false);
});

test('retains signed Int32 PTS scalars without imposing timestamp validity', async () => {
  const snapshot = await fixture();
  snapshot.firstFailure.sample = {
    kind: 'video',
    bytes: '5',
    pts: {
      value: '-9223372036854775808',
      timescale: -2147483648,
      epoch: '9223372036854775807',
      flags: 4294967295,
    },
  };
  assert.doesNotThrow(() => validate(snapshot));
  snapshot.firstFailure.sample.pts.timescale = -2147483649;
  assert.throws(() => validate(snapshot));
});

test('validates optional nominal deadline separately from actual scheduled wake', async () => {
  for (const failure of [false, true]) {
    const snapshot = await fixture();
    const observations = failure ? snapshot.firstFailure.observations : snapshot.observations;
    const producer = { frameIndex: '1', nominalDeadline: 1, deadline: 2, generationStart: 2.1 };
    observations.activeProducer = producer;
    assert.doesNotThrow(() => validate(snapshot));
    for (const invalid of [-1, NaN, Infinity, '1', 1e13]) {
      producer.nominalDeadline = invalid;
      assert.throws(() => validate(snapshot));
    }
  }
});
