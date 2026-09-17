import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { qualifyNativeDeliveryDeadlines } from './native-delivery-deadlines.mjs';

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
  const receipt = normalizeReceipt(boot[0].receipt);
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
    assert(
      d &&
        scalarSequence !== undefined &&
        event.window === undefined &&
        event.decoderStall === undefined,
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
    same(receipt, qualityReceipt(row), 'Quality receipt differs from native deadline receipt');
    assert(
      row.profileID === '240p30' &&
        row.videoBitrate === 350000 &&
        d.revision === '0' &&
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
