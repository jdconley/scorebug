import test from 'node:test';
import assert from 'node:assert/strict';
import {
  qualifyOrdinaryRecoveryNativeEvidence,
  qualifyOrdinaryRecoveryTransportEvidence,
} from '../ordinary-recovery-evidence.mjs';
import { createSocket } from 'node:dgram';
import { setTimeout as delay } from 'node:timers/promises';
import { createUDPImpairmentProxy } from '../udp-impairment.mjs';

test('independent transport checker joins real constrained FIFO ledger and exact audit snapshots', async (t) => {
  const receiver = createSocket('udp4'),
    publisher = createSocket('udp4');
  await Promise.all(
    [receiver, publisher].map((s) => new Promise((resolve) => s.bind(0, '127.0.0.1', resolve))),
  );
  receiver.on('message', (data, peer) => receiver.send(data, peer.port, peer.address));
  const uplink = await createUDPImpairmentProxy({
    receiverPort: receiver.address().port,
    forward: { recordTimeline: true, recordRateLedger: true },
    reverse: { recordTimeline: true },
    forwardRateControl: { rateBitsPerSecond: 750000 },
  });
  t.after(async () => {
    await uplink.close();
    await Promise.all([receiver, publisher].map((s) => new Promise((resolve) => s.close(resolve))));
  });
  async function until(check) {
    const end = performance.now() + 2000;
    while (!check() && performance.now() < end) await delay(2);
    assert(check(), 'Actual UDP condition timed out');
  }
  publisher.send(Buffer.alloc(1200), uplink.port, '127.0.0.1');
  await until(() => uplink.snapshot().reverse.queue.forwarded.packets > 0);
  const constrained = uplink.constrainForward();
  for (let i = 0; i < 40; i++) publisher.send(Buffer.alloc(1200), uplink.port, '127.0.0.1');
  await until(() => uplink.snapshot().forward.queue.rateLedgerFirstDenial !== null);
  const restored = uplink.restoreForward();
  await until(() => uplink.snapshot().reverse.queue.forwarded.packets === 41);
  await uplink.close();
  const input = {
    snapshot: uplink.snapshot(),
    ledger: uplink.rateLedgerSnapshot(),
    audit: { closed: true, records: [{ receipt: constrained }, { receipt: restored }] },
  };
  assert.equal(qualifyOrdinaryRecoveryTransportEvidence(input).transportQualified, true);
  const altered = structuredClone(input);
  altered.audit.records[0].receipt.appliedAt++;
  assert.throws(() => qualifyOrdinaryRecoveryTransportEvidence(altered));
  const wrongOccupancy = structuredClone(input);
  wrongOccupancy.snapshot.forwardRateControl.phases[0].reverse.queue.queue.packets = 1;
  assert.throws(
    () => qualifyOrdinaryRecoveryTransportEvidence(wrongOccupancy),
    /Phase queue conservation/,
  );
  const wrongBaseline = structuredClone(input);
  wrongBaseline.snapshot.forwardRateControl.phases[0].rateBitsPerSecond = 750000;
  assert.throws(() => qualifyOrdinaryRecoveryTransportEvidence(wrongBaseline));
  const wrongReverse = structuredClone(input);
  wrongReverse.snapshot.forwardRateControl.phases[0].reverse.queue.configuration.rateBitsPerSecond = 750000;
  assert.throws(() => qualifyOrdinaryRecoveryTransportEvidence(wrongReverse));
  const unrelatedFinal = structuredClone(input);
  unrelatedFinal.snapshot.forward = structuredClone(constrained.forward);
  unrelatedFinal.snapshot.forward.queue.configuration.rateBitsPerSecond = null;
  unrelatedFinal.snapshot.forward.queue.closed = true;
  assert.throws(() => qualifyOrdinaryRecoveryTransportEvidence(unrelatedFinal));
  const residual = structuredClone(input);
  residual.snapshot.forward.queue.queue.packets = 1;
  assert.throws(() => qualifyOrdinaryRecoveryTransportEvidence(residual));
  const overflow = structuredClone(input);
  overflow.ledger.overflow = true;
  assert.throws(() => qualifyOrdinaryRecoveryTransportEvidence(overflow));
});

