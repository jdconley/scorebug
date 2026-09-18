import { qualifiedDeliverySampleBounds } from './native-delivery-deadlines.mjs';
import assert from 'node:assert/strict';
import { basename } from 'node:path';
import { qualifyNativeStallSignal } from './native-controlled-stall.mjs';
import {
  ownedPause,
  qualifyOwnedPauseSample,
  qualifyNativeDeliveryFailureSignal,
} from './native-deadline-decisions.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';

const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0;
const same = (a, b, message) => assert.deepEqual(a, b, message);
const canonical = (n) => typeof n === 'string' && /^(0|[1-9][0-9]*)$/.test(n);
function context(row) {
  const s = row.response.status;
  return {
    gameId: s.gameId,
    generation: s.generation,
    workerId: s.workerId,
    workerEpoch: s.workerEpoch,
    attempt: s.observation.attempt,
    publication: s.publication,
  };
}

function freshCadence(row, owner, at = row.evaluatedUptime) {
  same(context(row), owner, 'Causal decoder owner changed');
  const status = row.response.status,
    c = status.observation.decoderCadence;
  assert(
    c?.formatVersion === 1 &&
      c.ended === false &&
      c.invalidReason === null &&
      Number.isSafeInteger(c.progress?.lastFreshPTS) &&
      c.progress.lastFreshPTS >= 0 &&
      finite(c.progress.ageMs),
    'Invalid causal decoder cadence',
  );
  assert.equal(c.progress.stalled, c.progress.ageMs >= 1000);
  assert.equal(row.observedStall, c.progress.stalled, 'Unavailable causal cadence');
  const age =
    status.decoderCadenceAgeUpperBoundMs / 1000 + row.requestSeconds + row.residenceSeconds;
  assert(
    Number.isSafeInteger(status.decoderCadenceAgeUpperBoundMs) &&
      status.decoderCadenceAgeUpperBoundMs >= 0 &&
      finite(row.requestSeconds) &&
      finite(row.residenceSeconds) &&
      finite(age) &&
      Math.abs(age - row.sampleAgeSeconds) < 1e-8 &&
      finite(at - row.evaluatedUptime) &&
      age + at - row.evaluatedUptime <= 0.25,
    'Stale causal decoder cadence',
  );
  const ttl = Math.max(
    0,
    Math.min(5, (Date.parse(status.expiresAt) - Date.parse(row.response.serverTime)) / 1000),
  );
  assert(at < row.receivedUptime + ttl - row.requestSeconds, 'Expired causal decoder cadence');
  return c;
}
function deliveryFaultSignal({ trigger, deliveryAudit, cadenceReports, fault, scope }) {
  const qualified = qualifyNativeDeliveryFailureSignal({
    event: trigger,
    audit: deliveryAudit,
    reports: cadenceReports,
    scope,
  });
  const { row, duration, triggerDeliveryRowIndex } = qualified,
    d = trigger.deliveryFailure;
  assert.equal(trigger.revision, '1');
  assert(duration === 1 || duration === 2, 'Unsupported delivery failure lane');
  const reasons = [duration === 1 ? 'freshFrameFloor' : 'sourceLoss'];
  if (d.onTimeFrames === 0) reasons.push('stalled');
  same(trigger.reasons, reasons, 'Wrong delivery failure reasons');
  assert.equal(trigger.state, d.onTimeFrames === 0 ? 'stalled' : 'degraded');
  const triggerCadenceReportIndex = cadenceReports.rows.findLastIndex(
    (r) => r.evaluatedUptime <= trigger.evaluatedAt,
  );
  assert(triggerCadenceReportIndex >= 0, 'Missing causal delivery report');
  const report = cadenceReports.rows[triggerCadenceReportIndex];
  assert.equal(
    report.deliveryReceiptID,
    d.deliveryReceiptID,
    'Deadline signal differs from current raw receipt',
  );
  const owner = row.context,
    c = freshCadence(report, owner, trigger.evaluatedAt),
    lastPTS = BigInt(c.progress.lastFreshPTS);
  const sample = qualifiedDeliverySampleBounds(row, qualified.ageAtClassification);
  const arrivals = new Map();
  for (const a of row.timeline.arrivals)
    if (!arrivals.has(String(a.pts))) arrivals.set(String(a.pts), a.ageMs / 1000);
  assert(
    row.frames.some((f) => {
      const age = arrivals.get(f.pts),
        delta = BigInt(f.pts) - lastPTS;
      return (
        delta > 0n &&
        delta < 180000n &&
        f.capturedAt + 1.5 < sample.lower &&
        (age === undefined ||
          (row.sampleTimeBounds
            ? sample.lower - age
            : row.evaluatedAt - age - qualified.ageAtClassification) >
            f.capturedAt + 1.5)
      );
    }),
    'Deadline failure lacks matured source beyond paused decoder anchor',
  );
  let stalledCadenceReportIndex, resumedCadenceReportIndex;
  for (let i = triggerCadenceReportIndex; i < cadenceReports.rows.length; i++) {
    const nextRow = cadenceReports.rows[i],
      next = freshCadence(nextRow, owner);
    assert.equal(next.scopeID, c.scopeID, 'Causal decoder scope changed');
    assert(next.progress.lastFreshPTS >= Number(lastPTS), 'Causal decoder progress regressed');
    if (stalledCadenceReportIndex === undefined) {
      assert.equal(
        next.progress.lastFreshPTS,
        Number(lastPTS),
        'Decoder advanced before owned stall',
      );
      assert(
        nextRow.evaluatedUptime <= trigger.evaluatedAt + 2.5,
        'Missing nearby native decoder stall',
      );
      if (next.progress.stalled) stalledCadenceReportIndex = i;
    } else if (!next.progress.stalled && next.progress.lastFreshPTS > Number(lastPTS)) {
      resumedCadenceReportIndex = i;
      break;
    }
  }
  assert(
    stalledCadenceReportIndex !== undefined && resumedCadenceReportIndex !== undefined,
    'Missing owned raw stall and resumed progress',
  );
  return {
    triggerDeliveryRowIndex,
    triggerCadenceReportIndex,
    stalledCadenceReportIndex,
    pauseMilliseconds: ownedPause(fault),
    decoderScopeID: c.scopeID,
    lastStalledPTS: String(lastPTS),
    admittedSampleAgeSeconds: trigger.evaluatedAt - d.observedAtLowerBound,
    decisionToObservedRecoverySeconds:
      cadenceReports.rows[resumedCadenceReportIndex].evaluatedUptime - trigger.evaluatedAt,
  };
}

