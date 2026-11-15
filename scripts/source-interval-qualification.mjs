import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';
import { validatePublishingClockDescriptor } from './publishing-clock-evidence.mjs';
import { immutableWindow } from './worker-report-age-qualification.mjs';

function integer(value, label, minimum = -(1n << 63n), maximum = (1n << 63n) - 1n) {
  assert.ok(
    typeof value === 'string' && value.length <= 20 && /^-?(0|[1-9]\d*)$/.test(value),
    `${label}: exact integer required`,
  );
  const parsed = BigInt(value);
  assert.equal(String(parsed), value, `${label}: noncanonical integer`);
  assert.ok(parsed >= minimum && parsed <= maximum, `${label}: integer out of range`);
  return parsed;
}
function safe(value, label, min = 0, max = Number.MAX_SAFE_INTEGER) {
  assert.ok(Number.isSafeInteger(value) && value >= min && value <= max, `${label}: invalid count`);
  return value;
}
function identities(values, label) {
  assert.ok(
    Array.isArray(values) && values.length > 0 && values.length <= 65536,
    `${label}: missing bounded identities`,
  );
  values.forEach((id, index) => {
    safe(id, label, 0, 65535);
    if (index) assert.ok(id > values[index - 1], `${label}: duplicate/reordered identity`);
  });
  return new Set(values);
}
const modulus = 1n << 33n;
const modulo = (n) => ((n % modulus) + modulus) % modulus;

/** Offline oracle for the known 30-fps fixture only. Inputs are the separately
 * qualified native observations, actual mux clock and authenticated publication
 * inventory. This compares exported runtime measurements with independently
 * decoded frame IDs; it does not reconstruct missing runtime measurements or
 * claim that historical evidence is currently fresh enough for quality policy. */
