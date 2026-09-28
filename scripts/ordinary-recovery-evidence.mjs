import assert from 'node:assert/strict';
import { qualifyRateLedger } from './rate-ledger-qualification.mjs';
import { qualifyDatagramTimeline } from './datagram-timeline-qualification.mjs';
import { timingContractForProfile } from './native-timing-contract.mjs';

export function ordinarySourceAgeLimit(diagnostic) {
  if (diagnostic.timingProfileID === undefined) return 5;
  const contract = timingContractForProfile(diagnostic.timingProfileID);
  assert.equal(diagnostic.decoderBudgetMilliseconds, String(contract.decoderBudgetMs));
  assert.equal(
    diagnostic.captureWindowMaximumAgeMilliseconds,
    String(contract.maximumCaptureWindowEvaluationAgeMs),
  );
  return Math.max(5, contract.maximumCaptureWindowEvaluationAgeMs / 1000);
}

/** Complete owned UDP accounting; does not infer native adaptation or media delivery. */
export function qualifyOrdinaryRecoveryTransportEvidence({ snapshot, ledger, audit }) {
  assert.equal(snapshot.formatVersion, 1);
  assert.equal(snapshot.closed, true);
  assert.equal(snapshot.foreignPeerPackets, 0);
  assert.deepEqual(snapshot.errors, []);
  assert.equal(snapshot.forwardRateSchedule, undefined);
  const control = snapshot.forwardRateControl;
  assert.deepEqual(control.requested, { mode: 'single-constraint', rateBitsPerSecond: 750000 });
  assert.equal(control.phases.length, 3);
  assert.deepEqual(
    control.phases.map((p) => p.phase),
    ['baseline', 'constrained', 'restored'],
  );
  assert(time(control.startedAt) <= time(control.phases[0].appliedAt));
  assert(time(control.stoppedAt) >= time(control.phases[2].appliedAt));
  assert.equal(audit.closed, true);
  assert.equal(audit.records.length, 2);
  for (let i = 0; i < 2; i++)
    assert.deepEqual(
      audit.records[i].receipt,
      control.phases[i + 1],
      'Audit does not identify actual UDP transition',
    );
  const configuration = {
    rateBitsPerSecond: null,
    delayMilliseconds: 0,
    dropEvery: 0,
    maxDatagramBytes: 2048,
    burstBytes: 16384,
    maxQueuePackets: 256,
    maxQueueBytes: 262144,
  };
  const dispositions = [
    'received',
    'forwarded',
    'injectedDrop',
    'overflowDrop',
    'oversizeDrop',
    'closeDiscard',
  ];
  for (let i = 0; i < 3; i++) {
    const phase = control.phases[i];
    assert.equal(phase.rateBitsPerSecond, i === 1 ? 750000 : null);
    if (i) assert(time(phase.appliedAt) >= time(control.phases[i - 1].appliedAt));
    for (const name of ['forward', 'reverse']) {
      const queue = phase[name].queue;
      assert.equal(queue.closed, false);
      assert.deepEqual(queue.configuration, {
        ...configuration,
        rateBitsPerSecond: name === 'forward' && i === 1 ? 750000 : null,
      });
      assert.equal(qualifyDatagramTimeline(queue).complete, true);
      assert.equal(queue.timeline.omittedEvents, 0);
      for (const [unit, occupancy, limit] of [
        ['packets', queue.queue.packets, configuration.maxQueuePackets],
        ['wireBytes', queue.queue.wireBytes, configuration.maxQueueBytes],
      ]) {
        assert(Number.isSafeInteger(occupancy) && occupancy >= 0 && occupancy <= limit);
        assert.equal(
          queue.received[unit] -
            dispositions
              .filter((kind) => kind !== 'received')
              .reduce((sum, kind) => sum + queue[kind][unit], 0),
          occupancy,
          'Phase queue conservation failed',
        );
      }
    }
  }
  function extendsQueue(before, after, boundary) {
    for (const kind of dispositions)
      for (const unit of ['packets', 'wireBytes'])
        assert(after[kind][unit] >= before[kind][unit], 'Queue counter regressed across phase');
    if (before.timeline.firstObservedAt !== null)
      assert.equal(after.timeline.firstObservedAt, before.timeline.firstObservedAt);
    const later = new Map(after.timeline.windows.map((window) => [window.start, window]));
    for (const earlier of before.timeline.windows) {
      const next = later.get(earlier.start);
      assert(next, 'Timeline prefix disappeared');
      if (earlier.end <= boundary)
        assert.deepEqual(next, earlier, 'Completed timeline prefix changed');
      else {
        for (const kind of dispositions)
          for (const unit of ['packets', 'wireBytes'])
            assert(next[kind][unit] >= earlier[kind][unit], 'Partial timeline counters regressed');
        for (const field of [
          'peakQueuePackets',
          'peakQueueBytes',
          'maximumForwardResidenceMilliseconds',
        ])
          assert(next[field] >= earlier[field], 'Partial timeline maximum regressed');
      }
    }
  }
  for (const name of ['forward', 'reverse']) {
    const direction = snapshot[name],
      queue = direction.queue;
    assert.equal(direction.pendingPackets, 0);
    assert.equal(direction.pendingPayloadBytes, 0);
    assert.equal(queue.closed, true);
    assert.equal(queue.queue.packets, 0);
    assert.equal(queue.queue.wireBytes, 0);
    for (const unit of ['packets', 'wireBytes'])
      assert.equal(
        queue.received[unit],
        ['forwarded', 'injectedDrop', 'overflowDrop', 'oversizeDrop', 'closeDiscard'].reduce(
          (sum, kind) => sum + queue[kind][unit],
          0,
        ),
        'Closed queue conservation failed',
      );
    assert.deepEqual(queue.configuration, configuration);
    assert.equal(qualifyDatagramTimeline(queue).complete, true);
    assert.equal(queue.timeline.omittedEvents, 0);
    assert.equal(queue.injectedDrop.packets, 0);
    assert.equal(queue.oversizeDrop.packets, 0);
    assert(
      queue.received.packets > 0 && queue.forwarded.packets > 0,
      'Actual bidirectional traffic required',
    );
    for (let i = 0; i < 3; i++)
      extendsQueue(
        control.phases[i][name].queue,
        i === 2 ? queue : control.phases[i + 1][name].queue,
        control.phases[i].appliedAt,
      );
  }
  const rate = qualifyRateLedger(
    {
      ledger,
      limited: { appliedAt: control.phases[1].appliedAt, queue: control.phases[1].forward.queue },
      restored: { appliedAt: control.phases[2].appliedAt, queue: control.phases[2].forward.queue },
    },
    { configuration: { ...configuration, rateBitsPerSecond: 750000 } },
  );
  return {
    transportQualified: true,
    nativePhaseOrderingQualified: false,
    mediaQualified: false,
    rate,
  };
}

