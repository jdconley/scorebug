import { qualifyCadenceAuditEnvelope } from './cadence-audit-envelope.mjs';
import assert from 'node:assert/strict';
import { replayNativePressure } from './native-quality-pressure.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
import { qualifyNativeDeliveryDeadlines } from './native-delivery-deadlines.mjs';
import { qualifyNativeDeliveryFailureSignal } from './native-deadline-decisions.mjs';
import { qualifyMeasuredCadenceContinuity } from './measured-trial-policy.mjs';
const finite = (n) => Number.isFinite(n) && n >= 0;
const identity = (s) => [
  s.workerID,
  s.workerEpoch,
  s.workerAttempt,
  s.readerID,
  s.processingScopeID,
];
const positiveSequence = (s) => {
  assert(typeof s === 'string' && /^[1-9][0-9]*$/.test(s) && Number.isSafeInteger(Number(s)));
  return Number(s);
};
const uuid = (s) => {
  assert(typeof s === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(s));
  return s.toLowerCase();
};
function owned(row, configuration) {
  assert.equal(row.revision, configuration.revision);
  assert.equal(row.profileID, configuration.profileID);
  assert.deepEqual(row.receipt, configuration.receipt);
  assert.equal(row.acknowledgedAt, configuration.acknowledgedAt);
  assert.deepEqual(row.application, configuration.application);
  assert.deepEqual(row.profileReceipt, configuration.profileReceipt);
}
/** Native failure-lane thresholds and decision labels, without evidence credit. */
export function measuredDeliveryFailureDecision(signal) {
  const duration = signal.end - signal.start;
  assert(finite(signal.start) && finite(signal.end) && [1, 2].includes(duration));
  for (const key of ['expectedFrames', 'onTimeFrames', 'lateFrames', 'missingFrames'])
    assert(Number.isSafeInteger(signal[key]) && signal[key] >= 0);
  assert(
    signal.expectedFrames > 0 &&
      signal.expectedFrames === signal.onTimeFrames + signal.lateFrames + signal.missingFrames,
  );
  assert(
    duration === 1
      ? signal.onTimeFrames < 24
      : (signal.lateFrames + signal.missingFrames) / signal.expectedFrames > 0.05,
  );
  const reasons = [duration === 1 ? 'freshFrameFloor' : 'sourceLoss'];
  if (signal.onTimeFrames === 0) reasons.push('stalled');
  return { state: signal.onTimeFrames === 0 ? 'stalled' : 'degraded', reasons };
}
/** Replays the observed causal decision only; no prefix, recovery, or complete-run
 * qualification is implied. The caller supplies an independently proved prefix
 * and owned-pause contract. Delivery-first and decoder-first routes remain distinct.
 */
