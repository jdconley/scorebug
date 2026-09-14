import assert from 'node:assert/strict';

const failureCodes = [
  'invalidState',
  'invalidTimestamp',
  'invalidRetryPolicy',
  'overflow',
  'backpressureTimedOut',
  'sinkFailed',
  'cancelled',
  'captureFailed',
];
const object = (value) =>
  assert.ok(
    value && typeof value === 'object' && !Array.isArray(value),
    'Expected diagnostic object',
  );
const boolean = (value) => assert.equal(typeof value, 'boolean');
const code = (value, allowed) => assert.ok(allowed.includes(value), 'Unknown diagnostic code');
const optional = (value, validate) => {
  if (value !== undefined) validate(value);
};
const counter = (value) => {
  assert.ok(
    typeof value === 'string' && /^(0|[1-9]\d{0,19})$/.test(value),
    'Expected decimal counter string',
  );
  assert.ok(BigInt(value) <= 18446744073709551615n, 'Counter exceeds UInt64');
};
const signedCounter = (value) => {
  assert.ok(
    typeof value === 'string' && /^(0|-?[1-9]\d{0,18})$/.test(value),
    'Expected decimal Int64 string',
  );
  assert.ok(BigInt(value) >= -9223372036854775808n && BigInt(value) <= 9223372036854775807n);
};
const time = (value) =>
  assert.ok(
    typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12,
    'Invalid diagnostic time',
  );
const times = (value, keys) => keys.forEach((key) => optional(value[key], time));
const integer = (value, max) =>
  assert.ok(Number.isSafeInteger(value) && value >= 0 && value <= max);
const counters = (value, keys) => keys.forEach((key) => counter(value[key]));

function coverage(value) {
  object(value);
  for (const key of ['producer', 'session', 'persistence', 'persistenceComplete'])
    boolean(value[key]);
}
function validity(value) {
  object(value);
  for (const key of ['timingValid', 'counterOverflow', 'invalidToken', 'invalidSequence'])
    boolean(value[key]);
}
function queue(value) {
  object(value);
  counters(value, [
    'currentItems',
    'currentBytes',
    'peakItems',
    'peakBytes',
    'acceptedCount',
    'rejectedCount',
    'droppedCount',
  ]);
  boolean(value.hasPendingConsumer);
}
function sample(value) {
  object(value);
  code(value.kind, ['audio', 'video']);
  counter(value.bytes);
  object(value.pts);
  signedCounter(value.pts.value);
  signedCounter(value.pts.epoch);
  assert.ok(
    Number.isSafeInteger(value.pts.timescale) &&
      value.pts.timescale >= -2147483648 &&
      value.pts.timescale <= 2147483647,
  );
  integer(value.pts.flags, 4294967295);
}
function producer(value) {
  object(value);
  counter(value.frameIndex);
  times(value, ['deadline', 'generationStart', 'generationEnd', 'callbackStart', 'callbackEnd']);
}
function consumer(value) {
  object(value);
  sample(value.sample);
  code(value.phase, ['dequeued', 'append', 'retryWait', 'returned', 'completed']);
  counters(value, ['attemptCount', 'falseCount']);
  times(value, [
    'started',
    'ended',
    'phaseStarted',
    'appendElapsed',
    'appendMaximum',
    'retryWaitElapsed',
    'readinessSince',
    'readinessElapsed',
  ]);
  optional(value.lastAppendResult, (result) => code(result, ['accepted', 'notReady', 'failure']));
}
function persistence(value) {
  object(value);
  counters(value, ['token', 'bytes']);
  code(value.kind, ['initialization', 'media']);
  times(value, ['started', 'ended', 'elapsed']);
  optional(value.result, (result) => code(result, ['success', 'failure']));
}
function bounded(values, limit, validate) {
  assert.ok(Array.isArray(values) && values.length <= limit, 'Diagnostic history exceeds bound');
  values.forEach(validate);
}
function observations(value) {
  object(value);
  for (const [key, limit, validate] of [
    ['producers', 32, producer],
    ['consumers', 64, consumer],
    ['persistences', 32, persistence],
  ]) {
    const history = value[key];
    object(history);
    counter(history.omittedCount);
    optional(history.oldestRetainedTime, time);
    bounded(history.completed, limit, validate);
  }
  optional(value.activeProducer, producer);
  optional(value.activeConsumer, consumer);
  bounded(value.activePersistences, 4, persistence);
  counters(value, [
    'omittedActivePersistences',
    'audioAccepted',
    'audioRejected',
    'videoAccepted',
    'videoRejected',
  ]);
}

/** Shape and ownership only. Partial/invalid timing and failure evidence carry no performance verdict. */
export function validateArchiveDiagnostics({ snapshot, recordingID }) {
  object(snapshot);
  assert.equal(snapshot.formatVersion, 1);
  assert.ok(typeof recordingID === 'string' && recordingID.length > 0);
  assert.equal(snapshot.recordingID, recordingID, 'Archive diagnostic recording identity mismatch');
  assert.equal(snapshot.closed, true, 'Archive diagnostics must be closed');
  coverage(snapshot.coverage);
  validity(snapshot.validity);
  for (const key of ['producer', 'session', 'persistence'])
    assert.equal(snapshot.coverage[key], true, `Missing ${key} coverage`);
  object(snapshot.queueLimits);
  counters(snapshot.queueLimits, ['maxItems', 'maxBytes']);
  object(snapshot.profile);
  for (const key of [
    'width',
    'height',
    'framesPerSecond',
    'videoBitRate',
    'audioChannels',
    'audioBitRate',
  ])
    integer(snapshot.profile[key], Number.MAX_SAFE_INTEGER);
  time(snapshot.profile.audioSampleRate);
  time(snapshot.profile.segmentDuration);
  optional(snapshot.observedAt, time);
  observations(snapshot.observations);
  optional(snapshot.firstFailure, (failure) => {
    object(failure);
    code(failure.reason, failureCodes);
    optional(failure.detectedAt, time);
    optional(failure.rejection, (reason) =>
      code(reason, ['invalidBytes', 'oversize', 'full', 'finished', 'cancelled']),
    );
    optional(failure.sample, sample);
    optional(failure.queue, queue);
    counter(failure.writtenSamples);
    coverage(failure.coverage);
    validity(failure.validity);
    observations(failure.observations);
  });
  object(snapshot.terminal);
  code(snapshot.terminal.state, ['finished', 'failed']);
  optional(snapshot.terminal.failure, (failure) => code(failure, failureCodes));
  counter(snapshot.terminal.writtenSamples);
  queue(snapshot.terminal.queue);
  return {
    recordingID,
    terminalState: snapshot.terminal.state,
    firstFailure: snapshot.firstFailure?.reason ?? null,
    timingValid: snapshot.validity.timingValid,
    coverage: snapshot.coverage,
    completed: Object.fromEntries(
      ['producers', 'consumers', 'persistences'].map((key) => [
        key,
        snapshot.observations[key].completed.length,
      ]),
    ),
  };
}
