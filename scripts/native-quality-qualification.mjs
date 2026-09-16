import assert from 'node:assert/strict';
import { replayNativePressure, replayNativeLocalPressure } from './native-quality-pressure.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
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
  adaptiveProfiles = false,
  profileQualification,
}) {
  assert([1, 2].includes(quality.formatVersion));
  assert.equal(quality.overflow, false);
  assert(Array.isArray(quality.events) && quality.events.length <= 512);
  const events = quality.events,
    boot = events[0];
  assert.equal(boot?.kind, 'bootstrap');
  assert.equal(boot.revision, '0');
  assert.equal(boot.receipt.bitRate, 6000000);
  assert(finite(boot.acknowledgedAt));
  let profile = '1080p30',
    profileChanges = 0,
    decreases = 0;
  if (adaptiveProfiles) {
    assert.equal(boot.profileID, profile);
    assert(profileQualification, 'Adaptive policy requires independently qualified native formats');
    assert.deepEqual(profileQualification.scope, snapshot.scope);
    assert(Array.isArray(profileQualification.receipts));
    assert.equal(profileQualification.phases?.length, profileQualification.receipts.length + 1);
  }
  const configurationIDs = new Set(),
    applicationIDs = new Set();
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
  let recoveryStart,
    lastEnd,
    lastScope,
    trial,
    probationStart,
    probationEnd,
    adviceEnd,
    lastWindowEnd;
  let decreaseAllowed = false,
    localEvaluated = 0;
  let cooldownUntil = 0,
    lastEvaluatedAt = 0;
  let evaluated = 0,
    trials = 0,
    rollbacks = 0,
    confirmed = 0;
  for (const row of events.slice(1)) {
    assert(finite(row.at) && row.at >= lastTime);
    const previousEventAt = lastTime;
    lastTime = row.at;
    assert.notEqual(row.kind, 'failed', 'Quality loop retired publishing');
    if (adaptiveProfiles && row.kind !== 'applied') assert.equal(row.profileID, profile);
    if (row.kind === 'evaluated' || row.kind === 'localPressure') {
      assert.equal(row.revision, String(revision));
      assert.deepEqual(row.receipt, current);
      const s = row.source,
        w = row.window,
        local = row.kind === 'localPressure';
      let source;
      if (!local) {
        assert.equal(s.attemptID.toLowerCase(), snapshot.scope.publishingAttemptID.toLowerCase());
        source = snapshot.sourceIntervals.find(
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
        if (w.connectivity !== undefined) assert.equal(w.connectivity, 'connected');
      }
      assert.equal(w.revision, String(revision));
      assert(typeof w.sequence === 'string' && /^[1-9][0-9]*$/.test(w.sequence));
      assert(Number.isSafeInteger(Number(w.sequence)) && Number(w.sequence) > lastPolicy);
      lastPolicy = Number(w.sequence);
      assert(w.start >= ack && w.end <= row.evaluatedAt && row.evaluatedAt - w.end <= 2);
      assert(lastWindowEnd === undefined || w.start >= lastWindowEnd, 'Policy windows overlap');
      const duration = w.end - w.start;
      assert(duration >= 1 && duration <= 5.25);
      if (!local)
        assert(
          finite(w.observedAt) &&
            w.observedAt >= w.end &&
            w.observedAt <= row.evaluatedAt &&
            row.evaluatedAt - w.observedAt <= 2,
        );
      assert.equal(w.capacity, null);
      assert(
        finite(row.evaluatedAt) &&
          row.evaluatedAt <= row.at &&
          row.evaluatedAt >= w.end &&
          row.evaluatedAt >= lastEvaluatedAt,
      );
      if (local) {
        assert.equal(row.acknowledgedAt, ack);
        replayNativeLocalPressure(row, snapshot, { after: lastWindowEnd });
      } else {
        replayNativePressure(row, snapshot, source);
        assert.equal(s.workerID, source.workerId);
        assert.equal(s.readerID, source.publication.readerId);
        assert.equal(s.processingScopeID, row.evidence.processing?.scopeID ?? null);
      }
      const scope = local
        ? undefined
        : `${s.workerID}/${s.workerEpoch}/${s.workerAttempt}/${s.readerID}/${s.processingScopeID}`;
      const unhealthy =
        ['thermal', 'worker', 'transport'].some((k) => w[k] === 'elevated') ||
        (finite(w.queue) && w.queue >= 0.75) ||
        (!local &&
          ([w.captured, w.encoded, w.received].some((n) => n / duration < 24) ||
            w.lost / w.expected > 0.01));
      decreaseAllowed = !trial && unhealthy;
      const strong =
        !local &&
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
      lastWindowEnd = w.end;
      lastEnd = w.end;
      lastScope = scope;
      if (local) localEvaluated++;
      else evaluated++;
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
      let admittedAt;
      if (quality.formatVersion === 2) {
        const application = row.application;
        assert(application && uuid(application.id) && uuid(application.attemptID));
        const id = application.id.toLowerCase();
        assert(!applicationIDs.has(id), 'Application authorization was reused');
        applicationIDs.add(id);
        assert.equal(
          application.attemptID.toLowerCase(),
          snapshot.scope.publishingAttemptID.toLowerCase(),
        );
        assert.equal(application.fromRevision, action.fromRevision);
        assert.equal(application.windowSequence, String(lastPolicy));
        admittedAt = application.admittedAt;
        assert(
          finite(admittedAt) && admittedAt >= previousEventAt && admittedAt >= lastEvaluatedAt,
        );
        assert(
          finite(action.validUntil) && admittedAt <= action.validUntil,
          'Native work started on expired advice',
        );
        assert(
          action.validUntil - 2 <= admittedAt,
          'Advice issuance cannot follow native admission',
        );
        assert.equal(application.completionDeadline, admittedAt + 2);
        assert(row.receipt.acceptedAt >= admittedAt, 'Native receipt predates admission');
        assert(row.acknowledgedAt <= application.completionDeadline);
      } else {
        // Old artifacts never gain extra completion time from optional new fields.
        assert(row.acknowledgedAt <= action.validUntil && row.at <= action.validUntil);
      }
      if (adaptiveProfiles) {
        const format = profileQualification.receipts[profileChanges];
        assert(format, 'Profile action lacks independent native format');
        assert.deepEqual(row.profileReceipt, format);
        assert.equal(action.profileID, row.profileID);
        assert.equal(row.profileID, format.profile);
        assert.notEqual(row.profileID, profile);
        assert.equal(format.previousEncoderSessionID, current.encoderSessionID);
        assert.equal(format.encoderSessionID, row.receipt.encoderSessionID);
        assert.equal(format.publishingGeneration, row.receipt.generation);
        assert(
          (admittedAt === undefined || format.acknowledgedAt >= admittedAt) &&
            format.acknowledgedAt >= lastEvaluatedAt &&
            format.acknowledgedAt >= ack &&
            format.acknowledgedAt <= row.receipt.acceptedAt,
        );
        assert.equal(row.receipt.bitRate, row.profileID === '1080p30' ? 6000000 : 1500000);
        const a = row.receipt.lastSubmittedPTS,
          b = format.firstNewSourcePTS;
        for (const p of [a, b])
          assert(
            p &&
              typeof p.value === 'string' &&
              /^\d+$/.test(p.value) &&
              Number.isSafeInteger(p.timescale) &&
              p.timescale > 0 &&
              p.timescale <= 2147483647,
          );
        assert(BigInt(a.value) * BigInt(b.timescale) >= BigInt(b.value) * BigInt(a.timescale));
        const phase = profileQualification.phases[profileChanges + 1];
        assert.equal(phase.encoderSessionID, row.receipt.encoderSessionID);
        assert.equal(phase.firstFrame, fixtureFrameID(b));
        const frame = fixtureFrameID({ ...a, epoch: '0', flags: 1 });
        assert(
          frame >= phase.firstFrame && frame <= phase.lastFrame,
          'Bitrate receipt escapes observed native phase',
        );
        profileChanges++;
      }
      if (action.kind === 'trial') {
        assert.equal(action.validUntil, adviceEnd + 2);
        assert(lastEvaluatedAt >= cooldownUntil, 'Trial is inside rollback cooldown');
        assert(
          !trial && recoveryStart !== undefined && lastEnd - recoveryStart >= 30,
          'Trial lacks30 seconds of strong source evidence',
        );
        if (adaptiveProfiles) {
          assert.equal(profile, '540p30');
          assert.equal(action.profileID, '1080p30');
        } else
          assert(
            action.bitRate > current.bitRate &&
              action.bitRate <= current.bitRate + Math.floor(current.bitRate / 10),
          );
        trial = {
          baseline: current.bitRate,
          baselineProfile: profile,
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
        if (admittedAt !== undefined) {
          assert(
            trial.rollbackRequired || admittedAt >= trial.deadline,
            'Timeout-only rollback started before probation expired',
          );
        }
        if (adaptiveProfiles) {
          assert.equal(action.profileID, trial.baselineProfile);
          assert(
            trial.rollbackRequired || row.profileReceipt.acknowledgedAt >= trial.deadline,
            'Rollback lacks pressure, invalid evidence or expiry',
          );
        }
        trial = undefined;
        cooldownUntil = row.acknowledgedAt + 60;
        rollbacks++;
      } else {
        assert.equal(action.kind, 'decrease');
        assert(
          decreaseAllowed && !trial,
          'Decrease lacks current unhealthy evidence outside probation',
        );
        assert.equal(action.validUntil, adviceEnd + 2);
        assert(row.receipt.acceptedAt >= lastEvaluatedAt);
        if (adaptiveProfiles) {
          assert.equal(profile, '1080p30');
          assert.equal(action.profileID, '540p30');
          assert.equal(action.bitRate, 1500000);
          decreases++;
        } else assert.equal(action.bitRate, Math.max(1000000, Math.floor(current.bitRate * 0.8)));
        assert(action.bitRate < current.bitRate);
      }
      current = row.receipt;
      if (adaptiveProfiles) profile = row.profileID;
      revision++;
      ack = row.acknowledgedAt;
      recoveryStart = undefined;
      lastEnd = undefined;
      adviceEnd = undefined;
      decreaseAllowed = false;
    } else if (row.kind === 'rejected') {
      recoveryStart = undefined;
      adviceEnd = undefined;
      decreaseAllowed = false;
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
  if (adaptiveProfiles) {
    assert.equal(
      profileChanges,
      profileQualification.receipts.length,
      'Unmatched native profile change',
    );
    assert(
      decreases >= 1 && confirmed >= 1 && !trial,
      'Need pressure reduction and completed recovery',
    );
    assert.equal(profile, '1080p30');
  }
  return {
    evaluated,
    ...(localEvaluated > 0 ? { localEvaluated } : {}),
    trials,
    rollbacks,
    confirmed,
    finalBitRate: current.bitRate,
    ...(adaptiveProfiles ? { profileChanges, decreases, finalProfile: profile } : {}),
    scope:
      'Native control and verified receipts with saved source correspondence; not achieved payload rate or production capacity qualification.',
  };
}
