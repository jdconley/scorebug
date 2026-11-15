import assert from 'node:assert/strict';

export function remoteWindowIdentity(sample) {
  return JSON.stringify([
    sample.gameId,
    sample.generation,
    sample.workerId,
    sample.attempt,
    sample.completed.sequence,
  ]);
}

// ageMs is a reading at an individual poll, never immutable window content.
export function immutableWindow(window) {
  const {
    sequence,
    durationMs,
    firstPTS,
    lastPTS,
    freshFrames,
    duplicateFrames,
    reorderedFrames,
    valid,
  } = window;
  return {
    sequence,
    durationMs,
    firstPTS,
    lastPTS,
    freshFrames,
    duplicateFrames,
    reorderedFrames,
    valid,
  };
}

const maxSafe = BigInt(Number.MAX_SAFE_INTEGER);
const attosecondsPerSecond = 10n ** 18n;
const attosecondsPerMillisecond = 10n ** 15n;
const maximumAge = maxSafe * attosecondsPerMillisecond;

function safe(value, label, minimum = 0) {
  assert.ok(Number.isSafeInteger(value) && value >= minimum, `${label} must be a safe integer`);
}

function exactDuration(value) {
  assert.ok(value && typeof value === 'object', 'Missing duration components');
  for (const field of ['seconds', 'attoseconds'])
    assert.ok(
      typeof value[field] === 'string' &&
        value[field].length <= (field === 'seconds' ? 19 : 18) &&
        /^(0|[1-9][0-9]*)$/.test(value[field]),
      `Noncanonical duration ${field}`,
    );
  const seconds = BigInt(value.seconds),
    attoseconds = BigInt(value.attoseconds);
  assert.ok(
    seconds <= 9223372036854775807n && attoseconds < attosecondsPerSecond,
    'Out-of-range duration components',
  );
  const result = seconds * attosecondsPerSecond + attoseconds;
  assert.ok(result <= maximumAge, 'Overflowing duration age');
  return result;
}

function validateSample(sample, requireBound) {
  assert.ok(typeof sample.gameId === 'string' && sample.gameId.length > 0, 'Invalid game scope');
  assert.ok(
    typeof sample.workerId === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(sample.workerId),
    'Invalid worker scope',
  );
  safe(sample.generation, 'generation', 1);
  safe(sample.attempt, 'attempt', 1);
  assert.ok(sample.ended === false && sample.invalidReason === null, 'Invalid decoder validity');
  const w = sample.completed;
  assert.ok(w && w.valid === true, 'Invalid completed window validity');
  safe(w.sequence, 'window sequence', 1);
  assert.equal(w.durationMs, 5000, 'Invalid completed window duration');
  let count = 0n;
  for (const field of ['freshFrames', 'duplicateFrames', 'reorderedFrames']) {
    safe(w[field], field);
    count += BigInt(w[field]);
  }
  assert.ok(count <= maxSafe, 'Window total exceeds safe integer');
  for (const field of ['firstPTS', 'lastPTS'])
    if (w[field] !== null) safe(w[field], field, -Number.MAX_SAFE_INTEGER);
  if (w.freshFrames === 0) assert.ok(w.firstPTS === null && w.lastPTS === null, 'Empty window PTS');
  else {
    assert.ok(w.firstPTS !== null && w.lastPTS !== null, 'Missing window PTS');
    assert.ok(
      w.freshFrames === 1 ? w.firstPTS === w.lastPTS : w.firstPTS < w.lastPTS,
      'Invalid window PTS progress',
    );
  }
  assert.ok(
    Number.isFinite(w.ageMs) && w.ageMs >= 0 && w.ageMs <= Number.MAX_SAFE_INTEGER,
    'Invalid window age lower bound',
  );
  if (requireBound || sample.decodedVideoAgeUpperBoundMs != null) {
    safe(sample.decodedVideoAgeUpperBoundMs, 'server upper bound');
    assert.ok(sample.decodedVideoAgeUpperBoundMs >= w.ageMs, 'Server upper below age lower bound');
  }
}

