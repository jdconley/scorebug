import { qualifyRecoveryDeliveryBucket } from './recovery-delivery-bucket.mjs';
import { qualifyRepeatedRecoveryInvalidations } from './repeated-recovery-invalidation.mjs';
import { qualifyCadenceAuditEnvelope } from './cadence-audit-envelope.mjs';
import assert from 'node:assert/strict';
import { replayNativePressure } from './native-quality-pressure.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';
import { qualifyMeasuredCadenceContinuity } from './measured-trial-policy.mjs';
import { qualifyNativeDeliveryDeadlines } from './native-delivery-deadlines.mjs';
import { qualifyMeasuredDeliveryOwnership } from './measured-native-trial.mjs';
import { qualifyRepeatedMeasuredRecoveryFaults } from './repeated-measured-recovery-fault.mjs';
const finite = (n) => Number.isFinite(n) && n >= 0;
const id = (n) => {
  assert(typeof n === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(n));
  return n.toLowerCase();
};
const seq = (n) => {
  assert(typeof n === 'string' && /^[1-9][0-9]*$/.test(n) && Number.isSafeInteger(Number(n)));
  return Number(n);
};
const owner = (s) => [s.workerID, s.workerEpoch, s.workerAttempt, s.readerID, s.processingScopeID];
function owned(row, current) {
  for (const key of [
    'revision',
    'profileID',
    'receipt',
    'acknowledgedAt',
    'application',
    'profileReceipt',
  ])
    assert.deepEqual(row[key], current[key], `Policy configuration changed: ${key}`);
}
function receipt(r) {
  id(r.configurationID);
  id(r.encoderSessionID);
  seq(r.generation);
  assert(finite(r.acceptedAt));
  fixtureFrameID(r.lastSubmittedPTS);
}
/** Complete two-cycle component replay over the unchanged global quality and
 * audit histories. Source/media/lifecycle/admission results are independent
 * structured dependencies; this gate replays policy, raw pressure, delivery,
 * cadence and owned faults, and grants no production permission. */
