import { cadenceAuditRowLimit, qualifyCadenceAuditEnvelope } from './cadence-audit-envelope.mjs';
import assert from 'node:assert/strict';
import { replayNativePressure } from './native-quality-pressure.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
const finite = (n) => Number.isFinite(n) && n >= 0;
const uuid = (n) =>
  typeof n === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(n);
const id = (n) => {
  assert(uuid(n), 'Invalid owned identity');
  return n.toLowerCase();
};
const sequence = (n) => {
  assert(typeof n === 'string' && /^[1-9][0-9]*$/.test(n) && Number.isSafeInteger(Number(n)));
  return Number(n);
};
const owner = (s) => [s.workerID, s.workerEpoch, s.workerAttempt, s.readerID, s.processingScopeID];
function receipt(r) {
  id(r.configurationID);
  id(r.encoderSessionID);
  sequence(r.generation);
  assert(finite(r.acceptedAt));
  fixtureFrameID(r.lastSubmittedPTS);
}
/** Every fresh helper can invalidate native probation between source windows.
 * This successful-path gate rejects unavailable/stale/changed/stalled history;
 * it grants no health duration from cadence reports. The 500-ms gap ceiling is
 * the existing native cadence audit completeness budget, not probation credit.
 */
function requireUninterruptedCadence(reports, sourceEvents, scope) {
  const first = sourceEvents[0],
    last = sourceEvents.at(-1);
  assert(first && last, 'Missing source decisions');
  return qualifyMeasuredCadenceContinuity({
    reports,
    start: first.window.start,
    end: last.evaluatedAt,
    source: first.source,
    scope,
  });
}
/** Validate an explicit native-time interval, without awarding health duration.
 * Recovery may retain only repeats of its independently proved consumed stall
 * before the first credited healthy window. Default trial replay permits none.
 */