function fixture() {
  const values = [
    ['initial-minimum', 1010, 1, 1005, 1, false],
    ['initial-probation', 1050, 2, 1048, 3, true],
    ['initial-confirmed', 1061, 2, 1048, 5, false],
    ['fallback-acknowledged', 1075, 3, 1070, 7, false],
    ['recovery-probation', 1120, 4, 1118, 19, true],
    ['recovery-confirmed', 1131, 4, 1118, 21, false],
  ];
  const samples = values.map(([phase, time, revision, ack, seq, trial]) => ({
    phase,
    readStartedUptimeSeconds: time,
    readEndedUptimeSeconds: time + 0.1,
    diagnostic: {
      observedAtUptimeSeconds: String(time - 0.1),
      sessionObservedAtUptimeSeconds: String(time - 0.15),
      sessionBusy: 'false',
      sessionClosed: 'false',
      driverClosed: 'false',
      policyOwnerKey: String(revision).repeat(64),
      policySourceScopeKey: 'a'.repeat(64),
      policyAttemptID: 'same-attempt',
      policyAcknowledgedAtUptimeSeconds: String(ack),
      policyAppliedRevision: String(revision),
      policyAppliedProfile: revision % 2 ? '240p30' : '360p30',
      policyAppliedBitrate: revision % 2 ? '350000' : '600000',
      policyTrialActive: String(trial),
      ...(trial ? { policyTrialRollbackRequired: 'false' } : {}),
      policyRecommendationPending: 'false',
      policyApplicationPending: 'false',
      policyMinimumResetRequired: 'false',
      policyAcceptedSourceSequence: String(seq),
      policyAcceptedSourceWindowEnd: String(time - 0.2),
    },
  }));
  const native = {
    formatVersion: 1,
    recordingStartedUptimeSeconds: 1000,
    recordingDeadlineUptimeSeconds: 1540,
    samples,
    milestones: [
      ...values.map(([phase], sampleIndex) => ({ phase, sampleIndex })),
      { phase: 'initial-increase-acknowledged', sampleIndex: 1 },
      { phase: 'recovery-increase-acknowledged', sampleIndex: 4 },
    ],
    gates: [
      ['initial-minimum', 1001, 10],
      ['initial-increase', 1011, 150],
      ['initial-confirmation', 1050.1, 30],
      ['fallback', 1061.3, 60],
      ['recovery-increase', 1075.3, 150],
      ['recovery-confirmation', 1120.1, 30],
    ].map(([phase, startedUptimeSeconds, limitSeconds]) => ({
      phase,
      startedUptimeSeconds,
      limitSeconds,
    })),
    exchanges: [
      {
        sequence: 1,
        operation: 'constrain',
        requestStartedUptimeSeconds: 1061.2,
        responseEndedUptimeSeconds: 1061.3,
        response: {
          runID: 'run',
          sequence: 1,
          phase: 'constrained',
          rateBitsPerSecond: 750000,
          appliedAt: 80000,
          forwardOperationOrdinal: 20,
        },
      },
      {
        sequence: 2,
        operation: 'restore',
        requestStartedUptimeSeconds: 1075.2,
        responseEndedUptimeSeconds: 1075.3,
        response: {
          runID: 'run',
          sequence: 2,
          phase: 'restored',
          rateBitsPerSecond: null,
          appliedAt: 94000,
          forwardOperationOrdinal: 500,
        },
      },
    ],
  };
  const audit = {
    formatVersion: 1,
    runID: 'run',
    closed: true,
    hostClock: 'performance.now milliseconds',
    records: native.exchanges.map((e, i) => ({
      runID: 'run',
      sequence: e.sequence,
      operation: e.operation,
      diagnostic: structuredClone(samples[i === 0 ? 2 : 3].diagnostic),
      receivedAtHost: e.response.appliedAt - 1,
      respondedAtHost: e.response.appliedAt + 1,
      receipt: {
        phase: e.response.phase,
        appliedAt: e.response.appliedAt,
        rateBitsPerSecond: e.response.rateBitsPerSecond,
        forward: { queue: { rateLedgerOperationOrdinal: e.response.forwardOperationOrdinal } },
      },
    })),
  };
  return { native, audit };
}

test('qualifies two actual trial transitions across ordered native and host clock brackets', () => {
  const result = qualifyOrdinaryRecoveryNativeEvidence(fixture());
  assert.equal(result.nativePhaseOrderingQualified, true);
  assert.equal(result.mediaQualified, false);
  assert.equal(result.transportQualified, false);
});

test('ACK gate cannot count a future receipt before probation becomes observable', () => {
  const f = fixture(),
    early = structuredClone(f.native.samples[1]);
  early.readStartedUptimeSeconds = 1040;
  early.readEndedUptimeSeconds = 1040.1;
  early.diagnostic.observedAtUptimeSeconds = '1039.9';
  early.diagnostic.sessionObservedAtUptimeSeconds = '1039.85';
  for (const field of [
    'policyOwnerKey',
    'policySourceScopeKey',
    'policyAcceptedSourceSequence',
    'policyAcceptedSourceWindowEnd',
  ])
    delete early.diagnostic[field];
  f.native.samples.splice(1, 0, early);
  for (const milestone of f.native.milestones)
    if (milestone.sampleIndex >= 1) milestone.sampleIndex++;
  f.native.milestones.find((m) => m.phase === 'initial-increase-acknowledged').sampleIndex = 1;
  f.native.gates.find((g) => g.phase === 'initial-confirmation').startedUptimeSeconds = 1040.1;
  assert.throws(
    () => qualifyOrdinaryRecoveryNativeEvidence(f),
    /Acknowledgment follows its observation/,
  );
});