function time(value) {
  assert(
    typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12,
    'Invalid clock value',
  );
  return value;
}
function scalar(value) {
  assert(typeof value === 'string' && value.trim() !== '', 'Missing diagnostic scalar');
  return time(Number(value));
}
function ordinal(value) {
  assert(
    typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value),
    'Invalid diagnostic ordinal',
  );
  return BigInt(value);
}
function key(value) {
  assert(typeof value === 'string' && /^[a-f0-9]{64}$/.test(value), 'Missing owner/scope key');
}
function freshSession(diagnostic, readEnd) {
  const session = scalar(diagnostic.sessionObservedAtUptimeSeconds);
  const driver = scalar(diagnostic.observedAtUptimeSeconds);
  assert(
    session <= driver && driver <= readEnd && readEnd - session <= 5,
    'Stale session diagnostic',
  );
  return session;
}

/** Native transition/clock evidence only; transport and recorded media remain separate gates. */
export function qualifyOrdinaryRecoveryNativeEvidence(input) {
  return qualifyNative(input, false);
}
/** Explicit closed contract; never infer the required ladder from submitted milestones. */
export function qualifyOrdinary720RecoveryNativeEvidence(input) {
  return qualifyNative(input, true);
}
/** Physical acquisition is a separate fixed contract, never a caller-selected budget. */
export function qualifyPhysical720RecoveryNativeEvidence(input) {
  return qualifyNative(input, true, true);
}
function qualifyNative({ native, audit }, recovery720, physical = false) {
  assert.equal(native.formatVersion, physical ? 3 : recovery720 ? 2 : 1);
  if (recovery720)
    assert.equal(native.contract, physical ? 'physical-recovery720-v1' : 'recovery720');
  if (physical) assert.equal(native.captureSource, 'physical-camera');
  assert.equal(native.failure, undefined, 'Native recovery retained a failure');
  assert.equal(audit.formatVersion, 1);
  assert.equal(audit.closed, true);
  assert.equal(audit.hostClock, 'performance.now milliseconds');
  assert.equal(audit.records.length, 2);
  assert.equal(native.exchanges.length, 2);
  const start = time(native.recordingStartedUptimeSeconds),
    deadline = time(native.recordingDeadlineUptimeSeconds);
  assert(
    deadline > start && deadline <= start + 540,
    'Recording deadline exceeds finite source allowance',
  );
  assert(
    Array.isArray(native.samples) &&
      native.samples.length > 0 &&
      native.samples.length <= (recovery720 ? 270 : 300),
  );
  const phases = recovery720
    ? [
        physical ? 'initial-source-ready' : 'initial-minimum',
        'initial-360-probation',
        'initial-360-confirmed',
        'initial-720-probation',
        'initial-720-confirmed',
        'fallback-acknowledged',
        'recovery-360-probation',
        'recovery-360-confirmed',
        'recovery-720-probation',
        'recovery-720-confirmed',
      ]
    : [
        'initial-minimum',
        'initial-probation',
        'initial-confirmed',
        'fallback-acknowledged',
        'recovery-probation',
        'recovery-confirmed',
      ];
  const selected = phases.map((phase) => {
    const matches = native.milestones.filter((m) => m.phase === phase);
    assert.equal(matches.length, 1, `Exactly one ${phase} milestone required`);
    const index = matches[0].sampleIndex;
    assert(Number.isSafeInteger(index) && index >= 0 && index < native.samples.length);
    return { ...native.samples[index], index };
  });
  let previousReadEnd = start;
  for (const sample of native.samples) {
    const before = time(sample.readStartedUptimeSeconds),
      after = time(sample.readEndedUptimeSeconds),
      d = sample.diagnostic;
    assert(
      before >= previousReadEnd && after >= before && after - before <= 5 && after <= deadline,
      'Invalid intermediate read bracket',
    );
    if (recovery720) assert(after <= deadline - 45, 'Cleanup reserve consumed');
    previousReadEnd = after;
    assert(
      d &&
        Object.values(d).every((v) => typeof v === 'string') &&
        Buffer.byteLength(JSON.stringify(d)) <= 4096,
    );
    if (d.policyAttemptID !== undefined)
      assert.equal(
        d.policyAttemptID,
        selected[0].diagnostic.policyAttemptID,
        'Intermediate attempt changed',
      );
    if (d.policySourceScopeKey !== undefined)
      assert.equal(
        d.policySourceScopeKey,
        selected[0].diagnostic.policySourceScopeKey,
        'Intermediate source scope changed',
      );
  }
  for (let i = 0; i < selected.length; i++) {
    const s = selected[i],
      d = s.diagnostic;
    assert(d && Object.values(d).every((v) => typeof v === 'string'));
    assert(Buffer.byteLength(JSON.stringify(d)) <= 4096);
    const before = time(s.readStartedUptimeSeconds),
      after = time(s.readEndedUptimeSeconds);
    assert(
      before >= start && after >= before && after <= deadline && after - before <= 5,
      'Invalid diagnostic read bracket',
    );
    const observed = scalar(d.observedAtUptimeSeconds);
    assert(
      observed <= after && observed >= before - 5,
      'Stale or incompatible native diagnostic clock',
    );
    const sessionObserved = freshSession(d, after);
    assert(scalar(d.policyAcknowledgedAtUptimeSeconds) <= sessionObserved);
    const sourceEnd = scalar(d.policyAcceptedSourceWindowEnd);
    assert(
      sourceEnd <= sessionObserved && sessionObserved - sourceEnd <= ordinarySourceAgeLimit(d),
      'Stale accepted source',
    );
    ordinal(d.policyAppliedRevision);
    ordinal(d.policyAcceptedSourceSequence);
    key(d.policyOwnerKey);
    key(d.policySourceScopeKey);
    assert(d.policyAttemptID);
    assert.equal(d.sessionClosed, 'false');
    assert.equal(d.driverClosed, 'false');
    if (i) {
      assert(
        s.index > selected[i - 1].index,
        'Milestones must use distinct advancing observations',
      );
      assert(before >= selected[i - 1].readEndedUptimeSeconds);
      assert.equal(
        d.policyAttemptID,
        selected[0].diagnostic.policyAttemptID,
        'Publishing attempt restarted',
      );
      assert.equal(
        d.policySourceScopeKey,
        selected[0].diagnostic.policySourceScopeKey,
        'Source scope changed',
      );
    }
  }
  if (recovery720) {
    const owners = new Map();
    for (const { diagnostic: d } of selected) {
      const revision = owners.get(d.policyOwnerKey);
      assert(
        revision === undefined || revision === d.policyAppliedRevision,
        'Owner reused across revisions',
      );
      owners.set(d.policyOwnerKey, d.policyAppliedRevision);
    }
  }
  function applied(s, profile, bitrate) {
    assert.equal(s.diagnostic.policyAppliedProfile, profile);
    assert.equal(s.diagnostic.policyAppliedBitrate, String(bitrate));
    for (const field of [
      'policyRecommendationPending',
      'policyApplicationPending',
      'policyMinimumResetRequired',
      'sessionBusy',
    ])
      assert.equal(s.diagnostic[field], 'false', `Unsettled ${field}`);
  }
  function trial(probation, confirmed, profile, bitrate) {
    applied(probation, profile, bitrate);
    applied(confirmed, profile, bitrate);
    const p = probation.diagnostic,
      c = confirmed.diagnostic;
    assert.equal(p.policyTrialActive, 'true', 'Actual probation must be observed');
    assert.equal(p.policyTrialRollbackRequired, 'false');
    assert.equal(c.policyTrialActive, 'false');
    assert(
      c.policyTrialRollbackRequired === undefined || c.policyTrialRollbackRequired === 'false',
    );
    for (const field of [
      'policyOwnerKey',
      'policyAppliedRevision',
      'policyAcknowledgedAtUptimeSeconds',
    ]) {
      assert.equal(c[field], p[field], 'Trial identity changed before confirmation');
      for (const sample of native.samples.slice(probation.index, confirmed.index + 1))
        if (sample.diagnostic[field] !== undefined)
          assert.equal(sample.diagnostic[field], p[field], 'Intermediate trial identity changed');
    }
    assert(
      ordinal(c.policyAcceptedSourceSequence) > ordinal(p.policyAcceptedSourceSequence),
      'No new source confirmation',
    );
    assert(scalar(c.policyAcceptedSourceWindowEnd) > scalar(p.policyAcceptedSourceWindowEnd));
  }
  const minimum = selected[0],
    probation = selected[1],
    confirmed = selected[recovery720 ? 4 : 2],
    fallback = selected[recovery720 ? 5 : 3],
    recovery = selected[recovery720 ? 6 : 4],
    recovered = selected.at(-1);
  const trials = recovery720
    ? [
        ['initial-360', selected[1], selected[2], minimum, '360p30', 600000],
        ['initial-720', selected[3], selected[4], selected[2], '720p30', 3000000],
        ['recovery-360', selected[6], selected[7], fallback, '360p30', 600000],
        ['recovery-720', selected[8], selected[9], selected[7], '720p30', 3000000],
      ]
    : [
        ['initial', probation, confirmed, minimum, '360p30', 600000],
        ['recovery', recovery, recovered, fallback, '360p30', 600000],
      ];
  let encoderACK;
  if (physical) {
    const local = time(native.localPublishingObservedUptimeSeconds),
      output = time(native.workerOutputObservedUptimeSeconds);
    for (const [phase, anchor] of [
      ['local-publishing-observed', local],
      ['worker-output-observed', output],
    ]) {
      const observations = native.milestones.filter((m) => m.phase === phase);
      assert.equal(observations.length, 1, `Missing/duplicate ${phase} anchor`);
      assert.equal(observations[0].uptimeSeconds, anchor, 'Startup anchor changed');
      assert.equal(observations[0].sampleIndex, undefined, 'Status anchor is not source evidence');
    }
    const milestones = native.milestones.filter((m) => m.phase === 'initial-encoder-ack');
    assert.equal(milestones.length, 1, 'Exactly one initial encoder ACK required');
    const index = milestones[0].sampleIndex;
    assert(Number.isSafeInteger(index) && index >= 0 && index < minimum.index);
    encoderACK = native.samples[index];
    assert.equal(encoderACK.phase, 'initial-encoder-ack');
    assert.equal(minimum.phase, 'initial-source-ready');
    const before = time(encoderACK.readStartedUptimeSeconds),
      after = time(encoderACK.readEndedUptimeSeconds);
    assert(
      local >= start &&
        local <= before &&
        after <= output &&
        output <= minimum.readStartedUptimeSeconds,
      'Startup observations are out of order',
    );
    assert(time(milestones[0].uptimeSeconds) >= after && milestones[0].uptimeSeconds - after <= 2);
    const sourceMilestone = native.milestones.find((m) => m.phase === 'initial-source-ready');
    assert(
      time(sourceMilestone.uptimeSeconds) >= minimum.readEndedUptimeSeconds &&
        sourceMilestone.uptimeSeconds - minimum.readEndedUptimeSeconds <= 2,
    );
    const d = encoderACK.diagnostic;
    assert(scalar(d.observedAtUptimeSeconds) >= before - 5);
    const observed = freshSession(d, after),
      acknowledged = scalar(d.policyAcknowledgedAtUptimeSeconds);
    assert(acknowledged > start && acknowledged <= observed, 'Invalid initial encoder ACK time');
    assert.equal(d.sessionClosed, 'false');
    assert.equal(d.driverClosed, 'false');
    applied(encoderACK, '240p30', 350000);
    assert.equal(d.policyAppliedRevision, '0', 'Initial encoder must be revision zero');
    assert.equal(d.policyTrialActive, 'false');
    assert(
      d.policyTrialRollbackRequired === undefined || d.policyTrialRollbackRequired === 'false',
    );
    // Configuration acknowledgment grants no source-health credit. The selected
    // source sample still passes every shared owner/freshness check above.
    for (const sample of native.samples.slice(index, minimum.index + 1)) {
      for (const field of [
        'policyAppliedRevision',
        'policyAcknowledgedAtUptimeSeconds',
        'policyAttemptID',
      ])
        if (sample.diagnostic[field] !== undefined)
          assert.equal(
            sample.diagnostic[field],
            d[field],
            'Initial encoder identity changed during acquisition',
          );
    }
    for (const field of [
      'policyAppliedRevision',
      'policyAcknowledgedAtUptimeSeconds',
      'policyAttemptID',
    ])
      assert.equal(minimum.diagnostic[field], d[field], 'Source does not own initial encoder ACK');
    for (const [phase, anchor] of [
      ['initial-encoder-ack', local],
      ['initial-source-ready', output],
    ]) {
      const gates = native.gates.filter((g) => g.phase === phase);
      assert.equal(gates.length, 1, `Missing/duplicate ${phase} gate`);
      assert.equal(
        gates[0].startedUptimeSeconds,
        anchor,
        'Startup gate detached from observed status',
      );
    }
  }
  applied(minimum, '240p30', 350000);
  applied(fallback, '240p30', 350000);
  assert.equal(minimum.diagnostic.policyTrialActive, 'false');
  assert(
    minimum.diagnostic.policyTrialRollbackRequired === undefined ||
      minimum.diagnostic.policyTrialRollbackRequired === 'false',
  );
  assert.equal(fallback.diagnostic.policyTrialActive, 'false');
  assert(
    fallback.diagnostic.policyTrialRollbackRequired === undefined ||
      fallback.diagnostic.policyTrialRollbackRequired === 'false',
  );
  assert(scalar(minimum.diagnostic.policyAcknowledgedAtUptimeSeconds) > start);
  assert(
    scalar(probation.diagnostic.policyAcknowledgedAtUptimeSeconds) >
      scalar(minimum.diagnostic.policyAcknowledgedAtUptimeSeconds),
  );
  for (const [, p, c, previous, profile, bitrate] of trials) {
    trial(p, c, profile, bitrate);
    if (recovery720) {
      assert.equal(
        ordinal(p.diagnostic.policyAppliedRevision),
        ordinal(previous.diagnostic.policyAppliedRevision) + 1n,
        'Non-consecutive climb',
      );
      assert(
        scalar(p.diagnostic.policyAcknowledgedAtUptimeSeconds) > previous.readEndedUptimeSeconds,
        'Climb preceded prior confirmation',
      );
      assert.notEqual(
        p.diagnostic.policyOwnerKey,
        previous.diagnostic.policyOwnerKey,
        'Climb reused prior owner',
      );
      assert(
        ordinal(p.diagnostic.policyAcceptedSourceSequence) >
          ordinal(previous.diagnostic.policyAcceptedSourceSequence),
      );
      assert(
        scalar(p.diagnostic.policyAcceptedSourceWindowEnd) >
          scalar(previous.diagnostic.policyAcceptedSourceWindowEnd),
      );
      for (const sample of native.samples.slice(previous.index + 1, p.index + 1))
        if (sample.diagnostic.policyAppliedRevision !== undefined)
          assert(
            ordinal(sample.diagnostic.policyAppliedRevision) <=
              ordinal(p.diagnostic.policyAppliedRevision),
            'Hidden applied rollback during climb',
          );
      const first = validateFormat(p.diagnostic, profile, bitrate);
      assert.equal(first.kind, 'trial', 'Climb must own measured probation');
      if (previous.diagnostic.appliedTransition !== undefined) {
        const prior = JSON.parse(previous.diagnostic.appliedTransition);
        assert.equal(
          first.oldEncoder,
          prior.rateEncoder,
          'Climb did not replace preceding encoder',
        );
        validateReceiptContinuity(first, prior);
      }
      const last = validateFormat(c.diagnostic, profile, bitrate);
      assert.deepEqual(last, first, 'Trial receipt changed before confirmation');
    }
  }
  if (recovery720) {
    validateFormat(fallback.diagnostic, '240p30', 350000);
    let precedingReceipt = validateFormat(confirmed.diagnostic, '720p30', 3000000);
    let revision = ordinal(confirmed.diagnostic.policyAppliedRevision),
      rate = 3000000;
    const restoredAt = time(native.exchanges[1].responseEndedUptimeSeconds);
    // The selected minimum is only a milestone; the constraint remains active
    // through the restoration response, including any intervening observations.
    for (const sample of native.samples
      .slice(confirmed.index + 1)
      .filter((sample) => sample.readStartedUptimeSeconds <= restoredAt)) {
      const d = sample.diagnostic;
      if (d.policyAppliedRevision === undefined) continue;
      const next = ordinal(d.policyAppliedRevision);
      assert(next >= revision, 'Observed revision rewind');
      if (next > revision) {
        const witness = validateFormat(d, d.policyAppliedProfile, scalar(d.policyAppliedBitrate));
        // Sampling can miss an intermediate descent. Compare exact source/time
        // lower bounds and generation with the last observed receipt, without
        // claiming an exhaustive encoder chain through unsampled revisions.
        validateReceiptContinuity(witness, precedingReceipt);
        precedingReceipt = witness;
        assert.equal(witness.revision, d.policyAppliedRevision);
        assert(!['trial', 'increase'].includes(witness.kind), 'Observed constrained increase');
        const nextRate = scalar(d.policyAppliedBitrate);
        assert(nextRate <= rate, 'Observed constrained increase');
        assert(
          scalar(d.policyAcknowledgedAtUptimeSeconds) >
            time(native.exchanges[0].responseEndedUptimeSeconds),
        );
        revision = next;
        rate = nextRate;
      }
    }
  }
  for (const [a, b] of [
    [minimum, probation],
    [confirmed, fallback],
    [fallback, recovery],
  ]) {
    assert(
      ordinal(b.diagnostic.policyAppliedRevision) > ordinal(a.diagnostic.policyAppliedRevision),
      'Revision did not advance',
    );
    assert.notEqual(a.diagnostic.policyOwnerKey, b.diagnostic.policyOwnerKey);
    assert(
      ordinal(b.diagnostic.policyAcceptedSourceSequence) >
        ordinal(a.diagnostic.policyAcceptedSourceSequence),
    );
  }
  const acknowledgments = trials.map(([prefix, trialSample, , , profile, bitrate]) => {
    const phase = `${prefix}-increase-acknowledged`;
    const matches = native.milestones.filter((m) => m.phase === phase);
    assert.equal(matches.length, 1, `Missing ${phase}`);
    const index = matches[0].sampleIndex;
    assert(Number.isSafeInteger(index) && index >= 0 && index < native.samples.length);
    const sample = native.samples[index],
      d = sample.diagnostic;
    const before = time(sample.readStartedUptimeSeconds),
      after = time(sample.readEndedUptimeSeconds);
    assert(before >= start && after >= before && after <= deadline && after - before <= 5);
    assert(index <= trialSample.index && after <= trialSample.readEndedUptimeSeconds);
    const observed = scalar(d.observedAtUptimeSeconds);
    assert(observed >= before - 5 && observed <= after);
    assert(
      scalar(d.policyAcknowledgedAtUptimeSeconds) <= freshSession(d, after),
      'Acknowledgment follows its observation',
    );
    for (const field of [
      'policyAttemptID',
      'policyAppliedRevision',
      'policyAppliedProfile',
      'policyAppliedBitrate',
      'policyAcknowledgedAtUptimeSeconds',
    ])
      assert.equal(
        d[field],
        trialSample.diagnostic[field],
        'Acknowledgment does not own the observed trial',
      );
    assert.equal(d.sessionClosed, 'false');
    assert.equal(d.driverClosed, 'false');
    if (recovery720)
      assert.deepEqual(
        validateFormat(d, profile, bitrate),
        validateFormat(trialSample.diagnostic, profile, bitrate),
        'ACK receipt does not own trial',
      );
    return sample;
  });
  const gateContracts = [
    ...(physical
      ? [
          ['initial-encoder-ack', 10, encoderACK],
          ['initial-source-ready', 30, minimum],
        ]
      : [['initial-minimum', 10, minimum]]),
    ['fallback', 60, fallback],
    ...trials.flatMap(([prefix, , c], i) => [
      [`${prefix}-increase`, 150, acknowledgments[i]],
      [`${prefix}-confirmation`, 30, c],
    ]),
  ];
  if (recovery720)
    assert.equal(native.gates.length, physical ? 11 : 10, 'Closed recovery gate contract');
  for (const [phase, limit, observation] of gateContracts) {
    const gates = native.gates.filter((g) => g.phase === phase);
    assert.equal(gates.length, 1, `Missing/duplicate ${phase} gate`);
    const gate = gates[0],
      began = time(gate.startedUptimeSeconds);
    assert.equal(gate.limitSeconds, limit);
    assert(began >= start && began <= observation.readStartedUptimeSeconds);
    assert(observation.readEndedUptimeSeconds <= began + limit, `${phase} exceeded its gate`);
  }
  for (const [phase, anchor] of [
    ['fallback', native.exchanges[0].responseEndedUptimeSeconds],
    ...trials.flatMap(([prefix, , , previous], i) => [
      [
        `${prefix}-increase`,
        previous === fallback
          ? native.exchanges[1].responseEndedUptimeSeconds
          : previous.readEndedUptimeSeconds,
      ],
      [`${prefix}-confirmation`, acknowledgments[i].readEndedUptimeSeconds],
    ]),
  ]) {
    const began = native.gates.find((g) => g.phase === phase).startedUptimeSeconds;
    assert(began >= time(anchor) && began - anchor <= 2, 'Gate detached from preceding phase');
  }
  for (let i = 0; i < 2; i++) {
    const e = native.exchanges[i],
      row = audit.records[i],
      trigger = i === 0 ? confirmed : fallback;
    const before = time(e.requestStartedUptimeSeconds),
      after = time(e.responseEndedUptimeSeconds);
    assert(
      after >= before && after - before <= 5 && after <= deadline,
      'Missing or excessive network clock bracket',
    );
    assert(
      before >= trigger.readEndedUptimeSeconds && before - trigger.readEndedUptimeSeconds <= 2,
    );
    const operation = i === 0 ? 'constrain' : 'restore',
      phase = i === 0 ? 'constrained' : 'restored';
    assert.equal(e.operation, operation);
    assert.equal(row.operation, operation);
    assert.equal(e.sequence, i + 1);
    assert.equal(row.sequence, i + 1);
    assert.equal(row.runID, audit.runID);
    assert.equal(e.response.runID, audit.runID);
    assert.equal(e.response.sequence, i + 1);
    assert.deepEqual(row.diagnostic, trigger.diagnostic, 'Network trigger diagnostic changed');
    const receipt = row.receipt;
    assert.equal(receipt.phase, phase);
    assert.equal(e.response.phase, phase);
    assert.equal(receipt.rateBitsPerSecond, i === 0 ? 750000 : null);
    assert.equal(e.response.rateBitsPerSecond, receipt.rateBitsPerSecond);
    assert.equal(e.response.appliedAt, receipt.appliedAt);
    assert.equal(
      e.response.forwardOperationOrdinal,
      receipt.forward.queue.rateLedgerOperationOrdinal,
    );
    assert(
      time(row.receivedAtHost) <= time(receipt.appliedAt) &&
        receipt.appliedAt <= time(row.respondedAtHost),
    );
    assert(
      (row.respondedAtHost - row.receivedAtHost) / 1000 <= after - before + 1e-9,
      'Host operation cannot fit native request bracket',
    );
    if (i) {
      assert(row.receivedAtHost >= audit.records[0].respondedAtHost);
      assert(before >= native.exchanges[0].responseEndedUptimeSeconds);
      const hostElapsed = (receipt.appliedAt - audit.records[0].receipt.appliedAt) / 1000;
      assert(
        hostElapsed >= before - native.exchanges[0].responseEndedUptimeSeconds - 1e-9 &&
          hostElapsed <= after - native.exchanges[0].requestStartedUptimeSeconds + 1e-9,
        'Host transition interval disagrees with native brackets',
      );
    }
    const next = i === 0 ? fallback : recovery;
    assert(
      scalar(next.diagnostic.policyAcknowledgedAtUptimeSeconds) > after,
      'Acknowledgment predates applied network boundary',
    );
    const nextGate = native.gates.find(
      (g) =>
        g.phase ===
        (i === 0 ? 'fallback' : recovery720 ? 'recovery-360-increase' : 'recovery-increase'),
    );
    assert(nextGate.startedUptimeSeconds >= after);
  }
  return {
    nativePhaseOrderingQualified: true,
    transportQualified: false,
    mediaQualified: false,
    ...(physical ? { physicalStartupQualified: true, startupContract: native.contract } : {}),
    publishingAttemptID: minimum.diagnostic.policyAttemptID,
    phases: selected.map((s, i) => ({
      phase: phases[i],
      revision: s.diagnostic.policyAppliedRevision,
      acknowledgedAtUptimeSeconds: scalar(s.diagnostic.policyAcknowledgedAtUptimeSeconds),
      observedAtUptimeSeconds: scalar(s.diagnostic.observedAtUptimeSeconds),
    })),
  };
}

