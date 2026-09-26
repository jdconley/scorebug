import assert from 'node:assert/strict';
import { qualifyRateLedger } from './rate-ledger-qualification.mjs';
import { qualifyDatagramTimeline } from './datagram-timeline-qualification.mjs';

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
export function qualifyOrdinaryRecoveryNativeEvidence({ native, audit }) {
  assert.equal(native.formatVersion, 1);
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
    Array.isArray(native.samples) && native.samples.length > 0 && native.samples.length <= 300,
  );
  const phases = [
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
      sourceEnd <= sessionObserved && sessionObserved - sourceEnd <= 5,
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
  function trial(probation, confirmed) {
    applied(probation, '360p30', 600000);
    applied(confirmed, '360p30', 600000);
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
  const [minimum, probation, confirmed, fallback, recovery, recovered] = selected;
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
  trial(probation, confirmed);
  trial(recovery, recovered);
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
  const acknowledgments = ['initial-increase-acknowledged', 'recovery-increase-acknowledged'].map(
    (phase, i) => {
      const matches = native.milestones.filter((m) => m.phase === phase);
      assert.equal(matches.length, 1, `Missing ${phase}`);
      const index = matches[0].sampleIndex;
      assert(Number.isSafeInteger(index) && index >= 0 && index < native.samples.length);
      const sample = native.samples[index],
        d = sample.diagnostic,
        trialSample = i === 0 ? probation : recovery;
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
      return sample;
    },
  );
  const gateContracts = [
    ['initial-minimum', 10, minimum],
    ['initial-increase', 150, acknowledgments[0]],
    ['initial-confirmation', 30, confirmed],
    ['fallback', 60, fallback],
    ['recovery-increase', 150, acknowledgments[1]],
    ['recovery-confirmation', 30, recovered],
  ];
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
    ['initial-increase', minimum.readEndedUptimeSeconds],
    ['initial-confirmation', acknowledgments[0].readEndedUptimeSeconds],
    ['fallback', native.exchanges[0].responseEndedUptimeSeconds],
    ['recovery-increase', native.exchanges[1].responseEndedUptimeSeconds],
    ['recovery-confirmation', acknowledgments[1].readEndedUptimeSeconds],
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
      (g) => g.phase === (i === 0 ? 'fallback' : 'recovery-increase'),
    );
    assert(nextGate.startedUptimeSeconds >= after);
  }
  return {
    nativePhaseOrderingQualified: true,
    transportQualified: false,
    mediaQualified: false,
    publishingAttemptID: minimum.diagnostic.policyAttemptID,
    phases: selected.map((s, i) => ({
      phase: phases[i],
      revision: s.diagnostic.policyAppliedRevision,
      acknowledgedAtUptimeSeconds: scalar(s.diagnostic.policyAcknowledgedAtUptimeSeconds),
      observedAtUptimeSeconds: scalar(s.diagnostic.observedAtUptimeSeconds),
    })),
  };
}