export function qualifySourceIntervals({
  snapshot,
  videoObservation,
  publishingClockObservation,
  workerPublicationEvidence,
  decodedEvidence,
  archiveIDs,
  liveIDs,
}) {
  const rows = snapshot.sourceIntervals;
  assert.ok(
    Array.isArray(rows) && rows.length >= 2 && rows.length <= 128,
    'Need two bounded runtime source intervals',
  );
  const scope = videoObservation.scope;
  assert.deepEqual(snapshot.scope, scope, 'Native scope mismatch');
  assert.deepEqual(publishingClockObservation.scope, scope, 'Clock scope mismatch');
  const clock = validatePublishingClockDescriptor(publishingClockObservation);
  // Decoder evidence predates workerEpoch. A single authenticated worker scope
  // is required so the offline lookup cannot confuse a restarted worker's PTS.
  assert.ok(
    Array.isArray(workerPublicationEvidence) && workerPublicationEvidence.length === 1,
    'Fixture requires exactly one authenticated worker publication scope',
  );
  const association = workerPublicationEvidence[0];
  assert.equal(association.gameId, scope.matchID);
  assert.equal(association.generation, scope.broadcastGeneration);
  assert.equal(association.recordingId, scope.recordingID);
  assert.equal(
    association.publication.publishingAttemptId.toLowerCase(),
    scope.publishingAttemptID.toLowerCase(),
  );
  const relayOrigin = integer(
    association.publication.clock.originPTS,
    'relay origin',
    0n,
    modulus - 1n,
  );
  assert.equal(association.publication.clock.convention, 'mpegts-ingress-origin-90k-v1');
  const archive = identities(archiveIDs, 'archive'),
    live = identities(liveIDs, 'live');
  archiveIDs.forEach((id, i) => assert.equal(id, i, 'Archive must contain all source frames'));
  liveIDs.forEach((id) => assert.ok(archive.has(id), 'Live identity outside archive'));
  assert.ok(
    Array.isArray(decodedEvidence) && decodedEvidence.length <= 4096,
    'Bounded decoder evidence required',
  );
  const windows = new Map();
  for (const sample of decodedEvidence) {
    assert.equal(sample.gameId, association.gameId);
    assert.equal(sample.generation, association.generation);
    assert.equal(sample.workerId, association.workerId);
    assert.equal(sample.attempt, association.attempt);
    const sequence = safe(sample.completed?.sequence, 'decoder sequence', 1);
    const prior = windows.get(sequence);
    if (prior) {
      assert.deepEqual(
        immutableWindow(sample.completed),
        immutableWindow(prior.completed),
        'Contradictory decoder window',
      );
      assert.equal(sample.clock, prior.clock);
      assert.equal(sample.ended, prior.ended);
      assert.equal(sample.invalidReason, prior.invalidReason);
    }
    windows.set(sequence, sample);
  }
  function window(sequence) {
    assert.ok(
      association.completedWindows.includes(sequence),
      'Window lacks private publication association',
    );
    const sample = windows.get(sequence);
    assert.ok(sample, 'Missing independent decoder window');
    assert.equal(sample.clock, 'mpegts-pts-90k-v1');
    assert.equal(sample.ended, false);
    assert.equal(sample.invalidReason, null);
    const w = sample.completed;
    assert.equal(w.durationMs, 5000);
    assert.equal(w.valid, true);
    assert.equal(w.duplicateFrames, 0);
    assert.equal(w.reorderedFrames, 0);
    safe(w.freshFrames, 'decoder frames', 1, 8192);
    safe(w.firstPTS, 'first PTS', Number.MIN_SAFE_INTEGER);
    safe(w.lastPTS, 'last PTS', Number.MIN_SAFE_INTEGER);
    assert.ok(w.lastPTS >= w.firstPTS);
    return w;
  }
  function project(source) {
    // fixtureFrameID independently validates all CMTime fields before arithmetic.
    fixtureFrameID(source);
    const numerator =
      BigInt(source.value) * BigInt(clock.sourceOrigin.timescale) -
      BigInt(clock.sourceOrigin.value) * BigInt(source.timescale);
    assert.ok(numerator >= 0n, 'Source precedes actual native clock origin');
    return (
      (numerator * 90000n) / (BigInt(source.timescale) * BigInt(clock.sourceOrigin.timescale)) +
      9000n
    );
  }
  let lastSequence = 0,
    lastEnd = -1;
  const intervals = rows.map((row) => {
    assert.deepEqual(row.scope, scope, 'Interval scope mismatch');
    assert.equal(row.workerId, association.workerId);
    assert.equal(row.workerEpoch, association.workerEpoch);
    assert.equal(row.workerAttempt, association.attempt);
    assert.deepEqual(row.publication, association.publication);
    assert.equal(row.publishingGeneration, clock.publishingGeneration);
    const sequence = Number(integer(row.sequence, 'sequence', 1n, BigInt(Number.MAX_SAFE_INTEGER)));
    const previousSequence = Number(
      integer(row.previousSequence, 'previous sequence', 1n, BigInt(Number.MAX_SAFE_INTEGER)),
    );
    assert.equal(sequence, previousSequence + 1, 'Only consecutive worker windows may match');
    assert.ok(sequence > lastSequence, 'Duplicate/reordered runtime interval');
    const previous = window(previousSequence),
      current = window(sequence);
    const previousPTS = integer(row.previousDecodedPTS, 'previous decoded PTS');
    const firstPTS = integer(row.firstDecodedPTS, 'first decoded PTS');
    const lastPTS = integer(row.lastDecodedPTS, 'last decoded PTS');
    assert.equal(previousPTS, BigInt(previous.lastPTS));
    assert.equal(firstPTS, BigInt(current.firstPTS));
    assert.equal(lastPTS, BigInt(current.lastPTS));
    assert.ok(previousPTS < firstPTS && firstPTS <= lastPTS);
    const start = fixtureFrameID(row.sourceStartExclusive),
      end = fixtureFrameID(row.sourceEndInclusive);
    assert.ok(end > start && start >= lastEnd, 'Invalid/overlapping source interval');
    const nativeStart = project(row.sourceStartExclusive),
      nativeEnd = project(row.sourceEndInclusive);
    assert.equal(
      modulo(nativeStart - relayOrigin),
      modulo(previousPTS),
      'Start differs from actual mux/relay clock',
    );
    assert.equal(
      modulo(nativeEnd - relayOrigin),
      modulo(lastPTS),
      'End differs from actual mux/relay clock',
    );
    assert.equal(nativeEnd - nativeStart, lastPTS - previousPTS, 'Unwrapped source span mismatch');
    const firstDelta = firstPTS - previousPTS;
    assert.equal(firstDelta % 3000n, 0n, 'First decoder PTS is not a fixture frame');
    const first = start + Number(firstDelta / 3000n);
    assert.ok(
      first > start && first <= end && live.has(first) && live.has(end) && live.has(start),
      'Missing decoded boundary identity',
    );
    for (const stage of ['captureVideo', 'encodedVideo']) {
      const range = videoObservation.sourceRanges[stage];
      assert.ok(
        range && start >= range.firstSourceFrame && end <= range.lastSourceFrame,
        'Missing native source provenance',
      );
      assert.equal(range.sourceFrames, range.lastSourceFrame - range.firstSourceFrame + 1);
    }
    for (const key of ['captureBoundaryStartTime', 'captureBoundaryEndTime']) {
      const value = row[key];
      assert.ok(
        typeof value === 'number' &&
          Number.isFinite(value) &&
          value >= snapshot.monotonicAnchor &&
          value <= snapshot.captureDetachedAt,
        'Callback time outside capture',
      );
    }
    assert.ok(row.captureBoundaryStartTime <= row.captureBoundaryEndTime);
    let captured = 0,
      decoded = 0;
    for (let id = start + 1; id <= end; id++) {
      if (archive.has(id)) captured++;
      if (live.has(id)) {
        assert.ok(id >= first, 'Unexpected live frame before decoder first');
        decoded++;
      }
    }
    const expected = {
      capturedFrames: captured,
      encodedFrames: end - start,
      decodedFrames: decoded,
      captureNotEncodedFrames: captured - (end - start),
      encodedNotDecodedFrames: end - start - decoded,
      leadingMissingEncodedFrames: first - start - 1,
    };
    for (const [key, value] of Object.entries(expected))
      assert.equal(safe(row[key], key, 0, 8192), value, `${key}: independent frame count mismatch`);
    assert.equal(decoded, current.freshFrames, 'Decoder count differs from live image identities');
    lastSequence = sequence;
    lastEnd = end;
    return {
      sequence,
      previousSequence,
      sourceStartExclusive: start,
      sourceEndInclusive: end,
      ...expected,
    };
  });
  return {
    scope,
    method:
      'Runtime source intervals checked against actual mux/relay clocks and decoded fixture identities',
    intervals,
  };
}