export function qualifyMeasuredCadenceContinuity({
  reports,
  start,
  end,
  source,
  scope,
  allowedStall,
  cadenceAuditMode = 'legacy',
  recoveryInvalidations = [],
}) {
  assert(finite(start) && finite(end) && end >= start);
  assert(
    Array.isArray(reports) &&
      reports.length > 0 &&
      reports.length <= cadenceAuditRowLimit(cadenceAuditMode),
  );
  // These are exact receipt/index joins independently replayed from the full
  // repeated raw quality and audit histories, never a caller-selected age limit.
  assert(Array.isArray(recoveryInvalidations) && recoveryInvalidations.length <= 512);
  assert(
    cadenceAuditMode === 'repeated' || recoveryInvalidations.length === 0,
    'Recovery invalidation requires explicit repeated cadence mode',
  );
  const unavailable = new Map();
  for (const invalidation of recoveryInvalidations) {
    const index = invalidation.reportIndex;
    assert(Number.isSafeInteger(index) && index >= 0 && index < reports.length);
    assert(!unavailable.has(index), 'Duplicate unavailable cadence receipt');
    assert.equal(reports[index].cadenceReceiptID, id(invalidation.receiptID));
    unavailable.set(index, invalidation);
  }
  if (allowedStall)
    assert(
      finite(allowedStall.start) &&
        finite(allowedStall.end) &&
        allowedStall.start >= start &&
        allowedStall.end <= end &&
        allowedStall.end > allowedStall.start &&
        Number.isSafeInteger(allowedStall.lastFreshPTS) &&
        allowedStall.lastFreshPTS >= 0,
    );
  let previousTime = -1,
    cursor = start,
    decoderScope,
    publication,
    lastProgress,
    count = 0;
  for (const [reportIndex, report] of reports.entries()) {
    assert(
      finite(report.evaluatedUptime) && report.evaluatedUptime > previousTime,
      'Cadence audit time reversal',
    );
    previousTime = report.evaluatedUptime;
    if (report.evaluatedUptime < start || report.evaluatedUptime > end) continue;
    assert(report.evaluatedUptime - cursor <= 0.5, 'Missing intermediate cadence coverage');
    cursor = report.evaluatedUptime;
    count++;
    assert.equal(report.expectedAttempt, id(source.attemptID));
    const status = report.response?.status,
      observation = status?.observation;
    assert.equal(status?.state, 'producing_output', 'Unavailable intermediate cadence owner');
    assert.equal(status.gameId, scope.matchID);
    assert.equal(status.generation, scope.broadcastGeneration);
    assert.equal(observation?.gameId, scope.matchID);
    assert.equal(observation.generation, scope.broadcastGeneration);
    assert.equal(status.workerId, source.workerID);
    assert.equal(status.workerEpoch, source.workerEpoch);
    assert.equal(observation.attempt, source.workerAttempt);
    assert.equal(status.publication?.publishingAttemptId, id(source.attemptID));
    assert.equal(status.publication.readerId, source.readerID);
    publication ??= status.publication;
    assert.deepEqual(status.publication, publication, 'Intermediate publication ownership changed');
    assert.equal(observation.decodedVideo?.clock, 'mpegts-pts-90k-v1');
    const cadence = observation.decoderCadence,
      progress = cadence?.progress;
    assert.equal(cadence?.formatVersion, 1);
    assert.equal(cadence.ended, false);
    assert.equal(cadence.invalidReason, null);
    for (const [window, duration] of [
      [cadence.oneSecond, 1000],
      [cadence.twoSeconds, 2000],
    ]) {
      if (window == null) continue;
      assert.equal(window.valid, true, 'Invalid intermediate cadence window');
      assert(
        Number.isSafeInteger(window.sequence) &&
          window.sequence > 0 &&
          window.sequence <= Number.MAX_SAFE_INTEGER / duration,
      );
      assert.equal(window.durationMs, duration);
      assert(finite(window.ageMs) && window.ageMs <= Number.MAX_SAFE_INTEGER);
      let total = 0;
      for (const value of [window.freshFrames, window.duplicateFrames, window.reorderedFrames]) {
        assert(Number.isSafeInteger(value) && value >= 0);
        total += value;
        assert(Number.isSafeInteger(total));
      }
      if (window.freshFrames === 0) {
        assert.equal(window.firstPTS, null);
        assert.equal(window.lastPTS, null);
      } else {
        assert(Number.isSafeInteger(window.firstPTS) && Number.isSafeInteger(window.lastPTS));
        assert(
          window.freshFrames === 1
            ? window.firstPTS === window.lastPTS
            : window.firstPTS < window.lastPTS,
        );
        assert(window.lastPTS <= progress.lastFreshPTS);
      }
    }
    if (cadence.twoSeconds != null) {
      const one = cadence.oneSecond,
        two = cadence.twoSeconds;
      assert(one && (one.sequence === two.sequence * 2 || one.sequence === two.sequence * 2 + 1));
      assert(
        Math.abs(one.sequence * 1000 + one.ageMs - (two.sequence * 2000 + two.ageMs)) <= 0.001,
      );
    } else if (cadence.oneSecond != null) assert.equal(cadence.oneSecond.sequence, 1);

    id(cadence.scopeID);
    decoderScope ??= cadence.scopeID;
    assert.equal(cadence.scopeID, decoderScope, 'Intermediate decoder scope changed');
    assert(Number.isSafeInteger(progress?.lastFreshPTS) && progress.lastFreshPTS >= 0);
    assert(
      lastProgress === undefined || progress.lastFreshPTS >= lastProgress,
      'Intermediate decoder progress regressed',
    );
    lastProgress = progress.lastFreshPTS;
    const repeatedStall =
      allowedStall &&
      report.evaluatedUptime >= allowedStall.start &&
      report.evaluatedUptime < allowedStall.end &&
      progress.lastFreshPTS === allowedStall.lastFreshPTS;
    assert(
      finite(progress.ageMs) &&
        progress.ageMs <= Number.MAX_SAFE_INTEGER &&
        (progress.ageMs < 1000 || repeatedStall),
      'Intermediate decoder stall invalidates probation',
    );
    assert.equal(progress.stalled, progress.ageMs >= 1000);
    const invalidated = unavailable.has(reportIndex);
    assert(
      !invalidated || (!progress.stalled && !repeatedStall),
      'Unavailable cadence cannot excuse a stall',
    );
    assert.equal(
      report.observedStall,
      invalidated ? null : progress.stalled,
      'Unjoined unavailable cadence or inconsistent stall classification',
    );
    assert(
      Number.isSafeInteger(status.decoderCadenceAgeUpperBoundMs) &&
        status.decoderCadenceAgeUpperBoundMs >= 0,
    );
    assert(finite(report.requestSeconds) && finite(report.residenceSeconds));
    const age =
      status.decoderCadenceAgeUpperBoundMs / 1000 + report.requestSeconds + report.residenceSeconds;
    assert(
      finite(report.sampleAgeSeconds) &&
        (invalidated ? age > 0.25 : age <= 0.25) &&
        Math.abs(age - report.sampleAgeSeconds) < 1e-8,
      'Unavailable or stale intermediate cadence',
    );
  }
  assert(count > 0 && end - cursor <= 0.5, 'Missing intermediate cadence coverage');
}
/** Narrow successful minimum -> next-profile laboratory replay. The caller must
 * independently recompute the structured source, native format, lifecycle and
 * witness inputs from bounded raw artifacts. This module also replays raw pressure
 * and joins raw cadence identities; it does not independently decode media or
 * qualify delivery lanes, probe capacity, or production upgrade authorization.
 * Rejection/reset/local-pressure episodes are deliberately unsupported successes.
 */
