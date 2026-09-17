import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { qualifyNativeDeliveryDeadlines } from './native-delivery-deadlines.mjs';
import { qualifyNativeProfileTransitions } from './native-profile-transitions.mjs';
import { fixtureFrameID } from './video-observation-qualification.mjs';

const finite = (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 1e12;
const same = (a, b, message) => assert.deepEqual(a, b, message);
const uuid = (s) =>
  typeof s === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(s);
function sequence(s) {
  assert(typeof s === 'string' && /^[1-9][0-9]*$/.test(s), 'Noncanonical decision sequence');
  const n = BigInt(s);
  assert(n <= (1n << 64n) - 1n, 'Decision sequence exceeds UInt64');
  return n;
}
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

// The raw verifier has already authenticated every usable receipt. Recompute its
// age bound without feeding exported, rounded ages back through frozen samples.
function expiresAt(row) {
  const ttl = Math.max(
    0,
    Math.min(
      5,
      (Date.parse(row.response.status.expiresAt) - Date.parse(row.response.serverTime)) / 1000,
    ),
  );
  return row.receivedUptime + ttl - row.requestSeconds;
}
function receiptAges(reports) {
  const ages = new Map();
  let previous;
  for (const row of reports.rows) {
    if (row.deliveryReceiptID === null) {
      previous = undefined;
      continue;
    }
    const owner = context(row),
      sample = row.response.status.observation.decoderDelivery.sampledAtMs;
    let age =
      row.response.status.decoderDeliveryAgeUpperBoundMs / 1000 +
      row.requestSeconds +
      row.residenceSeconds;
    if (previous && sample === previous.sample && isDeepStrictEqual(owner, previous.owner))
      age = Math.max(age, previous.age + row.evaluatedUptime - previous.at);
    ages.set(row.deliveryReceiptID, { age, at: row.evaluatedUptime, expiresAt: expiresAt(row) });
    previous = { sample, owner, age, at: row.evaluatedUptime };
  }
  return ages;
}
function qualityReceipt(row) {
  const r = row.receipt;
  return {
    generation: r.generation,
    configurationID: r.configuration.id,
    encoderSessionID: r.configuration.encoderSessionID,
    bitRate: r.configuration.bitRate,
    acceptedAt: r.acceptedAt,
    lastSubmittedPTS: r.lastSubmittedPTS,
  };
}
function normalizeReceipt(receipt) {
  assert(
    receipt && uuid(receipt.configurationID) && uuid(receipt.encoderSessionID),
    'Invalid quality receipt',
  );
  return {
    ...receipt,
    configurationID: receipt.configurationID.toLowerCase(),
    encoderSessionID: receipt.encoderSessionID.toLowerCase(),
  };
}
function ownedPause(fault) {
  assert(
    fault?.closed === true &&
      fault.failed === false &&
      finite(fault.pauseSentAt) &&
      finite(fault.resumeSentAt),
    'Invalid owned fault',
  );
  const duration = fault.resumeSentAt - fault.pauseSentAt;
  assert(duration >= 1800 && duration <= 2500, 'Unexpected owned pause duration');
  const { worker, guardian, decoder } = fault.identity ?? {};
  assert(
    [worker, guardian, decoder].every((p) => Number.isSafeInteger(p?.pid) && p.pid > 0),
    'Invalid fault process identity',
  );
  assert(
    new Set([worker.pid, guardian.pid, decoder.pid]).size === 3 &&
      guardian.ppid === worker.pid &&
      decoder.ppid === guardian.pid,
    'Fault does not own decoder parentage',
  );
  return duration;
}
function cadence(row) {
  if (row.sampleAgeSeconds === null) {
    assert.equal(row.observedStall, null, 'Stall without cadence freshness');
    return null;
  }
  const status = row.response.status,
    c = status.observation?.decoderCadence;
  assert(
    c?.formatVersion === 1 &&
      uuid(c.scopeID) &&
      c.invalidReason === null &&
      c.ended === false &&
      Number.isSafeInteger(c.progress?.lastFreshPTS) &&
      c.progress.lastFreshPTS >= 0 &&
      finite(c.progress.ageMs),
    'Invalid cadence evidence',
  );
  assert.equal(c.progress.stalled, c.progress.ageMs >= 1000, 'Cadence stall does not reconcile');
  assert(
    Number.isSafeInteger(status.decoderCadenceAgeUpperBoundMs) &&
      status.decoderCadenceAgeUpperBoundMs >= 0,
    'Missing cadence server bound',
  );
  const expected =
    status.decoderCadenceAgeUpperBoundMs / 1000 + row.requestSeconds + row.residenceSeconds;
  assert(
    finite(row.sampleAgeSeconds) && Math.abs(row.sampleAgeSeconds - expected) < 1e-8,
    'Cadence age does not reconcile',
  );
  assert.equal(
    row.observedStall,
    expected <= 0.25 ? c.progress.stalled : null,
    'Cadence observed stall does not reconcile',
  );
  assert(row.evaluatedUptime < expiresAt(row), 'Cadence status expired');
  return expected <= 0.25 ? c : null;
}
function associatedPause(row, reports, sampleAge) {
  const arrivals = new Map();
  for (const a of row.timeline.arrivals)
    if (!arrivals.has(String(a.pts))) arrivals.set(String(a.pts), a.ageMs / 1000);
  const failed = row.frames.filter((f) => {
    const age = arrivals.get(f.pts);
    return age === undefined || row.evaluatedAt - age - sampleAge > f.capturedAt + 1.5;
  });
  for (const report of reports.rows) {
    const c = cadence(report);
    if (
      !c ||
      report.observedStall !== true ||
      c.progress.stalled !== true ||
      c.progress.ageMs < 1000 ||
      report.evaluatedUptime > row.evaluatedAt ||
      !isDeepStrictEqual(context(report), row.context)
    )
      continue;
    const lastPTS = BigInt(c.progress.lastFreshPTS),
      observed = report.evaluatedUptime - report.sampleAgeSeconds;
    // PTS is already unwrapped in both native projections and worker cadence.
    // A nearby failed source after the stalled anchor binds the failure window;
    // never subtract Node fault timestamps from phone-local observations.
    if (
      !failed.some(
        (f) =>
          BigInt(f.pts) > lastPTS && BigInt(f.pts) - lastPTS < 180000n && f.capturedAt <= observed,
      )
    )
      continue;
    const resumed = reports.rows.find((r) => {
      const next = cadence(r);
      return (
        next &&
        r.evaluatedUptime > report.evaluatedUptime &&
        r.observedStall === false &&
        next.progress.stalled === false &&
        next.scopeID === c.scopeID &&
        next.progress.lastFreshPTS > c.progress.lastFreshPTS &&
        isDeepStrictEqual(context(r), row.context)
      );
    });
    if (resumed)
      return {
        decoderScopeID: c.scopeID,
        lastStalledPTS: String(c.progress.lastFreshPTS),
        stalledReportAt: report.evaluatedUptime,
        resumedReportAt: resumed.evaluatedUptime,
      };
  }
  return null;
}

function qualifiedFailure(event, audit, reports, ages) {
  const d = event.deliveryFailure;
  assert(
    d && d.sequence !== undefined && event.window === undefined && event.decoderStall === undefined,
    'Failure has fictitious window credit',
  );
  assert(
    finite(d.classifiedAt) && finite(event.evaluatedAt) && event.evaluatedAt >= d.classifiedAt,
    'Decision predates classification',
  );
  const matches = audit.rows.filter(
    (r) =>
      r.result !== null &&
      r.evaluatedAt === d.classifiedAt &&
      r.deliveryReceiptID === d.deliveryReceiptID &&
      isDeepStrictEqual(r.context, d.context) &&
      r.timeline.scopeID === d.scopeID &&
      r.appliedRevision === d.revision &&
      r.start === d.start &&
      r.end === d.end,
  );
  assert.equal(matches.length, 1, 'Decision lacks exact independently qualified deadline row');
  const row = matches[0];
  // Admission authority is retired by any intervening unavailable or replaced
  // owner/scope, even if a later report restores the original identity.
  for (const intervening of reports.rows.filter(
    (r) => r.evaluatedUptime > d.classifiedAt && r.evaluatedUptime <= event.evaluatedAt,
  )) {
    assert(
      intervening.deliveryReceiptID !== null &&
        isDeepStrictEqual(context(intervening), row.context) &&
        intervening.response.status.observation?.decoderDelivery?.scopeID === d.scopeID,
      'Deadline classification authority retired before decision',
    );
  }
  assert(
    uuid(d.publishingAttemptID) && d.publishingAttemptID.toLowerCase() === row.attemptID,
    'Wrong signal publication attempt',
  );
  same(
    normalizeReceipt(event.receipt),
    qualityReceipt(row),
    'Quality receipt differs from native deadline receipt',
  );
  assert(
    row.profileID === event.profileID &&
      row.videoBitrate === event.receipt.bitRate &&
      d.revision === event.revision &&
      row.acknowledgedAt === event.acknowledgedAt &&
      row.start >= event.acknowledgedAt,
    'Failure crosses applied truth',
  );
  if (row.classifiedAt !== undefined)
    assert.equal(row.classifiedAt, d.classifiedAt, 'Audit classification mismatch');
  for (const key of ['expectedFrames', 'onTimeFrames', 'lateFrames', 'missingFrames'])
    same(d[key], row.result[key], `Failure ${key} mismatch`);
  assert.equal(row.result.uncertainFrames, 0, 'Uncertain deadline cannot trigger');
  const proof = ages.get(row.deliveryReceiptID),
    ageAtClassification = Math.max(row.sampleAgeSeconds, proof.age + row.evaluatedAt - proof.at);
  assert(
    finite(d.observedAtLowerBound) &&
      Math.abs(d.observedAtLowerBound - (row.evaluatedAt - row.sampleAgeSeconds)) <= 1e-9,
    'Failure observation bound mismatch',
  );
  if (row.observedAtLowerBound !== undefined)
    assert.equal(d.observedAtLowerBound, row.observedAtLowerBound, 'Audit observation mismatch');
  assert(
    d.end <= d.observedAtLowerBound &&
      event.evaluatedAt - d.end <= 2 &&
      event.evaluatedAt - d.observedAtLowerBound <= 0.25 &&
      ageAtClassification + event.evaluatedAt - d.classifiedAt <= 0.25 &&
      event.evaluatedAt < proof.expiresAt,
    'Stale or expired failure at decision',
  );
  const duration = d.end - d.start;
  assert(
    duration === 1
      ? d.onTimeFrames < 24
      : (d.lateFrames + d.missingFrames) / d.expectedFrames > 0.05,
    'Deadline threshold is not strictly crossed',
  );
  return { row, ageAtClassification, duration };
}

/** Qualifies only the isolated, fixed-minimum deadline driver. Scalar synthetic
 * fixtures test the verifier; only actual exported artifacts qualify a native run.
 * Resumed decoder progress proves fixture cleanup, never automatic recovery. */
export function qualifyNativeDeadlineDecisions({ quality, audit, reports, fault, scope }) {
  const deadlineEvidence = qualifyNativeDeliveryDeadlines({
    audit,
    reports,
    scope,
    expectedLatencyBudget: 1.5,
  });
  assert(
    quality?.formatVersion === 4 &&
      quality.overflow === false &&
      quality.deadlineFailuresEnabled === true &&
      quality.decoderStallEnabled === false &&
      Array.isArray(quality.events) &&
      quality.events.length >= 3 &&
      quality.events.length <= 512,
    'Invalid isolated deadline quality envelope',
  );
  const events = quality.events,
    boot = events.filter((e) => e.kind === 'bootstrap');
  assert(boot.length === 1 && events[0] === boot[0], 'Missing initial bootstrap');
  assert.equal(boot[0].profileID, '240p30');
  assert.equal(boot[0].receipt?.bitRate, 350000);
  assert(finite(boot[0].acknowledgedAt), 'Invalid acknowledgment');
  normalizeReceipt(boot[0].receipt);
  assert(
    events.at(-1).kind === 'stopped' && events.at(-1).closed === true,
    'Missing final closed stop',
  );
  const pauseMilliseconds = ownedPause(fault),
    ages = receiptAges(reports),
    lanes = new Map();
  let lastSequence = 0n,
    lastTime = -1,
    count = 0;
  const associations = [];
  for (const event of events) {
    assert(
      [
        'bootstrap',
        'deliveryFailure',
        'localPressure',
        'evaluated',
        'rejected',
        'transition',
        'stopped',
      ].includes(event.kind),
      'Unknown event, watchdog or application masks minimum deadline hold',
    );
    assert(
      event.state !== 'healthy' && !event.reasons?.includes('recoveryQualified'),
      'Isolated fixture claims fictitious health or recovery',
    );
    assert(
      event === events.at(-1) || (event.kind !== 'stopped' && event.closed !== true),
      'Premature closed event',
    );
    assert(
      event.action === undefined &&
        event.recommendation === undefined &&
        event.application === undefined,
      'Minimum hold carries an action',
    );
    same(event.receipt, boot[0].receipt, 'Minimum hold changed receipt');
    assert(
      event.profileID === '240p30' &&
        event.revision === '0' &&
        event.acknowledgedAt === boot[0].acknowledgedAt,
      'Minimum hold changed applied truth',
    );
    if (event.evaluatedAt !== undefined) {
      assert(finite(event.evaluatedAt) && event.evaluatedAt >= lastTime, 'Decision time reversal');
      lastTime = event.evaluatedAt;
    }
    const scalarSequence = event.deliveryFailure?.sequence ?? event.window?.sequence;
    if (scalarSequence !== undefined) {
      const n = sequence(scalarSequence);
      assert(n > lastSequence, 'Decision sequence is not globally increasing');
      lastSequence = n;
    }
    if (event.kind !== 'deliveryFailure') {
      assert(event.deliveryFailure === undefined, 'Failure attached to wrong event');
      continue;
    }
    const d = event.deliveryFailure;
    const { row, ageAtClassification, duration } = qualifiedFailure(event, audit, reports, ages);
    const reasons = [duration === 1 ? 'freshFrameFloor' : 'sourceLoss'];
    if (d.onTimeFrames === 0) reasons.push('stalled');
    reasons.push('minimumProfileInsufficient');
    same(event.reasons, reasons, 'Wrong minimum deadline reasons');
    assert.equal(
      event.state,
      d.onTimeFrames === 0 ? 'stalled' : 'degraded',
      'Failure claims fictitious health',
    );
    assert(d.start >= (lanes.get(duration) ?? -1), 'Overlapping failure lane');
    lanes.set(duration, d.end);
    const association = associatedPause(row, reports, ageAtClassification);
    if (association) associations.push(association);
    count++;
  }
  assert(count > 0, 'Missing deadline failure decision');
  assert(associations.length > 0, 'No failure window associated with owned decoder pause');
  return {
    minimumHoldDecisionQualified: true,
    deadlineFailureDecisionCount: count,
    ownedFaultAssociationQualified: true,
    pauseMilliseconds,
    faultAssociations: associations,
    higherProfileResetWriteQualified: false,
    automaticAdaptationQualified: false,
    recoveryQualified: false,
    deadlineEvidence,
  };
}

// This bridge compares each clock only to its own domain: Node request bounds
// establish that the worker sample was fetched under SIGSTOP, while the raw
// worker scope/PTS anchor binds it to the phone's independently fresh report.
function qualifyOwnedPauseSample(fault, owner, association) {
  function workerSample(sample) {
    assert(
      sample &&
        finite(sample.requestStartedAt) &&
        finite(sample.receivedAt) &&
        sample.receivedAt >= sample.requestStartedAt,
      'Invalid owned worker sample clock',
    );
    const elapsed = sample.receivedAt - sample.requestStartedAt,
      value = sample.value;
    assert(elapsed <= 250, 'Slow owned pause worker sample');
    same(value?.context, owner, 'Owned pause worker context differs from resetting deadline');
    assert(
      Number.isSafeInteger(value.decoderCadenceAgeUpperBoundMs) &&
        value.decoderCadenceAgeUpperBoundMs >= 0 &&
        value.decoderCadenceAgeUpperBoundMs + elapsed <= 250,
      'Stale owned pause worker sample',
    );
    const ttl = Math.max(
      0,
      Math.min(5000, Date.parse(value.expiresAt) - Date.parse(value.serverTime)),
    );
    assert(Number.isFinite(ttl) && elapsed < ttl, 'Expired owned pause worker sample');
    const c = value.decoderCadence;
    assert(
      c?.formatVersion === 1 &&
        uuid(c.scopeID) &&
        c.invalidReason === null &&
        c.ended === false &&
        Number.isSafeInteger(c.progress?.lastFreshPTS) &&
        c.progress.lastFreshPTS >= 0 &&
        finite(c.progress.ageMs),
      'Invalid owned pause cadence',
    );
    return { c, age: value.decoderCadenceAgeUpperBoundMs + elapsed, elapsed, ttl };
  }
  const before = fault.beforePauseSample,
    sample = fault.pausedSample;
  const pre = workerSample(before),
    paused = workerSample(sample),
    c = paused.c;
  assert(
    before.receivedAt <= fault.pauseSentAt &&
      pre.c.progress.stalled === false &&
      pre.c.progress.ageMs + pre.age + fault.pauseSentAt - before.receivedAt <= 250,
    'Decoder progress not fresh immediately before owned pause',
  );
  assert(
    pre.elapsed + fault.pauseSentAt - before.receivedAt < pre.ttl,
    'Pre-pause worker status expired at pause',
  );
  assert(
    sample.requestStartedAt >= fault.pauseSentAt && sample.receivedAt <= fault.resumeSentAt,
    'Worker sample not bracketed by owned pause',
  );
  assert(
    c.progress.ageMs >= 1000 && c.progress.stalled === true,
    'Invalid owned pause cadence stall',
  );
  assert.equal(pre.c.scopeID, c.scopeID, 'Decoder scope changed during owned pause');
  assert(
    c.progress.lastFreshPTS >= pre.c.progress.lastFreshPTS,
    'Decoder PTS regressed during owned pause',
  );
  assert(
    c.progress.ageMs <= sample.receivedAt - fault.pauseSentAt + 250,
    'Owned pause sample reflects preexisting decoder stall',
  );
  assert.equal(
    c.scopeID,
    association.decoderScopeID,
    'Owned pause scope differs from native stall',
  );
  assert.equal(
    String(c.progress.lastFreshPTS),
    association.lastStalledPTS,
    'Owned pause PTS differs from native stall',
  );
}

/** Qualifies a single observed deadline-caused downward profile write. Healthy
 * raw windows establish the pre-fault baseline, never recovery/controller credit. */
export function qualifyNativeDeadlineReset({
  quality,
  audit,
  reports,
  fault,
  scope,
  format,
  snapshot,
  liveIDs,
}) {
  const deadlineEvidence = qualifyNativeDeliveryDeadlines({
    audit,
    reports,
    scope,
    expectedLatencyBudget: 1.5,
  });
  const transitions = qualifyNativeProfileTransitions(format, snapshot, liveIDs, {
    sequence: 'stall540',
    requireFrameEvidence: true,
  });
  same(scope, snapshot.scope, 'Wrong native transition scope');
  assert(
    quality?.formatVersion === 4 &&
      quality.overflow === false &&
      quality.deadlineFailuresEnabled === true &&
      quality.decoderStallEnabled === false &&
      Array.isArray(quality.events) &&
      quality.events.length >= 4 &&
      quality.events.length <= 512,
    'Invalid isolated deadline quality envelope',
  );
  const events = quality.events,
    boot = events[0],
    writes = events.filter((e) => e.kind === 'applied');
  assert(
    boot.kind === 'bootstrap' && events.filter((e) => e.kind === 'bootstrap').length === 1,
    'Missing initial bootstrap',
  );
  assert.equal(writes.length, 1, 'Exactly one native deadline application required');
  const write = writes[0],
    writeIndex = events.indexOf(write);
  assert(
    events.at(-1).kind === 'stopped' && events.at(-1).closed === true,
    'Missing final closed stop',
  );
  assert.equal(boot.profileID, '540p30');
  assert.equal(boot.receipt?.bitRate, 1500000);
  assert.equal(boot.revision, '0');
  const old = normalizeReceipt(boot.receipt),
    next = normalizeReceipt(write.receipt),
    profile = transitions.receipts[0];
  assert.equal(old.encoderSessionID, format.encoderSessions[0].encoderSessionID.toLowerCase());
  assert.equal(old.generation, format.publishingGeneration);
  assert(
    finite(old.acceptedAt) && old.acceptedAt >= format.phases[0].firstObservedAt,
    'Bootstrap predates native format',
  );
  assert(
    finite(boot.acknowledgedAt) && boot.acknowledgedAt >= old.acceptedAt,
    'Invalid bootstrap acknowledgment',
  );
  assert(
    fixtureFrameID(old.lastSubmittedPTS) >= transitions.phases[0].firstFrame &&
      fixtureFrameID(old.lastSubmittedPTS) <= transitions.phases[0].lastFrame,
    'Bootstrap source outside native phase',
  );
  same(write.profileReceipt, profile, 'Wrong native profile receipt');
  assert.equal(next.encoderSessionID, profile.encoderSessionID.toLowerCase());
  assert.equal(next.generation, old.generation);
  assert.equal(next.bitRate, 350000);
  assert.notEqual(next.configurationID, old.configurationID, 'Reset reused native configuration');
  assert.notEqual(next.encoderSessionID, old.encoderSessionID, 'Reset reused encoder session');
  assert(
    fixtureFrameID(next.lastSubmittedPTS) >= fixtureFrameID(profile.firstNewSourcePTS) &&
      fixtureFrameID(next.lastSubmittedPTS) <= transitions.phases[1].lastFrame,
    'Reset source outside native phase',
  );
  assert(
    finite(next.acceptedAt) && next.acceptedAt >= profile.acknowledgedAt,
    'Configuration receipt predates profile acknowledgment',
  );
  const pauseMilliseconds = ownedPause(fault),
    ages = receiptAges(reports),
    lanes = new Map();
  let lastSequence = 0n,
    lastTime = -1,
    count = 0,
    resetDecision,
    resetRow;
  const associations = [];
  for (const [index, event] of events.entries()) {
    assert(
      ['bootstrap', 'deliveryFailure', 'localPressure', 'rejected', 'applied', 'stopped'].includes(
        event.kind,
      ),
      'Unknown event, watchdog or failed/skipped application',
    );
    assert(event.decoderStall === undefined, 'Watchdog evidence masks deadline reset');
    assert(
      event.state !== 'healthy' && !event.reasons?.includes('recoveryQualified'),
      'Isolated fixture claims fictitious health or recovery',
    );
    assert(
      event === events.at(-1) || (event.kind !== 'stopped' && event.closed !== true),
      'Premature closed event',
    );
    const applied = index >= writeIndex,
      expected = applied ? write : boot;
    same(event.receipt, expected.receipt, 'Unexpected native receipt');
    assert(
      event.profileID === (applied ? '240p30' : '540p30') &&
        event.revision === (applied ? '1' : '0') &&
        event.acknowledgedAt === expected.acknowledgedAt,
      'Event changed applied truth',
    );
    if (applied)
      same(event.profileReceipt, profile, 'Unexpected profile receipt after acknowledgment');
    else assert.equal(event.profileReceipt, undefined, 'Profile receipt before application');
    assert.equal(event.recommendation, undefined, 'Unexpected unbound recommendation');
    if (applied) same(event.application, write.application, 'Changed persisted native application');
    else assert.equal(event.application, undefined, 'Application before native write');
    if (event.evaluatedAt !== undefined) {
      assert(
        finite(event.evaluatedAt) &&
          event.evaluatedAt >= lastTime &&
          event.evaluatedAt >= event.acknowledgedAt,
        'Decision time reversal or decision before acknowledgment',
      );
      assert(
        applied || event.evaluatedAt < write.acknowledgedAt,
        'Old revision decision after acknowledgment',
      );
      lastTime = event.evaluatedAt;
    }
    const scalarSequence = event.deliveryFailure?.sequence ?? event.window?.sequence;
    if (scalarSequence !== undefined) {
      const n = sequence(scalarSequence);
      assert(n > lastSequence, 'Decision sequence is not globally increasing');
      lastSequence = n;
    }
    if (event.window !== undefined)
      assert.equal(event.window.revision, event.revision, 'Old revision controller window');
    if (event.kind !== 'deliveryFailure') {
      assert.equal(event.deliveryFailure, undefined, 'Failure attached to wrong event');
      if (event !== write)
        assert.equal(event.action, undefined, 'Non-failure triggered profile action');
      continue;
    }
    const d = event.deliveryFailure;
    const { row, duration, ageAtClassification } = qualifiedFailure(event, audit, reports, ages);
    const reasons = [duration === 1 ? 'freshFrameFloor' : 'sourceLoss'];
    if (d.onTimeFrames === 0) reasons.push('stalled');
    if (applied) reasons.push('minimumProfileInsufficient');
    same(event.reasons, reasons, 'Wrong deadline reasons');
    assert.equal(
      event.state,
      d.onTimeFrames === 0 ? 'stalled' : 'degraded',
      'Failure claims fictitious health',
    );
    const lane = `${event.revision}:${duration}`;
    assert(d.start >= (lanes.get(lane) ?? -1), 'Overlapping failure lane');
    lanes.set(lane, d.end);
    const association = associatedPause(row, reports, ageAtClassification);
    if (association) associations.push(association);
    if (!applied) {
      assert(!resetDecision, 'Multiple higher-profile reset decisions');
      same(
        event.action,
        {
          kind: 'reset',
          profileID: '240p30',
          bitRate: 350000,
          fromRevision: '0',
          validUntil: Math.min(d.end + 2, d.observedAtLowerBound + 0.25),
        },
        'Wrong deadline reset recommendation or expiry',
      );
      assert(association, 'Reset failure window not associated with owned decoder pause');
      qualifyOwnedPauseSample(fault, row.context, association);
      resetDecision = event;
      resetRow = row;
    } else assert.equal(event.action, undefined, 'Minimum hold carries an action');
    count++;
  }
  assert(resetDecision, 'Missing higher-profile deadline reset decision');
  const action = write.action,
    application = write.application;
  same(action, resetDecision.action, 'Applied action differs from deadline recommendation');
  assert(
    application && uuid(application.id) && uuid(application.attemptID),
    'Invalid native application',
  );
  assert.equal(application.fromRevision, '0');
  assert.equal(application.windowSequence, resetDecision.deliveryFailure.sequence);
  assert.equal(application.attemptID.toLowerCase(), scope.publishingAttemptID.toLowerCase());
  for (const value of [
    application.admittedAt,
    application.completionDeadline,
    write.acknowledgedAt,
  ])
    assert(finite(value), 'Invalid application timing');
  assert(
    application.admittedAt >= resetDecision.evaluatedAt &&
      application.admittedAt <= action.validUntil,
    'Reset admission outside recommendation validity',
  );
  assert(
    application.completionDeadline > application.admittedAt &&
      application.completionDeadline <= application.admittedAt + 2,
    'Invalid bounded native completion deadline',
  );
  assert(
    profile.acknowledgedAt >= application.admittedAt &&
      write.acknowledgedAt >= next.acceptedAt &&
      write.acknowledgedAt <= application.completionDeadline,
    'Native reset acknowledgment outside application',
  );
  assert(
    format.phases[1].firstObservedAt >= application.admittedAt &&
      format.encoderSessions[1].firstCompletedAt >= application.admittedAt,
    'Native reset predates admission',
  );
  // Every classified row must retain the actual applied native identity, including
  // healthy rows and old-revision classifications attempted after acknowledgment.
  for (const row of audit.rows.filter((r) => r.result !== null)) {
    const expected = row.evaluatedAt < write.acknowledgedAt ? boot : write;
    same(
      qualityReceipt(row),
      normalizeReceipt(expected.receipt),
      'Deadline audit changed applied receipt',
    );
    assert(
      row.profileID === expected.profileID &&
        row.appliedRevision === expected.revision &&
        row.videoBitrate === expected.receipt.bitRate &&
        row.acknowledgedAt === expected.acknowledgedAt,
      'Deadline audit crosses applied truth',
    );
  }
  const resetAssociation = associations.find((a) => a.stalledReportAt <= resetDecision.evaluatedAt);
  const healthy = audit.rows.filter(
    (row) =>
      row.result !== null &&
      row.phase === resetRow.phase &&
      row.end <= resetRow.start &&
      row.evaluatedAt < resetAssociation.stalledReportAt &&
      isDeepStrictEqual(row.context, resetRow.context) &&
      isDeepStrictEqual(row.receipt, resetRow.receipt) &&
      row.appliedRevision === '0' &&
      row.profileID === '540p30' &&
      row.result.uncertainFrames === 0 &&
      row.result.lateFrames === 0 &&
      row.result.missingFrames === 0 &&
      row.result.onTimeFPS >= 30,
  );
  const healthyHigherProfileOneSecondWindows = healthy.filter((r) => r.end - r.start === 1).length;
  const healthyHigherProfileTwoSecondWindows = healthy.filter((r) => r.end - r.start === 2).length;
  assert(
    healthyHigherProfileOneSecondWindows >= 5 && healthyHigherProfileTwoSecondWindows >= 3,
    'Insufficient healthy higher-profile deadline baseline before owned fault',
  );
  return {
    higherProfileResetWriteQualified: true,
    deadlineFailureDecisionCount: count,
    ownedFaultAssociationQualified: true,
    pauseMilliseconds,
    faultAssociations: associations,
    healthyHigherProfileOneSecondWindows,
    healthyHigherProfileTwoSecondWindows,
    automaticAdaptationQualified: false,
    recoveryQualified: false,
    nativeApplicationSeconds: write.acknowledgedAt - application.admittedAt,
    decisionToFirstMinimumFrameSeconds:
      format.phases[1].firstObservedAt - resetDecision.evaluatedAt,
    decisionToAcknowledgmentSeconds: write.acknowledgedAt - resetDecision.evaluatedAt,
    deadlineEvidence,
    transitions,
  };
}