export function qualifyMeasuredRecoveryTrigger({
  quality,
  snapshot,
  cadenceReports,
  prefix,
  faultQualification,
  deliveryAudit,
}) {
  const events = quality.events,
    confirmed = events[prefix.confirmedEventIndex];
  const applicationEvents = events.filter((e) => e.kind === 'applied');
  assert.equal(applicationEvents.length, 2);
  const [trial, reset] = applicationEvents;
  const triggerIndex = events.findIndex(
    (e, i) => i >= prefix.nextEventIndex && ['decoderStall', 'deliveryFailure'].includes(e.kind),
  );
  assert(triggerIndex >= prefix.nextEventIndex, 'Missing supported recovery trigger');
  const resetIndex = events.indexOf(reset);
  assert.equal(resetIndex, triggerIndex + 1, 'Reset must immediately follow its causal trigger');
  const trigger = events[triggerIndex],
    signal = trigger.decoderStall ?? trigger.deliveryFailure,
    app = reset.application;
  const decoderTrigger = trigger.kind === 'decoderStall';
  assert(signal);
  if (faultQualification?.triggerKind !== undefined)
    assert.equal(faultQualification.triggerKind, trigger.kind);
  assert.equal(faultQualification?.triggerEventIndex, triggerIndex);
  assert.equal(faultQualification.resetEventIndex, resetIndex);
  assert.equal(faultQualification.triggerEvaluatedAt, trigger.evaluatedAt);
  assert.equal(faultQualification.resetApplicationID, app.id);
  assert.equal(faultQualification.resetAcknowledgedAt, reset.acknowledgedAt);
  if (decoderTrigger) {
    assert.equal(faultQualification.decoderScopeID, signal.scopeID);
    assert.equal(String(faultQualification.lastStalledPTS), signal.lastFreshPTS);
    assert.equal(trigger.state, 'stalled');
    assert.deepEqual(trigger.reasons, ['stalled']);
  } else {
    assert.equal(faultQualification.triggerKind, 'deliveryFailure');
    const failure = qualifyNativeDeliveryFailureSignal({
      event: trigger,
      audit: deliveryAudit,
      reports: cadenceReports,
      scope: snapshot.scope,
    });
    assert.equal(failure.triggerDeliveryRowIndex, faultQualification.triggerDeliveryRowIndex);
    const decision = measuredDeliveryFailureDecision(signal);
    assert.equal(failure.duration, signal.end - signal.start);
    assert.equal(trigger.state, decision.state);
    assert.deepEqual(trigger.reasons, decision.reasons);
    assert.deepEqual(trigger.action, reset.action);
  }
  owned(trigger, trial);
  assert(
    finite(trigger.evaluatedAt) &&
      trigger.evaluatedAt >= prefix.confirmedAt &&
      trigger.evaluatedAt <= trigger.at,
  );
  assert(
    finite(signal.observedAtLowerBound) &&
      signal.observedAtLowerBound >= trial.acknowledgedAt + 1 &&
      signal.observedAtLowerBound <= trigger.evaluatedAt &&
      trigger.evaluatedAt - signal.observedAtLowerBound <= 0.25,
  );
  assert.equal(signal.revision, '1');
  assert.equal(uuid(signal.publishingAttemptID), uuid(snapshot.scope.publishingAttemptID));
  if (decoderTrigger)
    for (const key of ['workerID', 'workerEpoch', 'workerAttempt', 'readerID'])
      assert.equal(signal[key], confirmed.source[key]);
  const triggerReportIndex = cadenceReports.rows.findLastIndex(
    (r) => r.evaluatedUptime <= trigger.evaluatedAt,
  );
  assert(triggerReportIndex >= 0);
  if (faultQualification.triggerCadenceReportIndex !== undefined)
    assert.equal(faultQualification.triggerCadenceReportIndex, triggerReportIndex);
  const triggerReport = cadenceReports.rows[triggerReportIndex],
    triggerStatus = triggerReport.response.status,
    progress = triggerStatus.observation.decoderCadence.progress;
  const lastStalledPTS = Number(faultQualification.lastStalledPTS);
  assert(Number.isSafeInteger(lastStalledPTS) && lastStalledPTS >= 0);
  assert.equal(progress.lastFreshPTS, lastStalledPTS);
  assert.equal(triggerStatus.observation.decoderCadence.scopeID, faultQualification.decoderScopeID);
  if (decoderTrigger) {
    assert.equal(triggerReport.observedStall, true);
    assert.equal(progress.stalled, true);
    assert(progress.ageMs >= 1000);
  } else {
    assert.equal(triggerReport.observedStall, progress.stalled);
    assert.equal(progress.stalled, progress.ageMs >= 1000);
    const stallIndex = cadenceReports.rows.findIndex(
      (r, i) => i >= triggerReportIndex && r.observedStall === true,
    );
    assert.equal(stallIndex, faultQualification.stalledCadenceReportIndex);
    const stalled = cadenceReports.rows[stallIndex];
    assert(stalled && stalled.evaluatedUptime >= triggerReport.evaluatedUptime);
    assert.equal(
      stalled.response.status.observation.decoderCadence.scopeID,
      faultQualification.decoderScopeID,
    );
    assert.equal(
      stalled.response.status.observation.decoderCadence.progress.lastFreshPTS,
      lastStalledPTS,
    );
    assert.equal(stalled.response.status.observation.decoderCadence.progress.stalled, true);
    assert(stalled.response.status.observation.decoderCadence.progress.ageMs >= 1000);
  }
  const triggerAge =
    triggerStatus.decoderCadenceAgeUpperBoundMs / 1000 +
    triggerReport.requestSeconds +
    triggerReport.residenceSeconds +
    (trigger.evaluatedAt - triggerReport.evaluatedUptime);
  assert(finite(triggerAge) && triggerAge <= 0.25, 'Causal decoder sample is stale');
  assert.equal(reset.application.windowSequence, signal.sequence);
  const expectedExpiry = decoderTrigger
    ? signal.observedAtLowerBound + 0.25
    : Math.min(signal.end + 2, signal.observedAtLowerBound + 0.25);
  assert.equal(reset.action.validUntil, expectedExpiry);
  return {
    trial,
    reset,
    trigger,
    signal,
    triggerIndex,
    resetIndex,
    triggerReport,
    lastStalledPTS,
    expectedExpiry,
  };
}
/** Observed decoder-stall or native delivery-failure reset routes only. Caller independently recomputes the full
 * native/source/lifecycle proofs, confirmed prefix, and causal owned-fault proof.
 * Those are structured dependency contracts, not permission booleans. This replay
 * independently validates raw delivery classifications and source/pressure/cadence
 * suffix evidence; it does not establish the external fault's freshness itself.
 */