function replayMeasuredTrialPolicy(
  {
    quality,
    snapshot,
    sourceIntervalQualification,
    profileQualification,
    lifecycleQualification,
    candidateWitnessQualification,
    cadenceReports,
    transportPolicy = 'sender-delay-v1',
  },
  confirmedPrefix = false,
) {
  assert.ok(
    ['sender-delay-v1', 'recovery-budget-v1'].includes(transportPolicy),
    'Unknown measured transport policy',
  );
  const recoveryPolicy = transportPolicy === 'recovery-budget-v1';
  assert.equal(quality.formatVersion, recoveryPolicy ? 5 : 4);
  if (recoveryPolicy) {
    // Prefix mode replays the same pressure policy and all admission/probation
    // gates through confirmation. It grants no qualification to a later reset.
    assert.equal(quality.transportPolicy, transportPolicy);
    assert.equal(candidateWitnessQualification?.policy, transportPolicy);
    assert.equal(lifecycleQualification?.probePolicy, transportPolicy);
  } else {
    assert.ok(
      !Object.hasOwn(quality, 'transportPolicy'),
      'Historical quality has new pressure policy',
    );
    assert.ok(
      !Object.hasOwn(candidateWitnessQualification ?? {}, 'policy') &&
        !Object.hasOwn(lifecycleQualification ?? {}, 'probePolicy'),
      'Historical quality has recovery-policy joins',
    );
  }
  assert.equal(quality.overflow, false);
  assert.equal(quality.measuredSourceEvaluationEnabled, true);
  assert(
    Array.isArray(quality.events) && quality.events.length >= 7 && quality.events.length <= 512,
  );
  const events = quality.events,
    boot = events[0],
    stop = events.at(-1);
  assert.equal(boot.kind, 'bootstrap');
  assert.equal(boot.revision, '0');
  assert.equal(boot.profileID, '240p30');
  assert.equal(boot.receipt.bitRate, 350000);
  receipt(boot.receipt);
  assert(
    finite(boot.acknowledgedAt) &&
      boot.receipt.acceptedAt <= boot.acknowledgedAt &&
      boot.acknowledgedAt <= boot.at,
  );
  for (const proof of [sourceIntervalQualification, profileQualification, lifecycleQualification])
    assert.deepEqual(proof?.scope, snapshot.scope, 'Independent proof scope mismatch');
  assert(
    Array.isArray(sourceIntervalQualification.intervals) &&
      sourceIntervalQualification.intervals.length <= 512,
  );
  assert(Array.isArray(snapshot.sourceIntervals) && snapshot.sourceIntervals.length <= 512);
  if (confirmedPrefix) {
    assert(
      [2, 3].includes(profileQualification.phases?.length),
      'Prefix requires full qualified native history',
    );
    assert.equal(profileQualification.receipts?.length, profileQualification.phases.length - 1);
  } else {
    assert.equal(profileQualification.phases?.length, 2);
    assert.equal(profileQualification.receipts?.length, 1);
  }
  const [initial, changed] = profileQualification.phases;
  assert.equal(initial.width, 426);
  assert.equal(initial.height, 240);
  assert.equal(initial.encoderSessionID, boot.receipt.encoderSessionID);
  assert.equal(changed.width, 640);
  assert.equal(changed.height, 360);
  const bootFrame = fixtureFrameID(boot.receipt.lastSubmittedPTS);
  assert(bootFrame >= initial.firstFrame && bootFrame <= initial.lastFrame);
  assert.deepEqual(lifecycleQualification.bootstrap, boot);
  assert.equal(
    lifecycleQualification.applications?.length,
    confirmedPrefix ? profileQualification.receipts.length : 1,
  );
  const appliedRows = events.filter((e) => e.kind === 'applied'),
    candidates = events.filter((e) => e.kind === 'candidate');
  assert.equal(
    appliedRows.length,
    confirmedPrefix ? lifecycleQualification.applications.length : 1,
    'Native applications must match full history',
  );
  if (!confirmedPrefix)
    assert.equal(candidates.length, 1, 'Exactly one measured candidate required');
  assert(candidates.length > 0, 'Missing measured candidate');
  const applied = appliedRows[0],
    candidate = candidates[0],
    c = candidate.candidate,
    witness = candidate.candidateAdmission;
  assert.equal(candidate.state, 'healthy');
  assert.deepEqual(candidate.reasons, ['trialRecommended']);
  for (const k of [
    'action',
    'application',
    'receipt',
    'profileReceipt',
    'acknowledgedAt',
    'revision',
    'profileID',
  ])
    assert.deepEqual(candidate[k], applied[k]);
  assert(c && witness && candidateWitnessQualification, 'Missing measured admission details');
  for (const k of [
    'evaluatedAt',
    'validUntil',
    'candidateTransportBitsPerSecond',
    'deliveredPaddingBitsPerSecond',
  ])
    assert.equal(
      candidateWitnessQualification[k],
      witness[k],
      'Witness result does not match admission',
    );
  for (const k of [
    'evaluatedAt',
    'validUntil',
    'candidateTransportBitsPerSecond',
    'deliveredPaddingBitsPerSecond',
  ])
    assert.equal(c[k], witness[k]);
  assert(id(c.id) === id(witness.measurement.id));
  assert.equal(c.measuredStart, witness.measurement.startedAt);
  assert.equal(c.measuredEnd, witness.measurement.endedAt);
  assert.equal(c.baselineProfileID, '240p30');
  assert.equal(c.baselineVideoBitrate, 350000);
  assert.equal(c.profileID, '360p30');
  assert.equal(c.videoBitrate, 600000);
  assert.equal(c.appliedRevision, '0');
  assert.equal(id(c.attemptID), id(snapshot.scope.publishingAttemptID));
  assert(
    c.candidateTransportBitsPerSecond > 0 &&
      c.deliveredPaddingBitsPerSecond >= 1.25 * c.candidateTransportBitsPerSecond,
  );
  assert(
    [c.measuredStart, c.measuredEnd, c.evaluatedAt, c.validUntil, candidate.evaluatedAt].every(
      finite,
    ),
  );
  assert(
    c.measuredStart >= boot.acknowledgedAt &&
      c.measuredEnd > c.measuredStart &&
      c.measuredEnd - c.measuredStart <= 7,
  );
  assert(
    c.measuredEnd <= c.evaluatedAt &&
      c.evaluatedAt <= candidate.evaluatedAt &&
      candidate.evaluatedAt <= c.validUntil,
  );
  assert(
    c.validUntil > c.evaluatedAt &&
      c.validUntil <= Math.min(c.measuredEnd + 2, c.evaluatedAt + 1.5),
  );
  qualifyCadenceAuditEnvelope(cadenceReports);
  const evaluatedRows = [];
  let appliedCount = 0,
    candidateCount = 0,
    confirmedEventIndex;
  let now = boot.at,
    current = boot.receipt,
    revision = '0',
    ack = boot.acknowledgedAt,
    profile = '240p30';
  let lastPolicy = 0,
    lastSource = 0,
    lastEnd,
    lastOwner,
    recoveryStart,
    baseline,
    trial,
    probationStart,
    probationEnd,
    probationWindows = 0,
    confirmation,
    transitions = 0,
    evaluated = 0;
  const sourceFor = (row) => {
    const s = row.source;
    assert(s);
    assert.equal(id(s.attemptID), id(snapshot.scope.publishingAttemptID));
    const matches = snapshot.sourceIntervals.filter(
      (x) =>
        x.sequence === s.sequence &&
        x.workerEpoch === s.workerEpoch &&
        x.workerAttempt === s.workerAttempt,
    );
    assert.equal(matches.length, 1, 'Missing unique native source interval');
    const source = matches[0];
    const proofs = sourceIntervalQualification.intervals.filter(
      (x) => x.sequence === Number(s.sequence),
    );
    assert.equal(proofs.length, 1, 'Missing independently qualified source interval');
    const proof = proofs[0];
    assert.equal(source.previousSequence, s.previousSequence);
    assert.equal(proof.previousSequence, Number(s.previousSequence));
    assert.equal(s.start, source.captureBoundaryStartTime);
    assert.equal(s.end, source.captureBoundaryEndTime);
    assert.equal(s.workerID, source.workerId);
    assert.equal(s.readerID, source.publication.readerId);
    assert.equal(s.processingScopeID, source.processing?.scopeID);
    assert.deepEqual(source.scope, snapshot.scope);
    assert.equal(id(source.publication.publishingAttemptId), id(s.attemptID));
    assert(sequence(s.sequence) > lastSource, 'Reused or reordered source interval');
    if (lastSource) assert.equal(Number(s.previousSequence), lastSource, 'Missing source interval');
    lastSource = Number(s.sequence);
    return { source, proof };
  };
  for (let eventIndex = 1; eventIndex < events.length; eventIndex++) {
    const row = events[eventIndex];
    assert(finite(row.at) && row.at >= now, 'Event clock reversal');
    now = row.at;
    assert(
      ['evaluated', 'applied', 'candidate', 'transition', 'stopped'].includes(row.kind),
      'Invalidated, reset, missing, or unsupported policy evidence',
    );
    if (row.kind === 'applied') {
      appliedCount++;
      assert.equal(appliedCount, 1, 'Duplicate trial application before confirmation');
      assert(
        !trial && !confirmation && baseline && recoveryStart !== undefined,
        'Trial lacks healthy baseline',
      );
      const a = row.action,
        app = row.application,
        native = lifecycleQualification.applications[0];
      assert.equal(a.kind, 'trial');
      assert.equal(a.profileID, '360p30');
      assert.equal(a.bitRate, 600000);
      assert.equal(a.fromRevision, '0');
      assert.equal(row.revision, '1');
      assert.equal(row.profileID, '360p30');
      assert.equal(id(a.candidateID), id(c.id));
      assert.equal(id(app.candidateID), id(c.id));
      id(app.id);
      assert.equal(id(app.attemptID), id(c.attemptID));
      assert.equal(app.fromRevision, '0');
      assert.equal(app.windowSequence, String(lastPolicy));
      const w = baseline.window;
      assert(candidate.evaluatedAt >= baseline.evaluatedAt);
      assert(w.end - recoveryStart >= 4, 'Insufficient initial healthy recovery');
      assert(
        candidate.evaluatedAt - w.end <= 2 && candidate.evaluatedAt - w.observedAt <= 2,
        'Candidate health is stale',
      );
      assert(
        w.end > c.measuredStart && w.start < c.measuredEnd,
        'Selected baseline does not overlap candidate measurement',
      );
      assert.equal(a.validUntil, Math.min(c.validUntil, w.end + 2, w.observedAt + 2));
      assert(
        finite(app.admittedAt) &&
          app.admittedAt >= candidate.evaluatedAt &&
          app.admittedAt >= baseline.at &&
          app.admittedAt <= a.validUntil,
      );
      assert.equal(app.completionDeadline, app.admittedAt + 2);
      receipt(row.receipt);
      assert(
        row.receipt.acceptedAt >= app.admittedAt &&
          row.receipt.acceptedAt <= row.acknowledgedAt &&
          row.acknowledgedAt <= app.completionDeadline &&
          row.acknowledgedAt <= row.at,
      );
      assert.equal(row.receipt.bitRate, 600000);
      assert.equal(row.receipt.generation, current.generation);
      assert.notEqual(row.receipt.configurationID, current.configurationID);
      assert.deepEqual(row.profileReceipt, profileQualification.receipts[0]);
      const p = row.profileReceipt;
      assert.equal(p.previousEncoderSessionID, current.encoderSessionID);
      assert.equal(p.encoderSessionID, row.receipt.encoderSessionID);
      assert.equal(changed.encoderSessionID, row.receipt.encoderSessionID);
      assert.equal(p.publishingGeneration, current.generation);
      assert.equal(p.profile, '360p30');
      assert(p.acknowledgedAt >= app.admittedAt && p.acknowledgedAt <= row.receipt.acceptedAt);
      assert.equal(fixtureFrameID(p.firstNewSourcePTS), changed.firstFrame);
      const frame = fixtureFrameID(row.receipt.lastSubmittedPTS);
      assert(frame >= changed.firstFrame && frame <= changed.lastFrame);
      assert.equal(native.applicationID, app.id);
      assert.equal(native.candidateID, c.id);
      assert.equal(native.target, '360p30');
      assert.deepEqual(native.application, app);
      assert.deepEqual(native.receipt, row.receipt);
      assert.deepEqual(native.profileReceipt, p);
      assert.equal(native.acknowledgedAt, row.acknowledgedAt);
      assert(
        finite(native.requestedAt) &&
          native.requestedAt >= app.admittedAt &&
          native.requestedAt <= p.acknowledgedAt,
      );
      trial = { deadline: row.acknowledgedAt + 22.5, owner: lastOwner };
      current = row.receipt;
      revision = '1';
      ack = row.acknowledgedAt;
      profile = '360p30';
      continue;
    }
    assert.equal(row.revision, revision);
    assert.equal(row.profileID, profile);
    assert.deepEqual(row.receipt, current);
    assert.equal(row.acknowledgedAt, ack);
    if (row.kind === 'candidate') {
      candidateCount++;
      assert.equal(candidateCount, 1, 'Duplicate candidate before confirmation');
      assert(row === candidate && revision === '1');
      continue;
    }
    if (row.kind === 'stopped') {
      assert(row === stop && row.closed === true);
      continue;
    }
    assert.equal(row.closed, false);
    const { source, proof } = sourceFor(row);
    if (row.kind === 'transition') {
      assert(
        trial && probationStart === undefined && transitions === 0,
        'Unexpected probation transition',
      );
      assert(!row.reasons?.length, 'Transition cannot confirm a trial');
      assert(
        row.source.start < ack &&
          row.source.end >= ack &&
          row.source.end - row.source.start <= 5.25,
      );
      assert.deepEqual(owner(row.source), trial.owner);
      transitions++;
      continue;
    }
    const w = row.window,
      s = row.source;
    assert(w && Array.isArray(row.reasons));
    assert.equal(w.revision, revision);
    assert(sequence(w.sequence) > lastPolicy);
    lastPolicy = Number(w.sequence);
    assert.equal(w.start, s.start);
    assert.equal(w.end, s.end);
    assert(w.start >= ack && (lastEnd === undefined || w.start >= lastEnd));
    const duration = w.end - w.start;
    assert(duration >= 1 && duration <= 5.25);
    assert(
      finite(row.evaluatedAt) &&
        row.evaluatedAt >= w.end &&
        row.evaluatedAt <= row.at &&
        row.evaluatedAt - w.end <= 2,
    );
    assert(
      finite(w.observedAt) &&
        w.observedAt >= w.end &&
        w.observedAt <= row.evaluatedAt &&
        row.evaluatedAt - w.observedAt <= 2,
    );
    assert.equal(source.publishingGeneration, current.generation);
    assert.deepEqual(source.encodingConfiguration, {
      id: current.configurationID,
      encoderSessionID: current.encoderSessionID,
      bitRate: current.bitRate,
    });
    for (const [k, p] of [
      ['captured', 'capturedFrames'],
      ['encoded', 'encodedFrames'],
      ['received', 'decodedFrames'],
    ]) {
      assert.equal(w[k], proof[p]);
      assert.equal(w[k], source[p]);
    }
    assert.equal(w.expected, w.captured);
    assert.equal(w.lost, w.captured - w.received);
    assert(w.expected > 0 && w.lost >= 0);
    assert.equal(w.capacity, null);
    replayNativePressure(row, snapshot, source, { transportPolicy });
    const report = cadenceReports.rows.findLast((r) => r.evaluatedUptime <= row.evaluatedAt);
    assert(
      report && row.evaluatedAt - report.evaluatedUptime <= 0.25,
      'Missing fresh raw cadence report',
    );
    const status = report.response.status,
      o = status.observation,
      d = o?.decodedVideo?.completed;
    assert.equal(report.expectedAttempt, id(s.attemptID));
    assert.equal(status.gameId, snapshot.scope.matchID);
    assert.equal(status.generation, snapshot.scope.broadcastGeneration);
    assert.equal(status.state, 'producing_output');
    assert.equal(status.workerId, s.workerID);
    assert.equal(status.workerEpoch, s.workerEpoch);
    assert.equal(o.attempt, s.workerAttempt);
    assert.deepEqual(status.publication, source.publication);
    assert.equal(o.processing.scopeID, s.processingScopeID);
    assert.equal(d.sequence, Number(s.sequence));
    assert.equal(d.firstPTS, Number(source.firstDecodedPTS));
    assert.equal(d.lastPTS, Number(source.lastDecodedPTS));
    assert.equal(d.freshFrames, w.received);
    assert.equal(d.valid, true);
    const age =
      status.decoderCadenceAgeUpperBoundMs / 1000 + report.requestSeconds + report.residenceSeconds;
    assert(finite(age) && age <= 0.25 && Math.abs(age - report.sampleAgeSeconds) < 1e-8);
    assert(
      age + (row.evaluatedAt - report.evaluatedUptime) <= 0.25,
      'Cadence evidence exceeds decision freshness',
    );
    assert.equal(report.observedStall, false);
    const cadence = o.decoderCadence;
    assert.equal(cadence.ended, false);
    assert.equal(cadence.invalidReason, null);
    assert.equal(cadence.progress.stalled, false);
    assert(finite(cadence.progress.ageMs) && cadence.progress.ageMs < 1000);
    const strong =
      w.connectivity === 'connected' &&
      [w.captured, w.encoded, w.received].every((n) => n / duration >= 29.7) &&
      w.lost / w.expected <= 0.01 &&
      finite(w.queue) &&
      w.queue < 0.5 &&
      ['thermal', 'worker', 'transport'].every((k) => w[k] === 'nominal');
    assert(strong, 'Failure episodes require a separate recovery replay');
    assert(
      row.reasons.every((r) => ['missingCapacity', 'telemetryGap', 'trialConfirmed'].includes(r)),
      'Contradictory policy decision',
    );
    const sameOwner =
      lastOwner === undefined || JSON.stringify(owner(s)) === JSON.stringify(lastOwner);
    if (!strong || (lastEnd !== undefined && (lastEnd !== w.start || !sameOwner)))
      recoveryStart = undefined;
    if (strong) recoveryStart ??= w.start;
    if (revision === '0') {
      assert(!row.reasons.includes('trialConfirmed'));
      baseline = strong ? row : undefined;
    } else {
      assert(strong && sameOwner, 'Unhealthy or changed probation ownership');
      if (trial) {
        assert(row.evaluatedAt < trial.deadline, 'Trial deadline expired');
        assert.deepEqual(owner(s), trial.owner);
        assert(
          probationStart !== undefined || w.start <= ack + 5.25,
          'First probation window is too late',
        );
        assert(
          probationEnd === undefined || w.start === probationEnd,
          'Probation is not contiguous',
        );
        probationStart ??= w.start;
        probationEnd = w.end;
        probationWindows++;
        const complete = probationEnd - probationStart >= 10;
        assert.equal(
          row.reasons.includes('trialConfirmed'),
          complete,
          'Confirmation disagrees with independently replayed probation',
        );
        if (complete) {
          confirmation = {
            start: probationStart,
            end: probationEnd,
            coverageSeconds: probationEnd - probationStart,
            windows: probationWindows,
            confirmedAt: row.evaluatedAt,
            deadline: trial.deadline,
          };
          trial = undefined;
        }
      } else assert(!row.reasons.includes('trialConfirmed'), 'Duplicate confirmation');
    }
    lastEnd = w.end;
    lastOwner = owner(s);
    evaluated++;
    evaluatedRows.push(row);
    if (confirmedPrefix && confirmation) {
      confirmedEventIndex = eventIndex;
      break;
    }
  }
  requireUninterruptedCadence(cadenceReports.rows, evaluatedRows, snapshot.scope);
  if (!confirmedPrefix) assert.equal(stop.kind, 'stopped');
  assert.equal(appliedCount, 1);
  assert.equal(candidateCount, 1);
  assert(confirmation && !trial, 'Need completed healthy measured probation');
  return {
    ...(confirmedPrefix
      ? {
          proofExtent: 'confirmed-prefix',
          confirmedEventIndex,
          confirmedAt: confirmation.confirmedAt,
          confirmedEventAt: events[confirmedEventIndex].at,
          nextEventIndex: confirmedEventIndex + 1,
          rawEventCount: events.length,
        }
      : {}),
    ...(recoveryPolicy ? { transportPolicy } : {}),
    evaluated,
    trials: 1,
    confirmed: 1,
    baselineWindowSequence: applied.application.windowSequence,
    transitions,
    probation: confirmation,
    finalProfile: profile,
    finalBitRate: current.bitRate,
    upgradeAuthorized: false,
    scope: confirmedPrefix
      ? 'Confirmed measured policy prefix only; suffix and recovery remain unqualified.'
      : 'Bounded laboratory measured policy replay; independent media/delivery/probe qualification remains required.',
  };
}

/** Complete strict successful-trial route; later resets/invalidation still reject. */
export function qualifyMeasuredTrialPolicy(input) {
  return replayMeasuredTrialPolicy(input);
}

/** Prove only the first confirmed trial from the unchanged complete raw history.
 * The caller must independently qualify the full two-/three-phase native history
 * and lifecycle before supplying their structured results. Neither later native
 * applications nor cadence after this boundary gain policy/recovery credit.
 * No synthetic stop, truncated quality object, or filtered raw audit is created.
 */
export function qualifyMeasuredTrialConfirmedPrefix(input) {
  return replayMeasuredTrialPolicy(input, true);
}