for (const [name, mutate] of [
  [
    'active minimum trial',
    (f) => {
      f.native.samples[0].diagnostic.policyTrialActive = 'true';
    },
  ],
  [
    'minimum rollback required',
    (f) => {
      f.native.samples[0].diagnostic.policyTrialRollbackRequired = 'true';
    },
  ],
  [
    'hidden intermediate trial replacement',
    (f) => {
      const extra = structuredClone(f.native.samples[1]);
      extra.readStartedUptimeSeconds = 1055;
      extra.readEndedUptimeSeconds = 1055.1;
      extra.diagnostic.policyOwnerKey = 'f'.repeat(64);
      f.native.samples.splice(2, 0, extra);
      for (const milestone of f.native.milestones)
        if (milestone.sampleIndex >= 2) milestone.sampleIndex++;
    },
  ],

  [
    'minimum from before recording',
    (f) => {
      f.native.samples[0].diagnostic.policyAcknowledgedAtUptimeSeconds = '999';
    },
  ],
  [
    'active trial during fallback',
    (f) => {
      f.native.samples[3].diagnostic.policyTrialActive = 'true';
    },
  ],
  [
    'rollback during fallback',
    (f) => {
      f.native.samples[3].diagnostic.policyTrialRollbackRequired = 'true';
    },
  ],
  [
    'hidden intermediate restart',
    (f) => {
      const extra = structuredClone(f.native.samples[2]);
      extra.readStartedUptimeSeconds = 1062;
      extra.readEndedUptimeSeconds = 1062.1;
      extra.diagnostic.policyAttemptID = 'hidden-other-attempt';
      f.native.samples.splice(3, 0, extra);
      for (const milestone of f.native.milestones)
        if (milestone.sampleIndex >= 3) milestone.sampleIndex++;
    },
  ],

  [
    'stale session with fresh driver',
    (f) => {
      f.native.samples[2].diagnostic.sessionObservedAtUptimeSeconds = '1000';
    },
  ],
  [
    'busy session',
    (f) => {
      f.native.samples[2].diagnostic.sessionBusy = 'true';
    },
  ],
  [
    'late confirmation gate restart',
    (f) => {
      f.native.gates[2].startedUptimeSeconds = 1060;
    },
  ],
  [
    'host handling longer than native bracket',
    (f) => {
      f.audit.records[0].receivedAtHost -= 1000;
    },
  ],
  [
    'incompatible inter-phase clocks',
    (f) => {
      f.audit.records[1].receipt.appliedAt += 30000;
      f.audit.records[1].receivedAtHost += 30000;
      f.audit.records[1].respondedAtHost += 30000;
      f.native.exchanges[1].response.appliedAt += 30000;
    },
  ],

  [
    'pre-constraint fallback',
    (f) => {
      f.native.samples[3].diagnostic.policyAcknowledgedAtUptimeSeconds = '1061';
    },
  ],
  [
    'pre-restoration recovery',
    (f) => {
      f.native.samples[4].diagnostic.policyAcknowledgedAtUptimeSeconds = '1074';
    },
  ],
  [
    'missing probation',
    (f) => {
      f.native.samples[1].diagnostic.policyTrialActive = 'false';
    },
  ],
  [
    'changed trial owner',
    (f) => {
      f.native.samples[2].diagnostic.policyOwnerKey = 'b'.repeat(64);
    },
  ],
  [
    'restarted publishing',
    (f) => {
      f.native.samples[4].diagnostic.policyAttemptID = 'new';
    },
  ],
  [
    'changed source scope',
    (f) => {
      f.native.samples[4].diagnostic.policySourceScopeKey = 'b'.repeat(64);
    },
  ],
  [
    'no advancing source',
    (f) => {
      f.native.samples[2].diagnostic.policyAcceptedSourceSequence = '3';
    },
  ],
  [
    'pending reset',
    (f) => {
      f.native.samples[2].diagnostic.policyMinimumResetRequired = 'true';
    },
  ],
  [
    'stale AX diagnostic',
    (f) => {
      f.native.samples[2].diagnostic.observedAtUptimeSeconds = '1000';
    },
  ],
  [
    'expired increase gate',
    (f) => {
      f.native.gates[1].startedUptimeSeconds = 800;
    },
  ],
  [
    'missing response bracket',
    (f) => {
      delete f.native.exchanges[0].responseEndedUptimeSeconds;
    },
  ],
  [
    'changed actual host receipt',
    (f) => {
      f.audit.records[0].receipt.appliedAt++;
    },
  ],
  [
    'incomplete controller',
    (f) => {
      f.audit.closed = false;
    },
  ],
  [
    'retained native failure',
    (f) => {
      f.native.failure = 'timeout';
    },
  ],
])
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifyOrdinaryRecoveryNativeEvidence(f));
  });
