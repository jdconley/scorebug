import assert from 'node:assert/strict';
import { replayNativePressure } from './native-quality-pressure.mjs';
const uuid = (value) =>
  typeof value === 'string' &&
  /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value) &&
  value.length === 36;
const finite = (value) => Number.isFinite(value) && value >= 0;
/** Native receipt and matched-source gate. It does not prove achieved payload rate. */
export function qualifyNativeQuality({
  quality,
  snapshot,
  sourceIntervalQualification,
  requireConfirmation = false,
}) {
  assert.equal(quality.formatVersion, 1);
  assert.equal(quality.overflow, false);
  assert(Array.isArray(quality.events) && quality.events.length <= 512);
  const events = quality.events,
    boot = events[0];
  assert.equal(boot?.kind, 'bootstrap');
  assert.equal(boot.revision, '0');
  assert.equal(boot.receipt.bitRate, 6000000);
  assert(finite(boot.acknowledgedAt));
  const configurationIDs = new Set();
  function receipt(value) {
    assert(uuid(value.configurationID) && uuid(value.encoderSessionID));
    assert(/^[1-9][0-9]*$/.test(value.generation));
    assert(
      Number.isSafeInteger(value.bitRate) && value.bitRate >= 1000000 && value.bitRate <= 12000000,
    );
    assert(finite(value.acceptedAt));
  }
  receipt(boot.receipt);
  configurationIDs.add(boot.receipt.configurationID);
  assert(boot.receipt.acceptedAt <= boot.acknowledgedAt && boot.acknowledgedAt <= boot.at);
  let current = boot.receipt,
    revision = 0,
    ack = boot.acknowledgedAt,
    lastTime = boot.at,
    lastPolicy = 0;
  let recoveryStart, lastEnd, lastScope, trial, probationStart, probationEnd, adviceEnd;
  let cooldownUntil = 0,
    lastEvaluatedAt = 0;
  let evaluated = 0,
    trials = 0,
    rollbacks = 0,
    confirmed = 0;
  for (const row of events.slice(1)) {
    assert(finite(row.at) && row.at >= lastTime);
    lastTime = row.at;
    assert.notEqual(row.kind, 'failed', 'Quality loop retired publishing');
    if (row.kind === 'evaluated') {
      assert.equal(row.revision, String(revision));
      assert.deepEqual(row.receipt, current);
      const s = row.source,
        w = row.window;
      assert.equal(s.attemptID.toLowerCase(), snapshot.scope.publishingAttemptID.toLowerCase());
      const source = snapshot.sourceIntervals.find(
        (x) =>
          x.sequence === s.sequence &&
          x.workerEpoch === s.workerEpoch &&
          x.workerAttempt === s.workerAttempt,
      );
      const proof = sourceIntervalQualification.intervals.find(
        (x) => x.sequence === Number(s.sequence),
      );
      assert(source && proof, 'Missing independently qualified source interval');
      assert.equal(source.publishingGeneration, current.generation);
      assert.deepEqual(source.encodingConfiguration, {
        id: current.configurationID,
        encoderSessionID: current.encoderSessionID,
        bitRate: current.bitRate,
      });
      assert.equal(w.start, source.captureBoundaryStartTime);
      assert.equal(w.end, source.captureBoundaryEndTime);
      assert.equal(s.start, w.start);
      assert.equal(s.end, w.end);
      assert.equal(w.captured, proof.capturedFrames);
      assert.equal(w.encoded, proof.encodedFrames);
      assert.equal(w.received, proof.decodedFrames);
      assert.equal(w.expected, w.captured);
      assert.equal(w.lost, w.captured - w.received);
      assert.equal(w.revision, String(revision));
      assert(Number(w.sequence) > lastPolicy);
      lastPolicy = Number(w.sequence);
      assert(w.start >= ack && w.end <= row.evaluatedAt && row.evaluatedAt - w.end <= 2);
      const duration = w.end - w.start;
      assert(duration >= 1 && duration <= 5.25);
      assert(
        finite(w.observedAt) &&
          w.observedAt >= w.end &&
          w.observedAt <= row.evaluatedAt &&
          row.evaluatedAt - w.observedAt <= 2,
      );
      assert.equal(w.capacity, null);
      assert(finite(row.evaluatedAt) && row.evaluatedAt <= row.at && row.evaluatedAt >= w.end);
      replayNativePressure(row, snapshot, source);
      assert.equal(s.workerID, source.workerId);
      assert.equal(s.readerID, source.publication.readerId);
      assert.equal(s.processingScopeID, row.evidence.processing?.scopeID ?? null);
      const scope = `${s.workerID}/${s.workerEpoch}/${s.workerAttempt}/${s.readerID}/${s.processingScopeID}`;
      const strong =
        [w.captured, w.encoded, w.received].every((n) => n / duration >= 29.7) &&
        w.lost / w.expected <= 0.01 &&
        finite(w.queue) &&
        w.queue < 0.5 &&
        ['thermal', 'worker', 'transport'].every((k) => w[k] === 'nominal');
      if (!strong || (lastEnd !== undefined && (w.start !== lastEnd || scope !== lastScope)))
        recoveryStart = undefined;
      if (strong) recoveryStart ??= w.start;
      adviceEnd = w.end;
      lastEvaluatedAt = row.evaluatedAt;
      if (trial) {
        if (
          row.evaluatedAt >= trial.deadline ||
          (probationStart === undefined && w.start > trial.appliedAt + 5.25)
        )
          trial.rollbackRequired = true;
        if (
          !strong ||
          scope !== trial.scope ||
          (probationEnd !== undefined && probationEnd !== w.start)
        )
          trial.rollbackRequired = true;
        if (strong && (probationEnd === undefined || probationEnd === w.start)) {
          probationStart ??= w.start;
          probationEnd = w.end;
        } else {
          probationStart = undefined;
          probationEnd = undefined;
        }
      }
      if (row.reasons.includes('trialConfirmed')) {
        assert(
          trial &&
            !trial.rollbackRequired &&
            probationStart !== undefined &&
            w.end - probationStart >= 10 &&
            row.evaluatedAt < trial.deadline,
        );
        trial = undefined;
        confirmed++;
        recoveryStart = undefined;
      }
      lastEnd = w.end;
      lastScope = scope;
      evaluated++;
    } else if (row.kind === 'applied') {
      const action = row.action;
      receipt(row.receipt);
      assert.equal(action.fromRevision, String(revision));
      assert.equal(row.revision, String(revision + 1));
      assert.equal(row.receipt.generation, current.generation);
      assert(!configurationIDs.has(row.receipt.configurationID));
      configurationIDs.add(row.receipt.configurationID);
      assert.equal(row.receipt.bitRate, action.bitRate);
      assert(
        finite(row.acknowledgedAt) &&
          row.receipt.acceptedAt <= row.acknowledgedAt &&
          row.acknowledgedAt <= row.at,
      );
      assert(row.acknowledgedAt <= action.validUntil && row.at <= action.validUntil);
      if (action.kind === 'trial') {
        assert.equal(action.validUntil, adviceEnd + 2);
        assert(lastEvaluatedAt >= cooldownUntil, 'Trial is inside rollback cooldown');
        assert(
          !trial && recoveryStart !== undefined && lastEnd - recoveryStart >= 30,
          'Trial lacks30 seconds of strong source evidence',
        );
        assert(
          action.bitRate > current.bitRate &&
            action.bitRate <= current.bitRate + Math.floor(current.bitRate / 10),
        );
        trial = {
          baseline: current.bitRate,
          deadline: row.acknowledgedAt + 22.5,
          appliedAt: row.acknowledgedAt,
          scope: lastScope,
          rollbackRequired: false,
        };
        probationStart = undefined;
        probationEnd = undefined;
        trials++;
      } else if (action.kind === 'rollback') {
        assert(trial);
        assert.equal(action.bitRate, trial.baseline);
        trial = undefined;
        cooldownUntil = row.acknowledgedAt + 60;
        rollbacks++;
      } else {
        assert.equal(action.kind, 'decrease');
        assert(action.bitRate < current.bitRate);
      }
      current = row.receipt;
      revision++;
      ack = row.acknowledgedAt;
      recoveryStart = undefined;
      lastEnd = undefined;
    } else if (row.kind === 'rejected') {
      recoveryStart = undefined;
      if (trial) trial.rollbackRequired = true;
    } else assert(['transition', 'skipped', 'stopped'].includes(row.kind));
  }
  const stopped = events.at(-1);
  assert.equal(stopped.kind, 'stopped');
  assert.equal(stopped.closed, true);
  assert.equal(stopped.revision, String(revision));
  assert.deepEqual(stopped.receipt, current);
  assert(evaluated >= 6 && trials >= 1, 'Need matched policy evidence and an actual native trial');
  if (requireConfirmation) assert(confirmed >= 1, 'Need an actual confirmed native trial');
  return {
    evaluated,
    trials,
    rollbacks,
    confirmed,
    finalBitRate: current.bitRate,
    scope:
      'Native control and verified receipts with saved source correspondence; not achieved payload rate or production capacity qualification.',
  };
}
