import assert from 'node:assert/strict';
import { isDeepStrictEqual } from 'node:util';
import { expandQualityEvidence } from './quality-evidence-dictionary.mjs';
import {
  measuredCapacityProfile,
  qualifyMeasuredCapacityUplink,
} from './measured-capacity-uplink.mjs';
import { capacityClockScope, qualifyCapacityClockBrackets } from './capacity-clock-brackets.mjs';
import {
  qualifyMeasuredNativeEvidence,
  qualifyMeasuredDeliveryOwnership,
  qualifyMeasuredDeliveryCoverage,
} from './measured-native-trial.mjs';
import {
  qualifyMeasuredTrialConfirmedPrefix,
  qualifyMeasuredCadenceContinuity,
} from './measured-trial-policy.mjs';
import { qualifyRecoveryDeliveryBucket } from './recovery-delivery-bucket.mjs';
import { replayNativePressure, replayNativeLocalPressure } from './native-quality-pressure.mjs';
const time = (n) =>
  assert(Number.isFinite(n) && n >= 0 && n <= 1e12, 'Invalid capacity policy time');
const seq = (s) => {
  assert(typeof s === 'string' && /^[1-9][0-9]*$/.test(s) && Number.isSafeInteger(Number(s)));
  return Number(s);
};
const identity = (s) => [
  s.workerID,
  s.workerEpoch,
  s.workerAttempt,
  s.readerID,
  s.processingScopeID,
];
function owned(row, configuration) {
  for (const k of ['revision', 'profileID', 'acknowledgedAt'])
    assert.equal(row[k], configuration[k]);
  for (const k of ['receipt', 'profileReceipt', 'application'])
    assert.deepEqual(row[k], configuration[k]);
}
function noAuthority(row) {
  for (const k of ['action', 'candidate', 'candidateAdmission', 'decoderStall', 'deliveryFailure'])
    assert.equal(row[k], undefined, 'Unexpected suffix authority');
}
function decisionTime(row) {
  for (const n of [row.evaluatedAt, row.window.start, row.window.end]) time(n);
  assert(
    row.evaluatedAt >= row.window.end &&
      row.evaluatedAt <= row.at &&
      row.evaluatedAt - row.window.end <= 2,
    'Stale/future suffix decision',
  );
}
function cadenceDecision(row, source, reports, scope) {
  const s = row.source,
    w = row.window,
    r = reports.findLast((r) => r.evaluatedUptime <= row.evaluatedAt);
  assert(r && row.evaluatedAt - r.evaluatedUptime <= 0.25, 'Missing fresh capacity cadence');
  const status = r.response.status,
    o = status.observation,
    d = o?.decodedVideo?.completed;
  assert.equal(r.expectedAttempt, s.attemptID.toLowerCase());
  assert.equal(status.state, 'producing_output');
  assert.equal(status.gameId, scope.matchID);
  assert.equal(status.generation, scope.broadcastGeneration);
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
  const age = status.decoderCadenceAgeUpperBoundMs / 1000 + r.requestSeconds + r.residenceSeconds;
  assert(
    Number.isFinite(age) &&
      age >= 0 &&
      Math.abs(age - r.sampleAgeSeconds) < 1e-8 &&
      age + row.evaluatedAt - r.evaluatedUptime <= 0.25,
    'Stale capacity source cadence',
  );
  assert.equal(r.observedStall, false);
  assert.equal(o.decoderCadence.ended, false);
  assert.equal(o.decoderCadence.invalidReason, null);
  assert.equal(o.decoderCadence.progress.stalled, false);
  assert(
    Number.isFinite(o.decoderCadence.progress.ageMs) &&
      o.decoderCadence.progress.ageMs >= 0 &&
      o.decoderCadence.progress.ageMs < 1000,
  );
}
/** Replays a single capacity decrease and restored policy/delivery from raw metadata.
 * Decoded IDs must come from actual media; this function cannot decode files or
 * verify waveform/score/archive durability. Fresh re-ramp and production stay gated. */