export function qualifyWorkerReportAge({ snapshot, decodedEvidence, decodedWindowLimit = 64 }) {
  // Trusted runner configuration only; no artifact field can expand this bound.
  assert.ok([64, 128].includes(decodedWindowLimit), 'Unsupported decoded window limit');
  const proofs = snapshot?.workerReportAgeProofs;
  assert.ok(
    Array.isArray(proofs) && proofs.length === 2,
    'Requires two native worker report age proofs',
  );
  const scope = snapshot.scope;
  assert.ok(
    typeof scope?.recordingID === 'string' && scope.recordingID.length > 0,
    'Invalid local recording scope',
  );
  assert.ok(
    typeof scope?.publishingAttemptID === 'string' &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        scope.publishingAttemptID,
      ),
    'Invalid local publishing scope UUID',
  );
  for (const proof of proofs) {
    assert.equal(proof.recordingID, scope.recordingID, 'Recording scope mismatch');
    assert.equal(
      proof.publishingAttemptID,
      scope.publishingAttemptID,
      'Local publishing attempt scope mismatch',
    );
    assert.equal(proof.gameId, scope.matchID, 'Remote game scope mismatch');
    assert.equal(proof.generation, scope.broadcastGeneration, 'Remote generation scope mismatch');
    assert.equal(proof.workerId, proofs[0].workerId, 'Remote worker scope mismatch');
    assert.equal(proof.attempt, proofs[0].attempt, 'Remote attempt scope mismatch');
    assert.equal(proof.evaluatedAt, 'pollControl', 'Proof must describe execution at pollControl');
    validateSample(proof, true);
    const request = exactDuration(proof.requestDuration),
      residence = exactDuration(proof.residenceDuration);
    const actual = exactDuration(proof.helperAgeUpperBound);
    const sum =
      BigInt(proof.decodedVideoAgeUpperBoundMs) * attosecondsPerMillisecond + request + residence;
    assert.ok(sum <= maximumAge, 'Overflowing duration age sum');
    assert.equal(actual, sum, 'Helper duration must equal exact server + request + residence');
  }
  assert.ok(
    proofs[0].completed.sequence < proofs[1].completed.sequence,
    'Proof history must be ordered distinct windows',
  );
  assert.ok(
    Array.isArray(decodedEvidence) && decodedEvidence.length <= decodedWindowLimit,
    'Invalid bounded collector evidence',
  );
  const samples = new Map();
  for (const sample of decodedEvidence) {
    validateSample(sample, false);
    const key = remoteWindowIdentity(sample),
      prior = samples.get(key);
    if (prior)
      assert.deepEqual(
        immutableWindow(sample.completed),
        immutableWindow(prior.completed),
        'Reused API identity changed immutable window content',
      );
    if (
      !prior ||
      (prior.decodedVideoAgeUpperBoundMs == null && sample.decodedVideoAgeUpperBoundMs != null)
    )
      samples.set(key, sample);
  }
  const unmatchedProofs = [],
    matchedWindows = [];
  for (const [index, proof] of proofs.entries()) {
    const sample = samples.get(remoteWindowIdentity(proof));
    if (sample)
      assert.deepEqual(
        immutableWindow(proof.completed),
        immutableWindow(sample.completed),
        'Native/API immutable window mismatch',
      );
    if (sample?.decodedVideoAgeUpperBoundMs != null)
      matchedWindows.push({
        gameId: proof.gameId,
        generation: proof.generation,
        workerId: proof.workerId,
        attempt: proof.attempt,
        sequence: proof.completed.sequence,
        nativeServerUpperBoundMs: proof.decodedVideoAgeUpperBoundMs,
        independentServerUpperBoundMs: sample.decodedVideoAgeUpperBoundMs,
      });
    else
      unmatchedProofs.push({
        sequence: proof.completed.sequence,
        position: index === 1 ? 'latest' : 'oldest',
        reason:
          'No independent bounded collector sample; the 500ms collector may miss the latest stop boundary',
      });
  }
  assert.ok(
    matchedWindows.length >= 1,
    'Requires at least one independent bounded API window match',
  );
  return {
    evidenceMeaning: 'historical helper execution at pollControl',
    proofCount: proofs.length,
    matchedWindowCount: matchedWindows.length,
    matchedWindows,
    unmatchedProofs,
  };
}