export function qualifyRepeatedMeasuredPolicy(input) {
  const {
    quality,
    snapshot,
    cadenceReports,
    sourceIntervalQualification: sources,
    profileQualification: profile,
    lifecycleQualification: lifecycle,
    candidateWitnessQualifications: witnesses,
    deliveryAudit,
  } = input;
  assert.equal(quality.formatVersion, 4);
  for (const key of [
    'measuredSourceEvaluationEnabled',
    'decoderStallEnabled',
    'deadlineFailuresEnabled',
  ])
    assert.equal(quality[key], true);
  assert.equal(quality.overflow, false);
  const events = quality.events;
  assert(Array.isArray(events) && events.length >= 16 && events.length <= 512);
  for (const proof of [sources, profile, lifecycle]) assert.deepEqual(proof?.scope, snapshot.scope);
  assert.equal(profile.phases?.length, 5);
  assert.equal(profile.receipts?.length, 4);
  assert.equal(lifecycle.applications?.length, 4);
  assert(Array.isArray(sources.intervals) && sources.intervals.length <= 512);
  assert(Array.isArray(snapshot.sourceIntervals) && snapshot.sourceIntervals.length <= 512);
  assert(Array.isArray(witnesses) && witnesses.length === 2);
  qualifyCadenceAuditEnvelope(cadenceReports, { cadenceAuditMode: 'repeated' });
  const reports = cadenceReports.rows;
  const invalidations = qualifyRepeatedRecoveryInvalidations({
    quality,
    cadenceReports,
    scope: snapshot.scope,
    snapshot,
    sourceIntervalQualification: sources,
  });
  const invalidationByIndex = new Map(invalidations.map((value) => [value.eventIndex, value]));
  const boot = events[0],
    stop = events.at(-1);
  assert.equal(boot.kind, 'bootstrap');
  assert.equal(stop.kind, 'stopped');
  assert.equal(boot.revision, '0');
  assert.equal(boot.profileID, '240p30');
  assert.equal(boot.receipt.bitRate, 350000);
  receipt(boot.receipt);
  assert(
    finite(boot.at) &&
      boot.receipt.acceptedAt <= boot.acknowledgedAt &&
      boot.acknowledgedAt <= boot.at,
  );
  assert.deepEqual(lifecycle.bootstrap, boot);
  assert.equal(profile.phases[0].encoderSessionID, boot.receipt.encoderSessionID);
  assert.equal(profile.phases[0].width, 426);
  assert.equal(profile.phases[0].height, 240);
  const bootFrame = fixtureFrameID(boot.receipt.lastSubmittedPTS);
  assert(bootFrame >= profile.phases[0].firstFrame && bootFrame <= profile.phases[0].lastFrame);
  const applications = events.filter((e) => e.kind === 'applied'),
    candidates = events.filter((e) => e.kind === 'candidate');
  assert.equal(applications.length, 4);
  assert.equal(candidates.length, 2);
  for (let i = 0; i < 2; i++) {
    const candidate = candidates[i],
      c = candidate.candidate,
      witness = candidate.candidateAdmission,
      qualification = witnesses[i];
    assert(c && witness && qualification);
    assert.equal(qualification.campaign, String(i + 1));
    assert.equal(qualification.appliedRevision, String(i * 2));
    assert.equal(id(qualification.candidateID ?? witness.measurement.id), id(c.id));
    owned(candidate, applications[i * 2]);
    assert.deepEqual(candidate.action, applications[i * 2].action);
    assert.equal(candidate.state, 'healthy');
    assert.deepEqual(candidate.reasons, ['trialRecommended']);
    for (const key of [
      'evaluatedAt',
      'validUntil',
      'candidateTransportBitsPerSecond',
      'deliveredPaddingBitsPerSecond',
    ]) {
      assert.equal(qualification[key], witness[key]);
      assert.equal(c[key], witness[key]);
    }
    assert.equal(id(c.id), id(witness.measurement.id));
    assert.equal(c.measuredStart, witness.measurement.startedAt);
    assert.equal(c.measuredEnd, witness.measurement.endedAt);
    assert.equal(c.appliedRevision, String(i * 2));
    assert.equal(c.baselineProfileID, '240p30');
    assert.equal(c.baselineVideoBitrate, 350000);
    assert.equal(c.profileID, '360p30');
    assert.equal(c.videoBitrate, 600000);
    assert.equal(id(c.attemptID), id(snapshot.scope.publishingAttemptID));
    assert(finite(c.candidateTransportBitsPerSecond) && finite(c.deliveredPaddingBitsPerSecond));
    assert(
      c.candidateTransportBitsPerSecond > 0 &&
        c.deliveredPaddingBitsPerSecond >= 1.25 * c.candidateTransportBitsPerSecond,
    );
    assert(
      [c.measuredStart, c.measuredEnd, c.evaluatedAt, c.validUntil, candidate.evaluatedAt].every(
        finite,
      ),
    );
    assert(c.measuredEnd > c.measuredStart && c.measuredEnd - c.measuredStart <= 7);
    assert(
      c.measuredEnd <= c.evaluatedAt &&
        c.evaluatedAt <= candidate.evaluatedAt &&
        candidate.evaluatedAt <= c.validUntil,
    );
    assert(
      c.validUntil > c.evaluatedAt &&
        c.validUntil <= Math.min(c.measuredEnd + 2, c.evaluatedAt + 1.5),
    );
  }
  let current = boot,
    lastAt = boot.at,
    evaluatorTime = boot.acknowledgedAt,
    lastSource,
    consumedSources = 0,
    lastPolicy = 0,
    lastEnd,
    identity,
    baseline,
    healthySince,
    trial,
    transitionPending = false,
    appliedCount = 0,
    candidateCount = 0,
    pendingTrigger;
  const confirmations = [],
    recoveries = [],
    healthHistory = [],
    evaluated = [];
  const sourceFor = (row) => {
    const s = row.source;
    assert(s);
    assert.equal(id(s.attemptID), id(snapshot.scope.publishingAttemptID));
    identity ??= owner(s);
    assert.deepEqual(owner(s), identity, 'Source owner changed');
    const previous = seq(s.previousSequence);
    assert.equal(seq(s.sequence), previous + 1, 'Missing or reused source interval');
    if (lastSource !== undefined) assert.equal(previous, lastSource);
    lastSource = Number(s.sequence);
    consumedSources++;
    const matches = snapshot.sourceIntervals.filter(
      (x) =>
        x.sequence === s.sequence &&
        x.workerEpoch === s.workerEpoch &&
        x.workerAttempt === s.workerAttempt,
    );
    const proofs = sources.intervals.filter((x) => x.sequence === Number(s.sequence));
    assert.equal(matches.length, 1);
    assert.equal(proofs.length, 1);
    const source = matches[0],
      proof = proofs[0];
    assert.equal(
      source,
      snapshot.sourceIntervals[consumedSources - 1],
      'Consumed source is not the original array prefix',
    );
    assert.equal(
      proof,
      sources.intervals[consumedSources - 1],
      'Consumed proof is not the original array prefix',
    );
    assert.equal(source.previousSequence, s.previousSequence);
    assert.equal(proof.previousSequence, Number(s.previousSequence));
    assert.deepEqual(source.scope, snapshot.scope);
    assert.equal(source.workerId, s.workerID);
    assert.equal(source.publication.readerId, s.readerID);
    assert.equal(source.processing?.scopeID, s.processingScopeID);
    assert.equal(id(source.publication.publishingAttemptId), id(s.attemptID));
    assert.equal(s.start, source.captureBoundaryStartTime);
    assert.equal(s.end, source.captureBoundaryEndTime);
    if (lastEnd !== undefined) assert.equal(s.start, lastEnd, 'Missing source time coverage');
    return { source, proof };
  };
  for (let eventIndex = 1; eventIndex < events.length; eventIndex++) {
    const row = events[eventIndex];
    assert(finite(row.at) && row.at >= lastAt, 'Event clock reversal');
    lastAt = row.at;
    assert(
      [
        'applied',
        'candidate',
        'evaluated',
        'transition',
        'decoderStall',
        'deliveryFailure',
        'stopped',
      ].includes(row.kind) || invalidationByIndex.has(eventIndex),
    );
    if (pendingTrigger) assert.equal(row.kind, 'applied', 'Reset must immediately follow trigger');
    if (row.kind === 'applied') {
      assert.equal(row.closed, false);
      const index = appliedCount++,
        isTrial = index % 2 === 0,
        a = row.action,
        app = row.application;
      assert(index < 4);
      assert.equal(row.revision, String(index + 1));
      assert.equal(a.fromRevision, current.revision);
      assert.equal(app.fromRevision, current.revision);
      assert.equal(a.kind, isTrial ? 'trial' : 'reset');
      assert.equal(row.profileID, isTrial ? '360p30' : '240p30');
      assert.equal(a.profileID, row.profileID);
      assert.equal(a.bitRate, isTrial ? 600000 : 350000);
      assert.equal(row.receipt.bitRate, a.bitRate);
      assert.equal(app.windowSequence, String(lastPolicy));
      assert.equal(id(app.attemptID), id(snapshot.scope.publishingAttemptID));
      id(app.id);
      if (isTrial) {
        const cRow = candidates[index / 2],
          c = cRow.candidate;
        assert(!trial && !pendingTrigger && baseline && healthySince !== undefined);
        assert.equal(id(a.candidateID), id(c.id));
        assert.equal(id(app.candidateID), id(c.id));
        assert(c.measuredStart >= current.acknowledgedAt);
        assert(baseline.window.end - healthySince >= (index === 0 ? 4 : 10));
        assert(cRow.evaluatedAt >= evaluatorTime, 'Candidate evaluator clock reversal');
        assert(cRow.evaluatedAt >= baseline.evaluatedAt);
        assert(
          cRow.evaluatedAt - baseline.window.end <= 2 &&
            cRow.evaluatedAt - baseline.window.observedAt <= 2,
        );
        assert(baseline.window.end > c.measuredStart && baseline.window.start < c.measuredEnd);
        assert.equal(
          a.validUntil,
          Math.min(c.validUntil, baseline.window.end + 2, baseline.window.observedAt + 2),
        );
        assert(app.admittedAt >= cRow.evaluatedAt && app.admittedAt >= baseline.at);
        trial = {
          campaign: String(index / 2 + 1),
          appliedRevision: current.revision,
          trialRevision: row.revision,
          owner: identity,
          deadline: row.acknowledgedAt + 22.5,
          windows: 0,
        };
      } else {
        assert(pendingTrigger && !trial && confirmations.length === (index + 1) / 2);
        assert.equal(a.candidateID, null);
        assert.equal(app.candidateID, null);
        const signal = pendingTrigger.row.decoderStall ?? pendingTrigger.row.deliveryFailure;
        assert.equal(
          a.validUntil,
          pendingTrigger.row.kind === 'decoderStall'
            ? signal.observedAtLowerBound + 0.25
            : Math.min(signal.end + 2, signal.observedAtLowerBound + 0.25),
        );
        assert(app.admittedAt >= pendingTrigger.row.at);
        recoveries.push({
          campaign: String((index + 1) / 2),
          triggerEventIndex: pendingTrigger.eventIndex,
          resetEventIndex: eventIndex,
          resetApplicationID: app.id,
          resetAcknowledgedAt: row.acknowledgedAt,
          healthyWindows: [],
        });
        pendingTrigger = undefined;
      }
      assert(
        finite(app.admittedAt) && app.admittedAt >= evaluatorTime && app.admittedAt <= a.validUntil,
      );
      assert.equal(app.completionDeadline, app.admittedAt + 2);
      receipt(row.receipt);
      assert(
        row.receipt.acceptedAt >= app.admittedAt &&
          row.receipt.acceptedAt <= row.acknowledgedAt &&
          row.acknowledgedAt <= app.completionDeadline &&
          row.acknowledgedAt <= row.at,
      );
      assert.equal(row.receipt.generation, current.receipt.generation);
      assert.notEqual(row.receipt.configurationID, current.receipt.configurationID);
      const phase = profile.phases[index + 1],
        p = row.profileReceipt,
        native = lifecycle.applications[index];
      assert.deepEqual(p, profile.receipts[index]);
      assert.equal(p.previousEncoderSessionID, current.receipt.encoderSessionID);
      assert.equal(p.encoderSessionID, row.receipt.encoderSessionID);
      assert.equal(phase.encoderSessionID, row.receipt.encoderSessionID);
      assert.equal(phase.width, isTrial ? 640 : 426);
      assert.equal(phase.height, isTrial ? 360 : 240);
      assert.equal(p.publishingGeneration, current.receipt.generation);
      assert.equal(p.profile, row.profileID);
      assert(p.acknowledgedAt >= app.admittedAt && p.acknowledgedAt <= row.receipt.acceptedAt);
      assert.equal(fixtureFrameID(p.firstNewSourcePTS), phase.firstFrame);
      const frame = fixtureFrameID(row.receipt.lastSubmittedPTS);
      assert(frame >= phase.firstFrame && frame <= phase.lastFrame);
      assert.equal(native.applicationID, app.id);
      assert.equal(native.candidateID, app.candidateID);
      assert.equal(native.target, row.profileID);
      for (const key of ['application', 'receipt', 'profileReceipt', 'acknowledgedAt'])
        assert.deepEqual(native[key], row[key]);
      assert(
        finite(native.requestedAt) &&
          native.requestedAt >= app.admittedAt &&
          native.requestedAt <= p.acknowledgedAt,
      );
      evaluatorTime = row.acknowledgedAt;
      current = row;
      transitionPending = true;
      baseline = undefined;
      healthySince = undefined;
      continue;
    }
    owned(row, current);
    if (row.kind === 'candidate') {
      assert.equal(row, candidates[candidateCount++]);
      assert.equal(Number(current.revision) % 2, 1);
      continue;
    }
    if (row.kind === 'stopped') {
      assert.equal(eventIndex, events.length - 1);
      assert.equal(row.closed, true);
      continue;
    }
    assert.equal(row.closed, false);
    if (row.kind === 'rejected') {
      const invalidation = invalidationByIndex.get(eventIndex);
      assert(invalidation && ['2', '4'].includes(current.revision));
      assert(!trial && !pendingTrigger && recoveries.at(-1).resetEventIndex < eventIndex);
      assert(invalidation.evaluatedAt >= evaluatorTime, 'Invalidation evaluator clock reversal');
      evaluatorTime = invalidation.evaluatedAt;
      if (invalidation.kind === 'source-expiry') {
        const { source, proof } = sourceFor(row);
        assert.equal(source, snapshot.sourceIntervals[invalidation.sourceIndex]);
        assert.equal(proof, sources.intervals[invalidation.proofIndex]);
        assert.equal(row.source.sequence, invalidation.sourceSequence);
        lastEnd = row.source.end;
      }
      baseline = undefined;
      healthySince = undefined;
      const recovery = recoveries.at(-1);
      recovery.latestInvalidationCaughtAt = Math.max(
        recovery.latestInvalidationCaughtAt ?? 0,
        invalidation.caughtAt,
      );
      recovery.latestInvalidationAvailableAt = Math.max(
        recovery.latestInvalidationAvailableAt ?? 0,
        invalidation.availableAt,
      );
      continue;
    }
    if (['decoderStall', 'deliveryFailure'].includes(row.kind)) {
      assert(
        !trial &&
          Number(current.revision) % 2 === 1 &&
          confirmations.length === (Number(current.revision) + 1) / 2,
      );
      const signal = row.decoderStall ?? row.deliveryFailure;
      assert.equal(seq(signal.sequence), lastPolicy + 1);
      lastPolicy++;
      assert.equal(signal.revision, current.revision);
      assert(
        finite(row.evaluatedAt) &&
          row.evaluatedAt >= confirmations.at(-1).confirmedAt &&
          row.evaluatedAt <= row.at,
      );
      assert(row.evaluatedAt >= evaluatorTime, 'Fault evaluator clock reversal');
      evaluatorTime = row.evaluatedAt;
      pendingTrigger = { row, eventIndex };
      healthySince = undefined;
      continue;
    }
    const { source, proof } = sourceFor(row),
      s = row.source;
    if (row.kind === 'transition') {
      assert(transitionPending, 'Unexpected transition');
      assert(
        s.start < current.acknowledgedAt &&
          s.end >= current.acknowledgedAt &&
          s.end - s.start <= 5.25 &&
          s.end <= row.at,
      );
      assert(!row.reasons?.length);
      transitionPending = false;
      lastEnd = s.end;
      continue;
    }
    assert(!transitionPending, 'Missing configuration transition');
    assert(finite(row.evaluatedAt) && row.evaluatedAt >= evaluatorTime, 'Evaluator clock reversal');
    evaluatorTime = row.evaluatedAt;
    const w = row.window;
    assert(w);
    assert.equal(seq(w.sequence), lastPolicy + 1, 'Missing or reused policy decision');
    lastPolicy++;
    assert.equal(w.revision, current.revision);
    assert.equal(w.start, s.start);
    assert.equal(w.end, s.end);
    const duration = w.end - w.start;
    assert(duration >= 1 && duration <= 5.25 && w.start >= current.acknowledgedAt);
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
    assert.equal(source.publishingGeneration, current.receipt.generation);
    assert.deepEqual(source.encodingConfiguration, {
      id: current.receipt.configurationID,
      encoderSessionID: current.receipt.encoderSessionID,
      bitRate: current.receipt.bitRate,
    });
    for (const [key, name] of [
      ['captured', 'capturedFrames'],
      ['encoded', 'encodedFrames'],
      ['received', 'decodedFrames'],
    ]) {
      assert.equal(w[key], source[name]);
      assert.equal(w[key], proof[name]);
      assert(Number.isSafeInteger(w[key]) && w[key] / duration >= 29.7);
    }
    assert.equal(w.expected, w.captured);
    assert.equal(w.lost, w.captured - w.received);
    assert(w.expected > 0 && w.lost >= 0 && w.lost / w.expected <= 0.01);
    assert.equal(w.capacity, null);
    assert.equal(w.connectivity, 'connected');
    replayNativePressure(row, snapshot, source, { recoveryBudget: true });
    assert(finite(w.queue) && w.queue < 0.5);
    for (const key of ['thermal', 'worker', 'transport']) assert.equal(w[key], 'nominal');
    const report = reports.findLast((r) => r.evaluatedUptime <= row.evaluatedAt);
    assert(report);
    const status = report.response.status,
      observation = status.observation,
      d = observation.decodedVideo?.completed;
    assert.equal(status.workerId, s.workerID);
    assert.equal(status.workerEpoch, s.workerEpoch);
    assert.equal(observation.attempt, s.workerAttempt);
    assert.deepEqual(status.publication, source.publication);
    assert.equal(observation.processing?.scopeID, s.processingScopeID);
    assert.equal(d?.sequence, Number(s.sequence));
    assert.equal(d.firstPTS, Number(source.firstDecodedPTS));
    assert.equal(d.lastPTS, Number(source.lastDecodedPTS));
    assert.equal(d.freshFrames, w.received);
    assert.equal(d.valid, true);
    assert(
      observation.decoderCadence.progress.lastFreshPTS >= d.lastPTS,
      'Cadence precedes completed source',
    );
    const age =
      status.decoderCadenceAgeUpperBoundMs / 1000 +
      report.requestSeconds +
      report.residenceSeconds +
      row.evaluatedAt -
      report.evaluatedUptime;
    assert(finite(age) && age <= 0.25);
    assert.equal(report.observedStall, false);
    assert(
      Array.isArray(row.reasons) &&
        row.reasons.includes('missingCapacity') &&
        row.reasons.every((r) => ['missingCapacity', 'telemetryGap', 'trialConfirmed'].includes(r)),
    );
    // A telemetry gap is allowed only for the first window of a configuration.
    if (row.reasons.includes('telemetryGap')) assert(healthySince === undefined);
    healthySince ??= w.start;
    if (Number(current.revision) % 2 === 0) {
      assert.equal(row.state, 'healthy');
      assert(!row.reasons.includes('trialConfirmed'));
      baseline = row;
      healthHistory.push({
        eventIndex,
        revision: current.revision,
        healthSequence: w.sequence,
        healthySince,
        healthyThrough: w.end,
      });
      if (current.revision !== '0')
        recoveries.at(-1).healthyWindows.push({
          eventIndex,
          policySequence: w.sequence,
          sourceSequence: s.sequence,
          start: w.start,
          end: w.end,
          evaluatedAt: row.evaluatedAt,
        });
    } else if (trial) {
      assert(row.evaluatedAt < trial.deadline);
      assert.deepEqual(owner(s), trial.owner);
      assert(trial.start !== undefined || w.start <= current.acknowledgedAt + 5.25);
      if (trial.end !== undefined) assert.equal(w.start, trial.end);
      trial.start ??= w.start;
      trial.end = w.end;
      trial.windows++;
      const complete = trial.end - trial.start >= 10;
      assert.equal(row.state, complete ? 'unknown' : 'probing');
      assert.equal(
        row.reasons.includes('trialConfirmed'),
        complete,
        'Confirmation disagrees with probation',
      );
      if (complete) {
        confirmations.push({
          campaign: trial.campaign,
          appliedRevision: trial.appliedRevision,
          trialRevision: trial.trialRevision,
          proofExtent: 'confirmed-prefix',
          confirmed: 1,
          confirmedEventIndex: eventIndex,
          confirmedAt: row.evaluatedAt,
          confirmedEventAt: row.at,
          nextEventIndex: eventIndex + 1,
          rawEventCount: events.length,
          probation: {
            start: trial.start,
            end: trial.end,
            coverageSeconds: trial.end - trial.start,
            windows: trial.windows,
            confirmedAt: row.evaluatedAt,
            deadline: trial.deadline,
          },
        });
        trial = undefined;
      }
    } else {
      assert.equal(row.state, 'healthy');
      assert(!row.reasons.includes('trialConfirmed'), 'Duplicate confirmation');
    }
    lastEnd = w.end;
    evaluated.push(row);
  }
  assert.equal(appliedCount, 4);
  assert.equal(candidateCount, 2);
  assert.equal(confirmations.length, 2);
  assert.equal(recoveries.length, 2);
  assert(!trial && !pendingTrigger && !transitionPending);
  // Native export may append source intervals after quality stops consuming.
  // Every consumed event must have matched the original array prefix above.
  // Join the remaining independently qualified source suffix without turning
  // exported observations into policy decisions or healthy-duration credit.
  assert.equal(
    snapshot.sourceIntervals.length,
    sources.intervals.length,
    'Source/proof suffix length mismatch',
  );
  for (let index = 0; index < snapshot.sourceIntervals.length; index++) {
    const source = snapshot.sourceIntervals[index],
      proof = sources.intervals[index];
    const previous = seq(source.previousSequence),
      sequence = seq(source.sequence);
    assert.equal(sequence, previous + 1);
    assert.equal(proof.sequence, sequence);
    assert.equal(proof.previousSequence, previous);
    assert.deepEqual(source.scope, snapshot.scope);
    assert.equal(proof.sourceStartExclusive, fixtureFrameID(source.sourceStartExclusive));
    assert.equal(proof.sourceEndInclusive, fixtureFrameID(source.sourceEndInclusive));
    for (const key of [
      'capturedFrames',
      'encodedFrames',
      'decodedFrames',
      'captureNotEncodedFrames',
      'encodedNotDecodedFrames',
      'leadingMissingEncodedFrames',
    ]) {
      assert(Number.isSafeInteger(source[key]) && source[key] >= 0);
      assert.equal(proof[key], source[key]);
    }
    assert(
      finite(source.captureBoundaryStartTime) &&
        finite(source.captureBoundaryEndTime) &&
        source.captureBoundaryEndTime >= source.captureBoundaryStartTime,
    );
    if (index > 0) {
      const prior = snapshot.sourceIntervals[index - 1];
      assert.equal(previous, Number(prior.sequence), 'Source export sequence gap');
      assert.equal(
        proof.sourceStartExclusive,
        sources.intervals[index - 1].sourceEndInclusive,
        'Source export frame gap',
      );
      assert.equal(
        source.captureBoundaryStartTime,
        prior.captureBoundaryEndTime,
        'Source export time gap',
      );
      for (const key of ['workerId', 'workerEpoch', 'workerAttempt', 'publication'])
        assert.deepEqual(source[key], prior[key], 'Source export ownership changed');
    }
  }
  const faults = qualifyRepeatedMeasuredRecoveryFaults({
    ...input,
    scope: snapshot.scope,
    confirmations,
  });
  const delivery = qualifyNativeDeliveryDeadlines({
    audit: deliveryAudit,
    reports: cadenceReports,
    cadenceAuditMode: 'repeated',
    deliveryAuditMode: 'repeated',
    scope: snapshot.scope,
    expectedLatencyBudget: 1.5,
  });
  qualifyMeasuredDeliveryOwnership(input, { profile, nativeLifecycle: lifecycle, delivery });
  const cadenceCheckedThrough = reports.at(-1).evaluatedUptime;
  assert(cadenceCheckedThrough >= evaluated.at(-1).evaluatedAt && cadenceCheckedThrough <= stop.at);
  for (const row of deliveryAudit.rows) assert(row.evaluatedAt <= cadenceCheckedThrough);
  for (let i = 0; i < 2; i++) {
    const recovery = recoveries[i],
      fault = faults.campaigns[i],
      reset = events[recovery.resetEventIndex],
      revision = String(i * 2 + 2);
    assert.equal(fault.triggerEventIndex, recovery.triggerEventIndex);
    assert.equal(fault.resetEventIndex, recovery.resetEventIndex);
    const resumedAt = reports[fault.resumedCadenceReportIndex].evaluatedUptime;
    const lanes = [1, 2].map((duration) => {
      const rows = deliveryAudit.rows.filter(
        (r) => r.appliedRevision === revision && r.end - r.start === duration,
      );
      assert(rows.length > 0, 'Missing recovery delivery lane');
      let end = rows[0].start;
      for (const row of rows) {
        assert.equal(row.start, end, 'Recovery delivery lane gap');
        end = row.end;
        assert.equal(row.reason, null);
        for (const key of ['uncertainFrames', 'lateFrames', 'missingFrames'])
          assert.equal(row.result[key], 0);
        qualifyRecoveryDeliveryBucket(row.result, duration);
      }
      return { duration, start: rows[0].start, end, rowCount: rows.length };
    });
    const creditAfter = Math.max(
      resumedAt,
      recovery.latestInvalidationCaughtAt ?? resumedAt,
      recovery.latestInvalidationAvailableAt ?? resumedAt,
    );
    const eligible = recovery.healthyWindows.filter(
      (w) => w.start >= creditAfter && lanes.every((l) => w.start >= l.start && w.end <= l.end),
    );
    assert(eligible.length, 'No whole recovered source windows');
    const credited = [];
    let end = eligible[0].start;
    for (const w of eligible) {
      assert.equal(w.start, end);
      credited.push(w);
      end = w.end;
      if (end - eligible[0].start >= 10) break;
    }
    assert(end - eligible[0].start >= 10, 'Insufficient shared recovery coverage');
    const deliveryRows = deliveryAudit.rows.filter(
      (r) =>
        r.appliedRevision === revision &&
        [1, 2].includes(r.end - r.start) &&
        r.start < end &&
        r.end > eligible[0].start,
    );
    const qualifiedAt = Math.max(
      ...credited.map((w) => w.evaluatedAt),
      ...deliveryRows.map((r) => r.evaluatedAt),
    );
    Object.assign(recovery, {
      resumedAt,
      deliveryLanes: lanes,
      cadenceCheckedThrough,
      sharedCoverage: {
        start: eligible[0].start,
        end,
        qualifiedAt,
        coverageSeconds: end - eligible[0].start,
        windowCount: credited.length,
        policyWindowSequences: credited.map((w) => w.policySequence),
        sourceWindowSequences: credited.map((w) => w.sourceSequence),
      },
      recoveryPolicyQualified: true,
      productionUpgradeAuthorized: false,
    });
    if (i === 0)
      assert(
        qualifiedAt <= applications[2].application.admittedAt,
        'Second trial precedes recovery',
      );
    assert(reset.acknowledgedAt < recovery.sharedCoverage.start);
  }
  // Partition validation at original resumed observations, retaining the entire
  // raw report array. Cross-partition identity and progress remain global.
  let lastPTS = -1,
    lastFreshBounds,
    publication,
    decoderScope;
  for (const r of reports) {
    if (r.evaluatedUptime < evaluated[0].window.start) continue;
    const status = r.response.status,
      cadence = status.observation.decoderCadence;
    publication ??= status.publication;
    decoderScope ??= cadence.scopeID;
    assert.deepEqual(status.publication, publication);
    assert.equal(cadence.scopeID, decoderScope);
    const progress = cadence.progress;
    assert(progress.lastFreshPTS >= lastPTS, 'Global decoder progress regressed');
    assert(finite(progress.ageMs) && finite(r.sampleAgeSeconds));
    // DecoderCadenceTracker snapshots retain the age of the last strictly newer
    // PTS. The native report supplies an upper bound on snapshot age, not an
    // exact worker/native clock offset. Intersect feasible last-arrival times
    // across repeated PTS, including reports on either side of a segment/stall.
    const upper = r.evaluatedUptime - progress.ageMs / 1000;
    const lower = upper - r.sampleAgeSeconds;
    const rounding = 2 * Number.EPSILON * Math.max(1, Math.abs(upper), Math.abs(lower));
    const next = { lower: lower - rounding, upper: upper + rounding };
    if (lastFreshBounds) {
      next.lower = Math.max(next.lower, lastFreshBounds.lower);
      if (progress.lastFreshPTS === lastPTS)
        next.upper = Math.min(next.upper, lastFreshBounds.upper);
    }
    assert(next.lower <= next.upper, 'Inconsistent global decoder last-fresh time');
    lastFreshBounds = next;
    lastPTS = progress.lastFreshPTS;
  }
  let start = evaluated[0].window.start;
  for (let i = 0; i < 2; i++) {
    const fault = faults.campaigns[i],
      trigger = events[fault.triggerEventIndex];
    let first = fault.stalledCadenceReportIndex ?? fault.triggerCadenceReportIndex;
    while (
      first > 0 &&
      reports[first - 1].observedStall &&
      reports[first - 1].response.status.observation.decoderCadence.progress.lastFreshPTS ===
        Number(fault.lastStalledPTS)
    )
      first--;
    const allowedStart = reports[first].evaluatedUptime;
    for (
      let j = first;
      j <= (fault.stalledCadenceReportIndex ?? fault.triggerCadenceReportIndex);
      j++
    ) {
      const r = reports[j],
        status = r.response.status,
        p = status.observation.decoderCadence.progress;
      assert(r.evaluatedUptime >= confirmations[i].confirmedAt);
      assert(p.ageMs / 1000 + r.sampleAgeSeconds + trigger.evaluatedAt - r.evaluatedUptime <= 1.5);
      const ttl = Math.max(
        0,
        Math.min(5, (Date.parse(status.expiresAt) - Date.parse(r.response.serverTime)) / 1000),
      );
      assert(r.evaluatedUptime < r.receivedUptime + ttl - r.requestSeconds);
    }
    const end = recoveries[i].resumedAt;
    qualifyMeasuredCadenceContinuity({
      reports,
      cadenceAuditMode: 'repeated',
      recoveryInvalidations: invalidations.filter((value) => value.kind !== 'source-expiry'),
      start,
      end,
      source: evaluated[0].source,
      scope: snapshot.scope,
      allowedStall: { start: allowedStart, end, lastFreshPTS: Number(fault.lastStalledPTS) },
    });
    recoveries[i].cadenceAllowedStallStart = allowedStart;
    start = end;
  }
  qualifyMeasuredCadenceContinuity({
    reports,
    cadenceAuditMode: 'repeated',
    recoveryInvalidations: invalidations.filter((value) => value.kind !== 'source-expiry'),
    start,
    end: cadenceCheckedThrough,
    source: evaluated[0].source,
    scope: snapshot.scope,
  });
  return {
    scope: structuredClone(snapshot.scope),
    rawEventCount: events.length,
    invalidations,
    confirmations,
    faults,
    recoveries,
    healthHistory,
    evaluated: evaluated.length,
    delivery,
    repeatedPolicyQualified: true,
    recoveryQualified: true,
    upgradeAuthorized: false,
    productionUpgradeAuthorized: false,
    description:
      'Two complete measured policy cycles; independent source, native media, lifecycle and admission contracts remain required.',
  };
}