export function qualifyMeasuredCapacityPolicy(raw, options = {}) {
  assert(
    options !== null && typeof options === 'object' && !Array.isArray(options),
    'Capacity policy options must be an object',
  );
  for (const key of Reflect.ownKeys(options))
    assert(
      ['profile', 'preTrialRejectionPolicy', 'capacityEvidencePolicy'].includes(key),
      'Unknown capacity policy option',
    );
  const {
    profile,
    preTrialRejectionPolicy = 'reject',
    capacityEvidencePolicy = 'congestion-v1',
  } = options;
  assert(
    ['congestion-v1', 'rate-ledger-v1'].includes(capacityEvidencePolicy),
    'Unknown capacity evidence policy',
  );
  const rateLedgerSelected = capacityEvidencePolicy === 'rate-ledger-v1';
  measuredCapacityProfile(profile);
  const input = { ...raw, quality: expandQualityEvidence(raw.quality) };
  const { quality, snapshot, cadenceReports, deliveryAudit } = input;
  const transport = qualifyMeasuredCapacityUplink(input.uplink, {
    profile,
    coveragePolicy: 'scheduled-hold-v1',
    ...(rateLedgerSelected
      ? { stimulusPolicy: 'rate-ledger-v1', rateLedger: input.rateLedger }
      : {}),
  });
  const exchanges = input.capacityClockExchanges;
  assert.equal(exchanges.formatVersion, 1);
  assert.equal(exchanges.clockBracketsQualified, false);
  assert.equal(exchanges.nativeAdaptationQualified, false);
  assert.deepEqual(capacityClockScope(exchanges.scope), capacityClockScope(snapshot.scope));
  const clock = qualifyCapacityClockBrackets({
    profile,
    scope: snapshot.scope,
    schedule: input.uplink.forwardRateSchedule,
    nativeAudit: input.capacityClockAudit,
    exchanges: exchanges.exchanges,
  });
  const native = qualifyMeasuredNativeEvidence(input, {
    recovery: true,
    capacityRecovery: true,
    capacityDecrease: true,
    probePolicy: 'recovery-budget-v1',
    ...(rateLedgerSelected ? { mediaLossPolicy: 'accounted-bounded-v1' } : {}),
  });
  const prefix = qualifyMeasuredTrialConfirmedPrefix({
    quality,
    snapshot,
    cadenceReports,
    sourceIntervalQualification: native.source,
    profileQualification: native.profile,
    lifecycleQualification: native.nativeLifecycle,
    candidateWitnessQualification: native.witness,
    transportPolicy: 'recovery-budget-v1',
    cadenceAuditMode: 'capacity',
    preTrialRejectionPolicy,
  });
  qualifyMeasuredDeliveryOwnership(input, {
    profile: native.profile,
    nativeLifecycle: native.nativeLifecycle,
    delivery: native.delivery,
  });
  const prefixDelivery = qualifyMeasuredDeliveryCoverage(deliveryAudit, {
    revision: '1',
    start: prefix.probation.start,
    end: prefix.probation.end,
  });
  const [limit, restored] = clock.boundaries,
    decrease = native.nativeLifecycle.capacityDecrease;
  assert(
    prefix.confirmedAt < limit.nativeLower && prefix.confirmedEventAt < limit.nativeLower,
    'Trial confirmation must precede actual capacity limit',
  );
  assert(decrease.windowStart > limit.nativeUpper, 'Pressure must follow actual capacity limit');
  const events = quality.events,
    confirmed = events[prefix.confirmedEventIndex],
    applied = events[decrease.appliedEventIndex],
    trial = events.find((e) => e.kind === 'applied');
  assert(
    applied.at < restored.nativeLower && applied.acknowledgedAt < restored.nativeLower,
    'Decrease must complete before restoration',
  );
  const reports = cadenceReports.rows,
    cadenceEnd = reports.at(-1).evaluatedUptime;
  time(cadenceEnd);
  let lastAt = confirmed.at,
    lastSource = seq(confirmed.source.sequence),
    lastSourceEnd = confirmed.source.end,
    lastPolicy = seq(confirmed.window.sequence),
    lastPolicyEnd = confirmed.window.end,
    lastEvaluation = confirmed.evaluatedAt;
  let localPressureEvents = 0,
    sourceWindows = 0,
    transitionWindows = 0,
    recoveryCutoff = restored.nativeUpper;
  let eligible = [];
  for (let index = prefix.nextEventIndex; index < events.length; index++) {
    const row = events[index];
    time(row.at);
    assert(row.at >= lastAt, 'Capacity suffix clock reversal');
    lastAt = row.at;
    assert(
      ['evaluated', 'localPressure', 'applied', 'transition', 'stopped'].includes(row.kind),
      'Unsupported capacity suffix event',
    );
    if (row.kind === 'applied') {
      assert.equal(index, decrease.appliedEventIndex, 'Unexpected capacity application');
      continue;
    }
    const current = index < decrease.appliedEventIndex ? trial : applied;
    owned(row, current);
    noAuthority(row);
    if (row.kind === 'stopped') {
      assert.equal(index, events.length - 1);
      assert.equal(row.closed, true);
      assert.equal(row.window, undefined);
      assert.equal(row.source, undefined);
      assert(cadenceEnd <= row.at, 'Cadence outlives stopped publisher');
      continue;
    }
    assert.equal(row.closed, false);
    if (row.kind === 'localPressure') {
      decisionTime(row);
      assert(
        row.evaluatedAt >= lastEvaluation && row.evaluatedAt <= cadenceEnd,
        'Pressure outside cadence audit',
      );
      const w = row.window;
      assert.equal(w.revision, current.revision);
      assert.equal(seq(w.sequence), lastPolicy + 1);
      assert(
        w.start >= lastPolicyEnd && w.start >= current.acknowledgedAt,
        'Local pressure overlaps prior policy',
      );
      const p = replayNativeLocalPressure(row, snapshot, {
        after: lastPolicyEnd,
        duration: 0.25,
        transportPolicy: 'recovery-budget-v1',
      });
      const reasons = [
        ...(w.start !== lastPolicyEnd ? ['telemetryGap'] : []),
        'unknownConnectivity',
        'missingCapture',
        'missingEncoded',
        'missingReceiver',
        'missingSourceLoss',
        ...(w.queue === null ? ['missingQueue'] : []),
        'missingCapacity',
        'unknownPressure',
        ...(w.transport === 'unknown' ? ['unknownTransportPressure'] : []),
        ...(p.queue !== null && p.queue >= 0.75 ? ['queuePressure'] : []),
        ...(p.thermal === 'elevated' ? ['thermalPressure'] : []),
        ...(p.transport === 'elevated' ? ['transportPressure'] : []),
        ...(current.revision === '2' ? ['minimumProfileInsufficient'] : []),
      ];
      assert.deepEqual(row.reasons, reasons);
      assert.equal(row.state, 'unknown');
      if (current.revision === '1')
        assert.equal(index, decrease.pressureEventIndex, 'Unmatched higher-profile pressure');
      if (w.end >= restored.nativeUpper) {
        recoveryCutoff = w.end;
        eligible = [];
      }
      lastPolicy = Number(w.sequence);
      lastPolicyEnd = w.end;
      lastEvaluation = row.evaluatedAt;
      localPressureEvents++;
      continue;
    }
    const s = row.source;
    assert(s, 'Missing suffix source');
    assert.deepEqual(identity(s), identity(confirmed.source));
    assert.equal(s.attemptID.toLowerCase(), snapshot.scope.publishingAttemptID.toLowerCase());
    const sources = snapshot.sourceIntervals.filter(
      (x) =>
        x.sequence === s.sequence &&
        x.workerEpoch === s.workerEpoch &&
        x.workerAttempt === s.workerAttempt,
    );
    const proofs = native.source.intervals.filter((x) => x.sequence === Number(s.sequence));
    assert.equal(sources.length, 1);
    assert.equal(proofs.length, 1);
    const source = sources[0],
      proof = proofs[0];
    assert.deepEqual(source.scope, snapshot.scope);
    assert.equal(source.workerId, s.workerID);
    assert.equal(source.publication.readerId, s.readerID);
    assert.equal(source.processing?.scopeID, s.processingScopeID);
    assert.equal(seq(s.sequence), lastSource + 1);
    assert.equal(Number(s.previousSequence), lastSource);
    assert.equal(source.previousSequence, s.previousSequence);
    assert.equal(proof.previousSequence, lastSource);
    assert.equal(s.start, source.captureBoundaryStartTime);
    assert.equal(s.end, source.captureBoundaryEndTime);
    assert.equal(s.start, lastSourceEnd, 'Source interval gap');
    assert(s.end > s.start && s.end - s.start <= 5.25 && s.end <= row.at);
    lastSource = Number(s.sequence);
    lastSourceEnd = s.end;
    const configuration = {
      id: current.receipt.configurationID,
      encoderSessionID: current.receipt.encoderSessionID,
      bitRate: current.receipt.bitRate,
    };
    if (row.kind === 'transition') {
      assert(
        !isDeepStrictEqual(source.encodingConfiguration, configuration) ||
          s.start < current.acknowledgedAt ||
          s.start < lastPolicyEnd,
        'Forged healthy-source transition',
      );
      for (const key of ['window', 'state', 'reasons', 'evidence', 'evaluatedAt'])
        assert.equal(row[key], undefined, 'Transition cannot supply policy health');
      assert(row.at <= cadenceEnd, 'Transition outside cadence audit');
      transitionWindows++;
      continue;
    }
    const w = row.window;
    assert(w);
    decisionTime(row);
    assert(
      row.evaluatedAt >= lastEvaluation && row.evaluatedAt <= cadenceEnd,
      'Source decision outside cadence audit',
    );
    assert.equal(seq(w.sequence), lastPolicy + 1);
    assert.equal(w.revision, current.revision);
    assert.equal(w.start, s.start);
    assert.equal(w.end, s.end);
    assert(
      w.start >= current.acknowledgedAt && w.start >= lastPolicyEnd,
      'Source overlaps local policy window',
    );
    const duration = w.end - w.start;
    assert(duration >= 1 && duration <= 5.25);
    time(w.observedAt);
    assert(
      w.observedAt >= w.end &&
        w.observedAt <= row.evaluatedAt &&
        row.evaluatedAt - w.observedAt <= 2,
    );
    assert.equal(source.publishingGeneration, current.receipt.generation);
    assert.deepEqual(source.encodingConfiguration, configuration);
    for (const [key, name] of [
      ['captured', 'capturedFrames'],
      ['encoded', 'encodedFrames'],
      ['received', 'decodedFrames'],
    ]) {
      assert.equal(w[key], source[name]);
      assert.equal(w[key], proof[name]);
      assert(w[key] / duration >= 29.7, 'Unhealthy capacity source cadence');
    }
    assert.equal(w.expected, w.captured);
    assert.equal(w.lost, w.captured - w.received);
    assert(w.expected > 0 && w.lost >= 0 && w.lost / w.expected <= 0.01);
    assert.equal(w.capacity, null);
    assert.equal(w.connectivity, 'connected');
    replayNativePressure(row, snapshot, source, { transportPolicy: 'recovery-budget-v1' });
    assert(Number.isFinite(w.queue) && w.queue >= 0 && w.queue < 0.5);
    for (const k of ['thermal', 'worker', 'transport']) assert.equal(w[k], 'nominal');
    assert.deepEqual(row.reasons, [
      ...(w.start !== lastPolicyEnd ? ['telemetryGap'] : []),
      'missingCapacity',
    ]);
    assert.equal(row.state, 'healthy');
    cadenceDecision(row, source, reports, snapshot.scope);
    if (current.revision === '2' && w.start >= recoveryCutoff) {
      if (eligible.length) assert.equal(w.start, eligible.at(-1).end, 'Recovery source gap');
      eligible.push({
        start: w.start,
        end: w.end,
        evaluatedAt: row.evaluatedAt,
        eventIndex: index,
        policySequence: w.sequence,
        sourceSequence: s.sequence,
      });
    }
    lastPolicy = Number(w.sequence);
    lastPolicyEnd = w.end;
    lastEvaluation = row.evaluatedAt;
    sourceWindows++;
  }
  assert.equal(events.at(-1).kind, 'stopped');
  assert(
    localPressureEvents > 0 && transitionWindows > 0 && eligible.length > 0,
    'Missing complete recovery suffix',
  );
  // The native driver defers one newly completed source interval while its
  // encoder work is pending, for less than two seconds. A completed predecessor
  // may never disappear just because no later policy row exposes the sequence gap.
  const tail = snapshot.sourceIntervals.filter((s) => seq(s.sequence) > lastSource);
  assert(tail.length <= 1, 'Unconsumed capacity source decisions');
  const latestSource = snapshot.sourceIntervals.at(-1);
  const finalObservation = reports.at(-1).response.status.observation;
  assert.equal(
    finalObservation.decodedVideo.completed.sequence,
    seq(latestSource.sequence),
    'Final capacity source differs from raw cadence',
  );
  assert.deepEqual(
    finalObservation.processing,
    latestSource.processing,
    'Final capacity processing differs from raw cadence',
  );
  let pendingSource = null;
  if (tail.length) {
    const s = tail[0],
      p = s.processing?.interval;
    assert.equal(seq(s.sequence), lastSource + 1, 'Unconsumed capacity source sequence');
    assert.equal(Number(s.previousSequence), lastSource);
    assert.equal(s.captureBoundaryStartTime, lastSourceEnd);
    assert(
      s.captureBoundaryStartTime >= lastPolicyEnd &&
        s.captureBoundaryStartTime >= applied.acknowledgedAt,
    );
    assert.deepEqual(s.encodingConfiguration, {
      id: applied.receipt.configurationID,
      encoderSessionID: applied.receipt.encoderSessionID,
      bitRate: applied.receipt.bitRate,
    });
    assert(
      p &&
        Number.isSafeInteger(p.pendingFrames) &&
        p.pendingFrames > 0 &&
        p.completedFrames + p.pendingFrames === p.submittedFrames &&
        p.submittedFrames === p.decodedFrames &&
        p.omittedBeforeEncoderFrames === 0 &&
        cadenceEnd >= s.captureBoundaryEndTime &&
        cadenceEnd - s.captureBoundaryEndTime < 2,
      'Unconsumed capacity source is not a bounded pending interval',
    );
    pendingSource = {
      sequence: s.sequence,
      pendingFrames: p.pendingFrames,
      ageSeconds: cadenceEnd - s.captureBoundaryEndTime,
      healthyCreditSeconds: 0,
    };
  }
  // Every receipt is independently reconstructed before these lane checks.
  for (const row of deliveryAudit.rows)
    assert(
      row.evaluatedAt <= cadenceEnd && row.end <= cadenceEnd,
      'Delivery decision outside cadence audit',
    );
  qualifyMeasuredCadenceContinuity({
    reports,
    start: confirmed.at,
    end: cadenceEnd,
    source: confirmed.source,
    scope: snapshot.scope,
    cadenceAuditMode: 'capacity',
  });
  const ranges = [1, 2].map((duration) => {
    const rows = deliveryAudit.rows.filter(
      (r) => r.appliedRevision === '2' && r.end - r.start === duration,
    );
    assert(rows.length, 'Missing recovery delivery lane');
    let end = rows[0].start;
    for (const r of rows) {
      assert.equal(r.start, end, 'Gap in post-decrease delivery lane');
      if (r.start >= recoveryCutoff) qualifyRecoveryDeliveryBucket(r.result, duration);
      end = r.end;
    }
    // Schedule.poll makes the next bucket due at end + duration + the two
    // configured budgets. No due bucket may be omitted at the final raw poll.
    assert(
      end + duration + deliveryAudit.latencyBudget + deliveryAudit.maximumSampleAge > cadenceEnd,
      'Incomplete terminal delivery lane',
    );
    return { start: rows[0].start, end };
  });
  const shared = eligible.filter((w) => ranges.every((r) => w.start >= r.start && w.end <= r.end));
  assert(shared.length, 'No shared recovered source/delivery window');
  const selected = [];
  let end = shared[0].start;
  for (const w of shared) {
    assert.equal(w.start, end, 'Gap in shared recovery windows');
    selected.push(w);
    end = w.end;
    if (end - shared[0].start >= 10) break;
  }
  assert(end - shared[0].start >= 10, 'Insufficient restored recovery coverage');
  const recovery = qualifyMeasuredDeliveryCoverage(deliveryAudit, {
    revision: '2',
    start: shared[0].start,
    end,
    recovery: true,
  });
  return {
    capacityPolicyQualified: true,
    profile,
    nativeProfile: native.profile,
    scope: snapshot.scope,
    transport,
    ...(rateLedgerSelected
      ? { capacityEvidencePolicy, mediaConservation: native.mediaConservation }
      : {}),
    clock,
    prefix,
    prefixDelivery,
    decrease,
    recovery: {
      ...recovery,
      windowCount: selected.length,
      sourceSequences: selected.map((w) => w.sourceSequence),
      policySequences: selected.map((w) => w.policySequence),
    },
    localPressureEvents,
    sourceWindows,
    transitionWindows,
    cadenceCheckedThrough: cadenceEnd,
    pendingSource,
    deliveryLanes: ranges,
    finalProfile: '240p30',
    freshRampQualified: false,
    mediaFilesQualified: false,
    physicalDeviceQualified: false,
    productionUpgradeAuthorized: false,
  };
}