export function qualifyMeasuredRecoveryPolicy({
  quality,
  snapshot,
  cadenceReports,
  sourceIntervalQualification,
  profileQualification,
  lifecycleQualification,
  prefix,
  faultQualification,
  deliveryAudit,
}) {
  assert.equal(quality.formatVersion, 4);
  assert.equal(quality.overflow, false);
  assert.equal(quality.measuredSourceEvaluationEnabled, true);
  assert.equal(quality.decoderStallEnabled, true);
  const events = quality.events;
  assert(Array.isArray(events) && events.length <= 512);
  assert.equal(prefix?.proofExtent, 'confirmed-prefix');
  assert.equal(prefix.rawEventCount, events.length);
  assert(Number.isSafeInteger(prefix.confirmedEventIndex) && prefix.confirmedEventIndex > 0);
  assert.equal(prefix.nextEventIndex, prefix.confirmedEventIndex + 1);
  const confirmed = events[prefix.confirmedEventIndex];
  assert.equal(confirmed?.kind, 'evaluated');
  assert(confirmed.reasons.includes('trialConfirmed'));
  assert.equal(prefix.confirmedAt, confirmed.evaluatedAt);
  assert.equal(prefix.confirmedEventAt, confirmed.at);
  assert.equal(prefix.probation.end, confirmed.window.end);
  assert(prefix.probation.coverageSeconds >= 10);
  assert.equal(confirmed.revision, '1');
  for (const p of [sourceIntervalQualification, profileQualification, lifecycleQualification])
    assert.deepEqual(p?.scope, snapshot.scope);
  assert.equal(profileQualification.phases?.length, 3);
  assert.equal(profileQualification.receipts?.length, 2);
  assert.equal(lifecycleQualification.applications?.length, 2);
  assert(
    Array.isArray(sourceIntervalQualification.intervals) &&
      sourceIntervalQualification.intervals.length <= 512,
  );
  assert(Array.isArray(snapshot.sourceIntervals) && snapshot.sourceIntervals.length <= 512);
  qualifyCadenceAuditEnvelope(cadenceReports);
  const {
    trial,
    reset,
    trigger,
    signal,
    triggerIndex,
    resetIndex,
    triggerReport,
    lastStalledPTS,
    expectedExpiry,
  } = qualifyMeasuredRecoveryTrigger({
    quality,
    snapshot,
    cadenceReports,
    prefix,
    faultQualification,
    deliveryAudit,
  });
  const app = reset.application,
    native = lifecycleQualification.applications[1];
  assert.equal(reset.revision, '2');
  assert.equal(reset.profileID, '240p30');
  assert.equal(reset.receipt.bitRate, 350000);
  assert.equal(reset.action.kind, 'reset');
  assert.equal(reset.action.fromRevision, '1');
  assert.equal(reset.action.profileID, '240p30');
  assert.equal(reset.action.bitRate, 350000);
  assert.equal(reset.action.candidateID, null);
  assert.equal(app.fromRevision, '1');
  assert.equal(app.candidateID, null);
  assert.equal(app.windowSequence, signal.sequence);
  assert.equal(uuid(app.attemptID), uuid(snapshot.scope.publishingAttemptID));
  uuid(app.id);
  assert.notEqual(app.id, trial.application.id);
  assert.equal(reset.action.validUntil, expectedExpiry);
  assert(
    finite(app.admittedAt) &&
      app.admittedAt >= trigger.at &&
      app.admittedAt <= reset.action.validUntil,
  );
  assert.equal(app.completionDeadline, app.admittedAt + 2);
  assert(
    finite(reset.acknowledgedAt) &&
      reset.receipt.acceptedAt >= app.admittedAt &&
      reset.receipt.acceptedAt <= reset.acknowledgedAt &&
      reset.acknowledgedAt <= app.completionDeadline &&
      reset.acknowledgedAt <= reset.at,
  );
  assert.equal(native.applicationID, app.id);
  assert.equal(native.target, '240p30');
  assert.equal(native.candidateID, null);
  assert.deepEqual(native.application, app);
  assert.deepEqual(native.receipt, reset.receipt);
  assert.deepEqual(native.profileReceipt, reset.profileReceipt);
  assert.equal(native.acknowledgedAt, reset.acknowledgedAt);
  assert(
    finite(native.requestedAt) &&
      native.requestedAt >= app.admittedAt &&
      native.requestedAt <= reset.profileReceipt.acknowledgedAt,
  );
  assert(reset.profileReceipt.acknowledgedAt <= reset.receipt.acceptedAt);
  assert.deepEqual(reset.profileReceipt, profileQualification.receipts[1]);
  const phase = profileQualification.phases[2];
  assert.equal(phase.width, 426);
  assert.equal(phase.height, 240);
  assert.equal(phase.encoderSessionID, reset.receipt.encoderSessionID);
  assert.equal(reset.profileReceipt.previousEncoderSessionID, trial.receipt.encoderSessionID);
  assert.equal(reset.receipt.generation, trial.receipt.generation);
  assert.equal(reset.profileReceipt.publishingGeneration, reset.receipt.generation);
  assert.notEqual(reset.receipt.configurationID, trial.receipt.configurationID);
  uuid(reset.receipt.configurationID);
  uuid(reset.receipt.encoderSessionID);
  assert.equal(fixtureFrameID(reset.profileReceipt.firstNewSourcePTS), phase.firstFrame);
  const receiptFrame = fixtureFrameID(reset.receipt.lastSubmittedPTS);
  assert(receiptFrame >= phase.firstFrame && receiptFrame <= phase.lastFrame);
  let lastAt = confirmed.at,
    lastPolicy = positiveSequence(confirmed.window.sequence),
    lastSource = positiveSequence(confirmed.source.sequence),
    lastEnd = confirmed.window.end,
    transitionCount = 0;
  const healthyWindows = [];
  for (let index = prefix.nextEventIndex; index < events.length; index++) {
    const row = events[index];
    assert(finite(row.at) && row.at >= lastAt, 'Suffix event clock reversal');
    lastAt = row.at;
    assert(
      ['evaluated', 'decoderStall', 'deliveryFailure', 'applied', 'transition', 'stopped'].includes(
        row.kind,
      ),
      'Unsupported or invalidated recovery suffix',
    );
    if (index === triggerIndex) {
      assert.equal(positiveSequence(signal.sequence), lastPolicy + 1);
      lastPolicy = Number(signal.sequence);
      continue;
    }
    if (index === resetIndex) continue;
    const configuration = index < resetIndex ? trial : reset;
    owned(row, configuration);
    if (row.kind === 'stopped') {
      assert.equal(index, events.length - 1);
      assert.equal(row.closed, true);
      continue;
    }
    assert.equal(row.closed, false);
    assert(
      ['evaluated', 'transition'].includes(row.kind),
      'Unmatched failure or application in suffix',
    );
    const s = row.source;
    assert(s);
    assert.deepEqual(identity(s), identity(confirmed.source));
    assert.equal(uuid(s.attemptID), uuid(snapshot.scope.publishingAttemptID));
    const matches = snapshot.sourceIntervals.filter(
      (x) =>
        x.sequence === s.sequence &&
        x.workerEpoch === s.workerEpoch &&
        x.workerAttempt === s.workerAttempt,
    );
    assert.equal(matches.length, 1);
    const source = matches[0];
    const proofs = sourceIntervalQualification.intervals.filter(
      (x) => x.sequence === Number(s.sequence),
    );
    assert.equal(proofs.length, 1);
    const proof = proofs[0];
    assert.deepEqual(source.scope, snapshot.scope);
    assert.equal(source.workerId, s.workerID);
    assert.equal(source.publication.readerId, s.readerID);
    assert.equal(source.processing?.scopeID, s.processingScopeID);
    assert.equal(source.previousSequence, s.previousSequence);
    assert.equal(Number(s.previousSequence), lastSource);
    assert.equal(proof.previousSequence, lastSource);
    assert.equal(positiveSequence(s.sequence), lastSource + 1);
    lastSource = Number(s.sequence);
    assert.equal(s.start, source.captureBoundaryStartTime);
    assert.equal(s.end, source.captureBoundaryEndTime);
    if (row.kind === 'transition') {
      assert(index > resetIndex && healthyWindows.length === 0 && transitionCount === 0);
      assert(
        s.start < reset.acknowledgedAt && s.end >= reset.acknowledgedAt && s.end - s.start <= 5.25,
      );
      assert.equal(s.start, lastEnd);
      assert(s.end <= row.at, 'Transition precedes its source boundary');
      assert(!row.reasons?.length);
      transitionCount++;
      lastEnd = s.end;
      continue;
    }
    const w = row.window;
    assert(w);
    assert.equal(positiveSequence(w.sequence), lastPolicy + 1);
    lastPolicy = Number(w.sequence);
    assert.equal(w.revision, configuration.revision);
    assert.equal(w.start, s.start);
    assert.equal(w.end, s.end);
    assert.equal(w.start, lastEnd, 'Recovery source window gap');
    lastEnd = w.end;
    const duration = w.end - w.start;
    assert(duration >= 1 && duration <= 5.25 && w.start >= configuration.acknowledgedAt);
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
    assert.equal(source.publishingGeneration, configuration.receipt.generation);
    assert.deepEqual(source.encodingConfiguration, {
      id: configuration.receipt.configurationID,
      encoderSessionID: configuration.receipt.encoderSessionID,
      bitRate: configuration.receipt.bitRate,
    });
    for (const [key, name] of [
      ['captured', 'capturedFrames'],
      ['encoded', 'encodedFrames'],
      ['received', 'decodedFrames'],
    ]) {
      assert.equal(w[key], proof[name]);
      assert.equal(w[key], source[name]);
      assert(w[key] / duration >= (index > resetIndex ? 29.7 : 24));
    }
    assert.equal(w.expected, w.captured);
    assert.equal(w.lost, w.captured - w.received);
    assert(w.expected > 0 && w.lost >= 0 && w.lost / w.expected <= 0.01);
    assert.equal(w.capacity, null);
    assert.equal(w.connectivity, 'connected');
    replayNativePressure(row, snapshot, source, { recoveryBudget: true });
    assert(finite(w.queue) && w.queue < 0.5);
    for (const key of ['thermal', 'worker', 'transport']) assert.equal(w[key], 'nominal');
    assert(
      Array.isArray(row.reasons) &&
        row.reasons.includes('missingCapacity') &&
        row.reasons.every(
          (r) =>
            r === 'missingCapacity' ||
            (index > resetIndex && healthyWindows.length === 0 && r === 'telemetryGap'),
        ),
    );
    const report = cadenceReports.rows.findLast((r) => r.evaluatedUptime <= row.evaluatedAt);
    assert(report);
    const status = report.response.status,
      o = status.observation,
      d = o?.decodedVideo?.completed;
    assert.equal(status.workerId, s.workerID);
    assert.equal(status.workerEpoch, s.workerEpoch);
    assert.equal(o.attempt, s.workerAttempt);
    assert.deepEqual(status.publication, source.publication);
    assert.equal(o.processing?.scopeID, s.processingScopeID);
    assert.equal(d.sequence, Number(s.sequence));
    assert.equal(d.firstPTS, Number(source.firstDecodedPTS));
    assert.equal(d.lastPTS, Number(source.lastDecodedPTS));
    assert.equal(d.freshFrames, w.received);
    assert.equal(d.valid, true);
    const age =
      status.decoderCadenceAgeUpperBoundMs / 1000 +
      report.requestSeconds +
      report.residenceSeconds +
      (row.evaluatedAt - report.evaluatedUptime);
    assert(finite(age) && age <= 0.25, 'Recovery decision cadence is stale');
    assert.equal(report.observedStall, false);
    if (index > resetIndex) {
      assert.equal(transitionCount, 1);
      healthyWindows.push({
        eventIndex: index,
        policySequence: w.sequence,
        sourceSequence: s.sequence,
        start: w.start,
        end: w.end,
        evaluatedAt: row.evaluatedAt,
      });
    }
  }
  const stop = events.at(-1);
  assert.equal(stop.kind, 'stopped');
  assert(healthyWindows.length > 0);
  const delivery = qualifyNativeDeliveryDeadlines({
    audit: deliveryAudit,
    reports: cadenceReports,
    scope: snapshot.scope,
    expectedLatencyBudget: 1.5,
  });
  const receipt = {
    acceptedAt: reset.receipt.acceptedAt,
    generation: reset.receipt.generation,
    lastSubmittedPTS: reset.receipt.lastSubmittedPTS,
    configuration: {
      id: uuid(reset.receipt.configurationID),
      encoderSessionID: uuid(reset.receipt.encoderSessionID),
      bitRate: 350000,
    },
  };
  const lanes = [1, 2].map((duration) => {
    const rows = deliveryAudit.rows.filter(
      (r) => r.appliedRevision === '2' && r.end - r.start === duration,
    );
    assert(rows.length > 0, 'Missing post-reset delivery lane');
    let end = rows[0].start;
    assert(end >= reset.acknowledgedAt);
    for (const row of rows) {
      assert.equal(row.start, end, 'Post-reset delivery lane gap');
      end = row.end;
      assert(end <= stop.at && row.evaluatedAt <= stop.at);
      assert.equal(row.profileID, '240p30');
      assert.equal(row.acknowledgedAt, reset.acknowledgedAt);
      assert.deepEqual(row.receipt, receipt);
      assert.equal(row.reason, null, 'Unhealthy recovery delivery classification');
      assert.equal(row.result.uncertainFrames, 0);
      assert.equal(row.result.lateFrames, 0);
      assert.equal(row.result.missingFrames, 0);
      assert(row.result.onTimeFrames / duration >= 30, 'Unhealthy recovery delivery');
      for (const frame of row.frames) {
        const id = fixtureFrameID(frame.sourcePTS);
        assert(
          id >= phase.firstFrame && id <= phase.lastFrame,
          'Delivery escaped reset encoder phase',
        );
      }
    }
    return { duration, start: rows[0].start, end, rowCount: rows.length };
  });
  // Source/processing intervals may begin while the owned pause is still being
  // observed. Credit only whole windows after fresh progress resumes; validate
  // earlier source windows structurally without awarding partial health.
  const resumed = cadenceReports.rows.find(
    (r) =>
      r.evaluatedUptime > triggerReport.evaluatedUptime &&
      r.observedStall === false &&
      r.response.status.observation?.decoderCadence?.progress?.lastFreshPTS > lastStalledPTS,
  );
  assert(resumed, 'Missing resumed decoder progress');
  const resumedAt = resumed.evaluatedUptime;
  const eligible = healthyWindows.filter(
    (w) => w.start >= resumedAt && lanes.every((l) => w.start >= l.start && w.end <= l.end),
  );
  assert(eligible.length > 0, 'No whole source window has both delivery lanes');
  const credited = [];
  let creditEnd = eligible[0].start;
  for (const window of eligible) {
    assert.equal(window.start, creditEnd);
    credited.push(window);
    creditEnd = window.end;
    if (creditEnd - eligible[0].start >= 10) break;
  }
  assert(creditEnd - eligible[0].start >= 10, 'Insufficient contiguous shared recovery coverage');
  const sharedCoverage = {
    start: eligible[0].start,
    end: creditEnd,
    coverageSeconds: creditEnd - eligible[0].start,
    windowCount: credited.length,
    policyWindowSequences: credited.map((w) => w.policySequence),
    sourceWindowSequences: credited.map((w) => w.sourceSequence),
  };
  const prefixReport = cadenceReports.rows.findLast((r) => r.evaluatedUptime <= prefix.confirmedAt);
  assert(prefixReport);
  // Cadence closes before asynchronous publisher shutdown/export joins. Require
  // all source/delivery decisions to fit the actual audit, then inspect every
  // remaining report; the later stopped log adds no telemetry coverage.
  const cadenceCheckedThrough = cadenceReports.rows.at(-1).evaluatedUptime;
  assert(
    cadenceCheckedThrough >= healthyWindows.at(-1).evaluatedAt && cadenceCheckedThrough <= stop.at,
  );
  for (const row of deliveryAudit.rows.filter((row) => row.appliedRevision === '2'))
    assert(row.evaluatedAt <= cadenceCheckedThrough);
  // The control task may consume a second fresh report of the same owned pause.
  // Preserve that causal trigger; include only adjacent preceding reports of its
  // identical stalled progress in the allowance, never in healthy recovery credit.
  let cadenceAllowedStallStart = triggerReport.evaluatedUptime;
  if (triggerReport.observedStall === true) {
    const scopeID = triggerReport.response.status.observation.decoderCadence.scopeID;
    for (let index = cadenceReports.rows.indexOf(triggerReport) - 1; index >= 0; index--) {
      const row = cadenceReports.rows[index],
        status = row.response?.status;
      const cadence = status?.observation?.decoderCadence,
        progress = cadence?.progress;
      if (
        row.observedStall !== true ||
        progress?.stalled !== true ||
        progress.lastFreshPTS !== lastStalledPTS ||
        cadence.scopeID !== scopeID
      )
        break;
      assert(row.evaluatedUptime >= prefix.confirmedAt, 'Owned stall precedes confirmation');
      const upperReaction =
        progress.ageMs / 1000 + row.sampleAgeSeconds + trigger.evaluatedAt - row.evaluatedUptime;
      assert(
        finite(upperReaction) && upperReaction <= 1.5,
        'Earlier stall report exceeds reaction budget',
      );
      const ttl = Math.max(
        0,
        Math.min(5, (Date.parse(status.expiresAt) - Date.parse(row.response.serverTime)) / 1000),
      );
      assert(
        row.evaluatedUptime < row.receivedUptime + ttl - row.requestSeconds,
        'Expired earlier stall report',
      );
      cadenceAllowedStallStart = row.evaluatedUptime;
    }
  }
  qualifyMeasuredCadenceContinuity({
    reports: cadenceReports.rows,
    start: prefixReport.evaluatedUptime,
    end: cadenceCheckedThrough,
    source: confirmed.source,
    scope: snapshot.scope,
    allowedStall: {
      start: cadenceAllowedStallStart,
      end: sharedCoverage.start,
      lastFreshPTS: lastStalledPTS,
    },
  });
  return {
    recoveryPolicyQualified: true,
    productionUpgradeAuthorized: false,
    triggerEventIndex: triggerIndex,
    resetEventIndex: resetIndex,
    resetApplicationID: app.id,
    resetAcknowledgedAt: reset.acknowledgedAt,
    healthyWindows,
    resumedAt,
    cadenceCheckedThrough,
    cadenceAllowedStallStart,
    sharedCoverage,
    deliveryLanes: lanes,
    delivery,
    scope:
      'Observed decoder-stall or native delivery-failure reset suffix only; independently qualified confirmed prefix and external causal fault remain required.',
  };
}