/** Exact CoreMedia epoch-zero numeric serialization; no floating point PTS conversion. */
function rational(value) {
  assert(
    typeof value === 'string' && /^(0|[1-9][0-9]*)\/([1-9][0-9]*)$/.test(value),
    'Invalid exact PTS',
  );
  const [n, d] = value.split('/').map(BigInt);
  assert(n <= 9223372036854775807n && d <= 2147483647n, 'PTS integer overflow');
  return [n, d];
}
function compare(a, b) {
  return a[0] * b[1] - b[0] * a[1];
}
function validateReceiptContinuity(current, previous) {
  assert.equal(current.profileGeneration, previous.rateGeneration, 'Publishing generation changed');
  assert(
    compare(rational(current.oldPTS), rational(previous.ratePTS)) >= 0n,
    'Transition source PTS predates preceding receipt',
  );
  assert(
    scalar(current.profileNativeAt) >= scalar(previous.nativeAt),
    'Transition native time predates preceding receipt',
  );
}
function validateFormat(d, profile, bitrate) {
  assert(typeof d.appliedTransition === 'string', 'Missing ACK format receipt');
  const w = JSON.parse(d.appliedTransition);
  assert(w && Object.values(w).every((v) => typeof v === 'string'));
  for (const [field, current] of [
    ['revision', 'policyAppliedRevision'],
    ['attemptID', 'policyAttemptID'],
    ['profile', 'policyAppliedProfile'],
    ['bitrate', 'policyAppliedBitrate'],
    ['ackAt', 'policyAcknowledgedAtUptimeSeconds'],
  ])
    assert.equal(w[field], d[current]);
  assert.equal(ordinal(w.revision), ordinal(w.fromRevision) + 1n);
  assert.equal(w.profile, profile);
  assert.equal(w.nativeBitrate, String(bitrate));
  const dimensions = {
    '240p30': ['426', '240'],
    '360p30': ['640', '360'],
    '720p30': ['1280', '720'],
  }[profile];
  assert.deepEqual(
    [w.formatWidth, w.formatHeight],
    dimensions,
    'Actual receipt dimensions mismatch',
  );
  for (const field of ['oldEncoder', 'newEncoder', 'rateEncoder'])
    assert(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(w[field]),
      'Invalid encoder identity',
    );
  assert.notEqual(w.oldEncoder, w.newEncoder);
  assert.equal(w.newEncoder, w.rateEncoder);
  assert(ordinal(w.profileGeneration) > 0n);
  assert.equal(w.profileGeneration, w.rateGeneration);
  assert(ordinal(w.profileGeneration) <= 18446744073709551615n);
  assert(compare(rational(w.oldPTS), rational(w.newPTS)) < 0n, 'Profile PTS did not advance');
  assert(
    compare(rational(w.newPTS), rational(w.ratePTS)) <= 0n,
    'Rate receipt preceded profile PTS',
  );
  assert(
    scalar(w.profileNativeAt) <= scalar(w.nativeAt) && scalar(w.nativeAt) <= scalar(w.ackAt),
    'Receipt follows ACK',
  );
  return w;
}