/** Retrospective owned decoder-stall causality only. Source/native qualifications
 * are independently replayed by the composition; this joins their exact facts.
 * Node times never share an epoch with native capture/decision uptime. */
export function qualifyMeasuredRecoveryFault({
  fault,
  quality,
  cadenceReports,
  deliveryAudit,
  scope,
  prefix,
  snapshot,
  format,
  sourceIntervalQualification,
  profileQualification,
  archiveIDs,
  liveIDs,
}) {
  assert.equal(fault?.formatVersion, 1);
  assert.equal(fault.delayBeforePauseMs, 70000, 'Wrong measured recovery pause schedule');
  ownedPause(fault);
  for (const [kind, p] of Object.entries(fault.identity)) {
    assert(['worker', 'guardian', 'decoder'].includes(kind), 'Unexpected process identity');
    assert(
      Number.isSafeInteger(p.ppid) &&
        p.ppid > 0 &&
        typeof p.start === 'string' &&
        p.start.trim().length > 0 &&
        Number.isFinite(Date.parse(p.start)),
      'Missing process start identity',
    );
    assert(
      typeof p.command === 'string' &&
        basename(p.command) === (kind === 'decoder' ? 'ffmpeg' : 'node'),
      'Unexpected owned process executable',
    );
  }
  same(scope, snapshot.scope, 'Fault scope differs from native source');
  same(sourceIntervalQualification.scope, scope, 'Fault scope differs from qualified source');
  assert(
    quality.decoderStallEnabled === true && quality.measuredSourceEvaluationEnabled === true,
    'Measured decoder stall must be enabled',
  );
  const events = quality.events,
    confirmed = events[prefix.confirmedEventIndex];
  assert(
    prefix.proofExtent === 'confirmed-prefix' &&
      prefix.confirmed === 1 &&
      confirmed?.kind === 'evaluated' &&
      confirmed.reasons?.includes('trialConfirmed') &&
      confirmed.revision === '1' &&
      confirmed.profileID === '360p30' &&
      confirmed.evaluatedAt === prefix.confirmedAt &&
      confirmed.at === prefix.confirmedEventAt,
    'Fault lacks exact independently confirmed prefix',
  );
  const triggers = events
    .map((e, i) => ({ e, i }))
    .filter(({ e }) => ['decoderStall', 'deliveryFailure'].includes(e.kind));
  assert.equal(triggers.length, 1, 'Recovery requires exactly one supported failure');
  const { e: trigger, i: triggerEventIndex } = triggers[0];
  assert(
    triggerEventIndex > prefix.confirmedEventIndex && trigger.evaluatedAt > prefix.confirmedAt,
    'Stall precedes confirmation',
  );
  assert.equal(trigger.profileID, '360p30');
  for (const key of ['receipt', 'profileReceipt', 'application', 'acknowledgedAt'])
    same(trigger[key], confirmed[key], `Stall ${key} differs from confirmed native state`);
  assert(
    (trigger.kind === 'deliveryFailure' ||
      (trigger.deliveryFailure === undefined && trigger.action === undefined)) &&
      trigger.closed === false,
    'Unsupported competing or closed stall signal',
  );
  assert(
    !events
      .slice(prefix.confirmedEventIndex + 1, triggerEventIndex)
      .some((e) =>
        ['deliveryFailure', 'failed', 'applied', 'watchdog', 'stopped'].includes(e.kind),
      ),
    'Unsupported competing trigger before decoder stall',
  );
  assert(quality.formatVersion === 4 && quality.overflow === false && events.length <= 512);
  assert(
    events.at(-1)?.kind === 'stopped' && events.at(-1).closed === true,
    'Missing final closed stop',
  );
  assert(
    cadenceReports.closed === true &&
      cadenceReports.overflow === false &&
      cadenceReports.invalid === false,
  );
  const signal =
    trigger.kind === 'deliveryFailure'
      ? deliveryFaultSignal({ trigger, deliveryAudit, cadenceReports, fault, scope })
      : qualifyNativeStallSignal(
          { quality, audit: cadenceReports, fault, scope, expectedRevision: '1' },
          trigger,
        );
  const decision = trigger.deliveryFailure ?? trigger.decoderStall;
  if (trigger.kind === 'deliveryFailure') {
    assert.equal(quality.deadlineFailuresEnabled, true);
    assert.equal(trigger.decoderStall, undefined);
  }
  const report = cadenceReports.rows[signal.triggerCadenceReportIndex],
    owner = context(report),
    c = report.response.status.observation.decoderCadence;
  assert(
    owner.gameId === scope.matchID &&
      owner.generation === scope.broadcastGeneration &&
      owner.publication.publishingAttemptId === scope.publishingAttemptID.toLowerCase(),
    'Native stall report belongs to another publication',
  );
  const serverAge = report.response.status.decoderCadenceAgeUpperBoundMs / 1000,
    age = serverAge + report.requestSeconds + report.residenceSeconds,
    delay = trigger.evaluatedAt - report.evaluatedUptime;
  assert(
    finite(serverAge) &&
      finite(report.requestSeconds) &&
      finite(report.residenceSeconds) &&
      finite(age) &&
      Math.abs(age - report.sampleAgeSeconds) < 1e-8 &&
      age + delay <= 0.25,
    'Native stall report stale at decision',
  );
  const ttl = Math.max(
    0,
    Math.min(
      5,
      (Date.parse(report.response.status.expiresAt) - Date.parse(report.response.serverTime)) /
        1000,
    ),
  );
  assert(
    trigger.evaluatedAt < report.receivedUptime + ttl - report.requestSeconds,
    'Native stall report expired at decision',
  );
  assert(
    c.formatVersion === 1 && c.ended === false && c.invalidReason === null,
    'Invalid native stall cadence',
  );
  qualifyOwnedPauseSample(fault, owner, signal);

  const beforePTS = BigInt(fault.beforePauseSample.value.decoderCadence.progress.lastFreshPTS);
  const intervals = snapshot.sourceIntervals.filter(
    (r) =>
      canonical(r.previousDecodedPTS) &&
      canonical(r.lastDecodedPTS) &&
      BigInt(r.previousDecodedPTS) < beforePTS &&
      beforePTS <= BigInt(r.lastDecodedPTS),
  );
  assert.equal(intervals.length, 1, 'Pre-pause PTS needs one exact source interval');
  const interval = intervals[0],
    summaries = sourceIntervalQualification.intervals.filter(
      (r) => String(r.sequence) === interval.sequence,
    );
  assert.equal(summaries.length, 1, 'Pre-pause source interval was not independently qualified');
  const summary = summaries[0],
    start = fixtureFrameID(interval.sourceStartExclusive),
    end = fixtureFrameID(interval.sourceEndInclusive),
    delta = beforePTS - BigInt(interval.previousDecodedPTS);
  assert(delta > 0n && delta % 3000n === 0n, 'Pre-pause PTS is not an exact source frame');
  same(
    [summary.sourceStartExclusive, summary.sourceEndInclusive, String(summary.previousSequence)],
    [start, end, interval.previousSequence],
    'Source qualification boundaries differ',
  );
  for (const key of [
    'capturedFrames',
    'encodedFrames',
    'decodedFrames',
    'captureNotEncodedFrames',
    'encodedNotDecodedFrames',
    'leadingMissingEncodedFrames',
  ])
    same(summary[key], interval[key], `Source qualification ${key} differs`);
  same(interval.scope, scope, 'Foreign source scope');
  same(
    {
      gameId: scope.matchID,
      generation: scope.broadcastGeneration,
      workerId: interval.workerId,
      workerEpoch: interval.workerEpoch,
      attempt: interval.workerAttempt,
      publication: interval.publication,
    },
    owner,
    'Pre-pause source owner differs from raw stall',
  );
  assert(
    finite(interval.captureBoundaryStartTime) &&
      finite(interval.captureBoundaryEndTime) &&
      interval.captureBoundaryStartTime > prefix.confirmedEventAt &&
      interval.captureBoundaryEndTime > interval.captureBoundaryStartTime,
    'Pre-pause source capture does not prove after confirmation',
  );
  const frame = start + Number(delta / 3000n),
    phase = profileQualification.phases[1];
  assert(
    Number.isSafeInteger(frame) &&
      frame > start &&
      frame <= end &&
      phase.width === 640 &&
      phase.height === 360 &&
      frame >= phase.firstFrame &&
      frame <= phase.lastFrame,
    'Pre-pause frame is outside native 360 phase',
  );
  assert(
    archiveIDs.includes(frame) && liveIDs.includes(frame),
    'Pre-pause source absent from archive or live decode',
  );
  same(format.scope, scope, 'Foreign native frame scope');
  const frames = format.compressedFrames
    .map((r, index) => ({ r, index }))
    .filter(({ r }) => fixtureFrameID(r.sourcePTS) === frame);
  assert.equal(frames.length, 1, 'Pre-pause source absent from exact native frames');
  const native = frames[0],
    phaseStart = profileQualification.phases[0].nativeFrames;
  assert(
    native.index >= phaseStart &&
      native.index < phaseStart + phase.nativeFrames &&
      native.r.observedAt > interval.captureBoundaryStartTime &&
      native.r.observedAt < trigger.evaluatedAt,
    'Pre-pause native frame belongs to another phase or time',
  );
  assert.equal(
    format.encoderSessions[1].encoderSessionID,
    phase.encoderSessionID,
    'Native phase encoder differs',
  );

  const resets = events
    .map((e, i) => ({ e, i }))
    .filter(({ e }) => e.kind === 'applied' && e.action?.kind === 'reset');
  assert.equal(resets.length, 1, 'Stall requires exactly one reset application');
  const { e: reset, i: resetEventIndex } = resets[0],
    application = reset.application;
  assert.equal(resetEventIndex, triggerEventIndex + 1, 'Reset is not the immediate causal action');
  same(
    reset.action,
    {
      kind: 'reset',
      profileID: '240p30',
      bitRate: 350000,
      fromRevision: '1',
      candidateID: null,
      validUntil:
        trigger.kind === 'deliveryFailure'
          ? Math.min(decision.end + 2, decision.observedAtLowerBound + 0.25)
          : decision.observedAtLowerBound + 0.25,
    },
    'Reset action differs from stall authority',
  );
  if (trigger.kind === 'deliveryFailure')
    same(trigger.action, reset.action, 'Applied action differs from deadline recommendation');
  assert(
    application?.windowSequence === decision.sequence &&
      application.fromRevision === '1' &&
      application.candidateID === null &&
      application.attemptID === scope.publishingAttemptID &&
      typeof application.id === 'string' &&
      application.id.length > 0,
    'Reset application differs from exact stall sequence',
  );
  assert(
    finite(application.admittedAt) &&
      application.admittedAt >= trigger.evaluatedAt &&
      application.admittedAt <= reset.action.validUntil &&
      application.completionDeadline === application.admittedAt + 2 &&
      finite(reset.acknowledgedAt) &&
      reset.acknowledgedAt >= application.admittedAt &&
      reset.acknowledgedAt <= application.completionDeadline,
    'Reset admission or completion outside causal deadline',
  );
  assert(
    reset.revision === '2' &&
      reset.profileID === '240p30' &&
      reset.receipt.bitRate === 350000 &&
      reset.closed === false,
    'Reset did not apply minimum revision 2',
  );
  return {
    ...signal,
    triggerKind: trigger.kind,
    stalledCadenceReportIndex: signal.stalledCadenceReportIndex ?? signal.triggerCadenceReportIndex,
    faultQualified: true,
    recoveryQualified: false,
    productionUpgradeAuthorized: false,
    triggerEventIndex,
    resetEventIndex,
    triggerEvaluatedAt: trigger.evaluatedAt,
    resetApplicationID: application.id,
    resetAcknowledgedAt: reset.acknowledgedAt,
    prePauseSourceFrame: frame,
    prePauseSourceIntervalSequence: interval.sequence,
  };
}
