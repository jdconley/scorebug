import assert from 'node:assert/strict';
import test from 'node:test';
import { deliverySnapshot } from '../../packages/protocol/dist/index.js';

// Synthetic scalar evidence only: these tests do not qualify capture or relay hardware.
const id = (n) => `${String(n).padStart(8, '0')}-1111-4111-8111-111111111111`;
const time = (i) => ({ value: String(270000 + i * 1000), timescale: 30000, epoch: '0', flags: 1 });
function scalarFixture() {
  const scope = {
    recordingID: 'recording',
    matchID: 'match',
    broadcastGeneration: 2,
    publishingAttemptID: id(1),
    appliedProfileRevision: '0',
  };
  const configuration = { id: id(2), encoderSessionID: id(3), bitRate: 500000 };
  const receipt = { generation: '7', configuration, acceptedAt: 9, lastSubmittedPTS: time(0) };
  const clock = { generation: '7', sourceOrigin: time(0) };
  const publication = {
    readerId: id(4),
    publisherId: id(5),
    publishingAttemptId: id(1),
    clock: { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '9000' },
  };
  const context = {
    gameId: 'match',
    generation: 2,
    workerId: 'worker',
    workerEpoch: id(6),
    attempt: 1,
    publication,
  };
  const capture = Array.from({ length: 91 }, (_, i) => ({
    sourcePTS: time(i),
    observedAt: 9 + i / 30,
    encoding: null,
  }));
  const encoded = capture
    .filter((_, i) => i !== 32)
    .map((f) => ({
      ...structuredClone(f),
      observedAt: f.observedAt + 0.002,
      encoding: {
        encoderSessionID: id(3),
        configuration: structuredClone(configuration),
        submittedAt: f.observedAt + 0.001,
        completedAt: f.observedAt + 0.002,
      },
    }));
  const arrivals = capture
    .slice(0, 90)
    .flatMap((f, i) =>
      i === 32
        ? []
        : [[i * 3000, (f.observedAt + (i === 31 ? 1.1 : i === 33 ? 0.98 : 0.1)) * 1000]],
    )
    .sort((a, b) => a[1] - b[1]);
  const packet = {
    formatVersion: 1,
    scopeID: id(7),
    sampledAtMs: 12450,
    coverageAtMs: 0,
    afterOrdinal: 0,
    lastOrdinal: arrivals.length,
    arrivals,
    invalidReason: null,
    ended: false,
  };
  const row = {
    phase: 1,
    start: 10,
    end: 11,
    evaluatedAt: 12.5,
    appliedRevision: '0',
    acknowledgedAt: 9.01,
    profileID: '240p30',
    videoBitrate: 500000,
    attemptID: id(1),
    receipt,
    deliveryReceiptID: id(8),
    sampleAgeSeconds: 0.05,
    clock,
    clockClosed: false,
    clockScope: scope,
    history: {
      scope,
      closed: false,
      invalidity: null,
      omittedCaptureFrames: '0',
      omittedEncodedFrames: '0',
      trimmedCaptureFrames: 0,
      trimmedEncodedFrames: 0,
      capture,
      encoded,
    },
    timeline: deliverySnapshot(packet),
    context,
    diagnostics: { isPublishing: true, clock, receipt, ingressScope: scope, ingressClosed: false },
    anchorSourcePTS: time(89),
    frames: capture.slice(30, 60).map((f, i) => ({
      pts: String((i + 30) * 3000),
      sourcePTS: f.sourcePTS,
      capturedAt: f.observedAt,
      wasEncoded: i !== 2,
    })),
    reason: null,
    result: {
      expectedFrames: 30,
      onTimeFrames: 27,
      lateFrames: 1,
      missingFrames: 1,
      uncertainFrames: 1,
      onTimeFPS: null,
      failureFraction: null,
    },
  };
  const response = {
    serverTime: '2040-01-01T00:00:01.000Z',
    status: {
      ...context,
      state: 'producing_output',
      expiresAt: '2040-01-01T00:00:05.000Z',
      decoderDeliveryAgeUpperBoundMs: 20,
      observation: {
        gameId: 'match',
        generation: 2,
        state: 'producing_output',
        attempt: 1,
        decodedVideo: { clock: 'mpegts-pts-90k-v1' },
        decoderDelivery: packet,
      },
    },
  };
  return {
    scope,
    audit: {
      formatVersion: 1,
      closed: true,
      overflow: false,
      invalid: false,
      latencyBudget: 1,
      maximumSampleAge: 0.25,
      rows: [row],
    },
    reports: {
      formatVersion: 1,
      closed: true,
      overflow: false,
      invalid: false,
      rows: [
        {
          response,
          expectedAttempt: id(1),
          receivedUptime: 12.48,
          evaluatedUptime: 12.49,
          requestSeconds: 0.01,
          residenceSeconds: 0.01,
          deliveryReceiptID: id(8),
          deliverySampleAgeSeconds: 0.04,
        },
      ],
    },
  };
}
function fixture() {
  const f = scalarFixture(),
    row = f.audit.rows[0],
    report = f.reports.rows[0];
  f.audit.latencyBudget = 1.5;
  row.videoBitrate = 350000;
  row.receipt.configuration.bitRate = 350000;
  row.diagnostics.receipt.configuration.bitRate = 350000;
  for (const frame of row.history.encoded) frame.encoding.configuration.bitRate = 350000;
  row.evaluatedAt = 12.6;
  const packet = report.response.status.observation.decoderDelivery;
  packet.arrivals = row.history.capture
    .slice(0, 90)
    .flatMap((frame, i) =>
      i >= 31 && i <= 38
        ? []
        : [
            [
              i * 3000,
              (i > 38
                ? Math.max(frame.observedAt + 0.1, 11.3 + (i - 39) * 0.001)
                : frame.observedAt + 0.1) * 1000,
            ],
          ],
    );
  packet.lastOrdinal = packet.arrivals.length;
  packet.sampledAtMs = 12550;
  row.timeline = deliverySnapshot(packet);
  row.result = {
    expectedFrames: 30,
    onTimeFrames: 22,
    lateFrames: 0,
    missingFrames: 8,
    uncertainFrames: 0,
    onTimeFPS: 22,
    failureFraction: 8 / 30,
  };
  report.receivedUptime = 12.58;
  report.evaluatedUptime = 12.59;
  report.sampleAgeSeconds = 0.04;
  report.observedStall = false;
  report.response.status.decoderCadenceAgeUpperBoundMs = 20;
  report.response.status.observation.decoderCadence = {
    formatVersion: 1,
    scopeID: id(10),
    invalidReason: null,
    ended: false,
    progress: { lastFreshPTS: 267000, ageMs: 480, stalled: false },
  };
  const stalled = structuredClone(report);
  stalled.receivedUptime = 11.18;
  stalled.evaluatedUptime = 11.19;
  stalled.deliveryReceiptID = id(9);
  stalled.observedStall = true;
  stalled.response.status.observation.decoderDelivery = {
    ...structuredClone(packet),
    sampledAtMs: 11150,
    arrivals: packet.arrivals.slice(0, 31),
    lastOrdinal: 31,
  };
  stalled.response.status.observation.decoderCadence.progress = {
    lastFreshPTS: 90000,
    ageMs: 1050,
    stalled: true,
  };
  f.reports.rows.unshift(stalled);
  const receipt = {
    generation: row.receipt.generation,
    configurationID: row.receipt.configuration.id.toUpperCase(),
    encoderSessionID: row.receipt.configuration.encoderSessionID.toUpperCase(),
    bitRate: 350000,
    acceptedAt: row.receipt.acceptedAt,
    lastSubmittedPTS: structuredClone(row.receipt.lastSubmittedPTS),
  };
  const identity = {
    profileID: '240p30',
    revision: '0',
    acknowledgedAt: row.acknowledgedAt,
    receipt,
  };
  f.quality = {
    formatVersion: 4,
    overflow: false,
    deadlineFailuresEnabled: true,
    decoderStallEnabled: false,
    events: [
      { ...structuredClone(identity), kind: 'bootstrap' },
      {
        ...structuredClone(identity),
        kind: 'deliveryFailure',
        state: 'degraded',
        reasons: ['freshFrameFloor', 'minimumProfileInsufficient'],
        evaluatedAt: 12.62,
        deliveryFailure: {
          publishingAttemptID: id(1).toUpperCase(),
          classifiedAt: row.evaluatedAt,
          deliveryReceiptID: row.deliveryReceiptID,
          context: structuredClone(row.context),
          scopeID: row.timeline.scopeID,
          sequence: '1',
          revision: '0',
          start: row.start,
          end: row.end,
          expectedFrames: 30,
          onTimeFrames: 22,
          lateFrames: 0,
          missingFrames: 8,
          observedAtLowerBound: 12.55,
        },
      },
      { ...structuredClone(identity), kind: 'stopped', closed: true },
    ],
  };
  f.fault = {
    closed: true,
    failed: false,
    pauseSentAt: 100000,
    resumeSentAt: 101900,
    identity: {
      worker: { pid: 10 },
      guardian: { pid: 11, ppid: 10 },
      decoder: { pid: 12, ppid: 11 },
    },
  };
  return f;
}

let qualify;
test('independently qualifies the minimum deadline hold from raw scalar evidence', async () => {
  const module = await import('../native-deadline-decisions.mjs').catch(() => null);
  assert.equal(
    typeof module?.qualifyNativeDeadlineDecisions,
    'function',
    'independent decision verifier must exist',
  );
  qualify = module.qualifyNativeDeadlineDecisions;
  const result = qualify(fixture());
  assert.equal(result.minimumHoldDecisionQualified, true);
  assert.equal(result.deadlineFailureDecisionCount, 1);
  assert.equal(result.ownedFaultAssociationQualified, true);
  assert.equal(result.deadlineEvidence.counts.missingFrames, 8);
  assert.equal(result.deadlineEvidence.latencyBudget, 1.5);
  assert.equal(result.higherProfileResetWriteQualified, false);
  assert.equal(result.automaticAdaptationQualified, false);
  assert.equal(result.recoveryQualified, false);
});

const failure = (f) => f.quality.events[1].deliveryFailure;
for (const [name, damage] of Object.entries({
  disabledDriver: (f) => (f.quality.deadlineFailuresEnabled = false),
  enabledWatchdog: (f) => (f.quality.decoderStallEnabled = true),
  fabricatedWindow: (f) => (f.quality.events[1].window = { sequence: '1' }),
  missingFailure: (f) => f.quality.events.splice(1, 1),
  watchdogMask: (f) =>
    f.quality.events.splice(1, 0, {
      ...structuredClone(f.quality.events[0]),
      kind: 'decoderStall',
    }),
  wrongContext: (f) => (failure(f).context.publication.publisherId = id(90)),
  wrongReceipt: (f) => (failure(f).deliveryReceiptID = id(90)),
  wrongScope: (f) => (failure(f).scopeID = id(90)),
  wrongRevision: (f) => (failure(f).revision = '1'),
  wrongClassification: (f) => (failure(f).classifiedAt += 0.01),
  wrongWindow: (f) => (failure(f).start += 0.01),
  wrongCount: (f) => failure(f).missingFrames--,
  wrongObservedBound: (f) => (failure(f).observedAtLowerBound += 0.01),
  decisionBeforeClassification: (f) => (f.quality.events[1].evaluatedAt = 12.59),
  staleSampleAtDecision: (f) => (f.quality.events[1].evaluatedAt = 12.81),
  staleSourceAtDecision: (f) => (f.quality.events[1].evaluatedAt = 13.01),
  uncertainty: (f) => (f.audit.rows[0].result.uncertainFrames = 1),
  forgedRawEvidence: (f) =>
    f.reports.rows[1].response.status.observation.decoderDelivery.arrivals.pop(),
  bogusHealthyCredit: (f) => (f.quality.events[1].state = 'healthy'),
  bogusRecoveryCredit: (f) => f.quality.events[1].reasons.push('recoveryQualified'),
  wrongReason: (f) => (f.quality.events[1].reasons[0] = 'sourceLoss'),
  noMinimumReason: (f) => f.quality.events[1].reasons.pop(),
  actionAtMinimum: (f) => (f.quality.events[1].action = { kind: 'reset' }),
  appliedAtMinimum: (f) =>
    f.quality.events.splice(2, 0, { ...structuredClone(f.quality.events[0]), kind: 'applied' }),
  receiptChange: (f) => (f.quality.events[1].receipt.configurationID = id(90)),
  allReceiptsUnbound: (f) => f.quality.events.forEach((e) => (e.receipt.configurationID = id(90))),
  missingStopped: (f) => f.quality.events.pop(),
  overflow: (f) => (f.quality.overflow = true),
  duplicateSequence: (f) => f.quality.events.splice(2, 0, structuredClone(f.quality.events[1])),
  noncanonicalSequence: (f) => (failure(f).sequence = '01'),
  uint64Overflow: (f) => (failure(f).sequence = '18446744073709551616'),
  noFault: (f) => (f.fault.failed = true),
  shortFault: (f) => (f.fault.resumeSentAt = f.fault.pauseSentAt + 1799),
  unownedFault: (f) => (f.fault.identity.decoder.ppid = 90),
  noObservedStall: (f) => (f.reports.rows[0].observedStall = false),
  wrongStallOwner: (f) => (f.reports.rows[0].response.status.workerId = 'other'),
  unrelatedStallPTS: (f) =>
    (f.reports.rows[0].response.status.observation.decoderCadence.progress.lastFreshPTS = 900000),
  noResumedProgress: (f) =>
    (f.reports.rows[1].response.status.observation.decoderCadence.progress.lastFreshPTS = 90000),
  wrongResumedScope: (f) =>
    (f.reports.rows[1].response.status.observation.decoderCadence.scopeID = id(90)),
}))
  test(`rejects ${name}`, () => {
    assert.equal(typeof qualify, 'function');
    const f = fixture();
    damage(f);
    assert.throws(() => qualify(f));
  });

for (const [name, damage] of Object.entries({
  expiredAtDecision: (f) =>
    (f.reports.rows[1].response.status.expiresAt = '2040-01-01T00:00:01.040Z'),
  forgedCadenceAge: (f) => (f.reports.rows[0].sampleAgeSeconds = 0.03),
  missingCadenceAge: (f) => delete f.reports.rows[0].response.status.decoderCadenceAgeUpperBoundMs,
  bogusCadenceStall: (f) =>
    (f.reports.rows[0].response.status.observation.decoderCadence.progress.ageMs = 900),
  wrongAttemptSignal: (f) => (failure(f).publishingAttemptID = id(90)),
  healthyOtherEvent: (f) =>
    f.quality.events.splice(2, 0, {
      ...structuredClone(f.quality.events[0]),
      kind: 'other',
      state: 'healthy',
    }),
  recoveryOtherEvent: (f) =>
    f.quality.events.splice(2, 0, {
      ...structuredClone(f.quality.events[0]),
      kind: 'other',
      reasons: ['recoveryQualified'],
    }),
  stoppedEarly: (f) => (f.quality.events[1].closed = true),
  unknownEventKind: (f) =>
    f.quality.events.splice(2, 0, { ...structuredClone(f.quality.events[0]), kind: 'invented' }),
}))
  test(`rejects ${name}`, () => {
    const f = fixture();
    damage(f);
    assert.throws(() => qualify(f));
  });

function thresholdsFixture(duration, missingCount) {
  const f = fixture(),
    row = f.audit.rows[0],
    report = f.reports.rows[1],
    d = failure(f);
  const packet = report.response.status.observation.decoderDelivery;
  packet.arrivals = row.history.capture
    .slice(0, 90)
    .flatMap((frame, i) =>
      i >= 31 && i < 31 + missingCount
        ? []
        : [
            [
              i * 3000,
              (i > 30
                ? Math.max(frame.observedAt + 0.1, 11.3 + (i - 31) * 0.001)
                : frame.observedAt + 0.1) * 1000,
            ],
          ],
    );
  packet.lastOrdinal = packet.arrivals.length;
  if (duration === 2) {
    row.start = 9.5;
    row.end = 11.5;
    row.evaluatedAt = 13.1;
    row.frames = row.history.capture.slice(15, 75).map((frame, i) => ({
      pts: String((i + 15) * 3000),
      sourcePTS: frame.sourcePTS,
      capturedAt: frame.observedAt,
      wasEncoded: i + 15 !== 32,
    }));
    report.receivedUptime = 13.08;
    report.evaluatedUptime = 13.09;
    packet.sampledAtMs = 13050;
    f.quality.events[1].evaluatedAt = 13.12;
    Object.assign(d, {
      start: row.start,
      end: row.end,
      classifiedAt: row.evaluatedAt,
      observedAtLowerBound: 13.05,
    });
    f.quality.events[1].reasons[0] = 'sourceLoss';
  }
  row.timeline = deliverySnapshot(packet);
  const expectedFrames = duration * 30,
    onTimeFrames = expectedFrames - missingCount;
  row.result = {
    expectedFrames,
    onTimeFrames,
    lateFrames: 0,
    missingFrames: missingCount,
    uncertainFrames: 0,
    onTimeFPS: onTimeFrames / duration,
    failureFraction: missingCount / expectedFrames,
  };
  Object.assign(d, { expectedFrames, onTimeFrames, missingFrames: missingCount });
  return f;
}
test('requires strictly fewer than 24 on-time frames in a one-second window', () => {
  assert.equal(qualify(thresholdsFixture(1, 7)).minimumHoldDecisionQualified, true);
  assert.throws(() => qualify(thresholdsFixture(1, 6)), /threshold/);
});
test('requires strictly more than five percent failures in a two-second window', () => {
  assert.equal(qualify(thresholdsFixture(2, 4)).minimumHoldDecisionQualified, true);
  assert.throws(() => qualify(thresholdsFixture(2, 3)), /threshold/);
});
test('global sequence includes ordinary controller windows', () => {
  const f = fixture();
  const ordinary = {
    ...structuredClone(f.quality.events[0]),
    kind: 'localPressure',
    evaluatedAt: 12.6,
    state: 'degraded',
    reasons: ['thermalPressure'],
    window: { sequence: '2' },
  };
  f.quality.events.splice(1, 0, ordinary);
  assert.throws(() => qualify(f), /globally increasing/);
  f.quality.events[2].deliveryFailure.sequence = '3';
  assert.equal(qualify(f).minimumHoldDecisionQualified, true);
});
test('same-lane replay cannot get a second decision under a new sequence', () => {
  const f = fixture(),
    replay = structuredClone(f.quality.events[1]);
  replay.deliveryFailure.sequence = '2';
  f.quality.events.splice(2, 0, replay);
  assert.throws(() => qualify(f), /Overlapping/);
});
test('sample reconciliation tolerance never freshens evidence at admission', () => {
  const f = fixture();
  f.audit.rows[0].sampleAgeSeconds = 0.0485;
  failure(f).observedAtLowerBound = 12.5515;
  f.quality.events[1].evaluatedAt = 12.5505 + 0.25;
  assert.throws(() => qualify(f), /Stale/);
});

test('unavailable startup report without an observation cannot mask later qualified evidence', () => {
  for (const observation of [null, undefined]) {
    const f = fixture(),
      startup = structuredClone(f.reports.rows[0]);
    startup.receivedUptime = 10.18;
    startup.evaluatedUptime = 10.19;
    startup.deliveryReceiptID = null;
    startup.deliverySampleAgeSeconds = null;
    startup.sampleAgeSeconds = null;
    startup.observedStall = null;
    startup.response.status.state = 'waiting';
    startup.response.status.observation = observation;
    f.reports.rows.unshift(startup);
    assert.equal(qualify(f).minimumHoldDecisionQualified, true);
  }
});

function interveningReport(f, evaluatedUptime = 12.61, receiptNumber = 11) {
  const row = structuredClone(f.reports.rows[1]);
  row.evaluatedUptime = evaluatedUptime;
  row.receivedUptime = evaluatedUptime - 0.01;
  row.deliveryReceiptID = id(receiptNumber);
  row.deliverySampleAgeSeconds = 0.04 + evaluatedUptime - 12.59;
  f.reports.rows.push(row);
  return row;
}
test('same-owner same-scope report preserves pending classification authority', () => {
  const f = fixture();
  interveningReport(f);
  assert.equal(qualify(f).minimumHoldDecisionQualified, true);
});
for (const [name, retire] of Object.entries({
  omission: (row) => {
    delete row.response.status.observation.decoderDelivery;
    row.deliveryReceiptID = null;
    row.deliverySampleAgeSeconds = null;
  },
  context: (row) => {
    row.response.status.workerId = 'new-worker';
    row.deliverySampleAgeSeconds = 0.04;
  },
  scope: (row) => {
    row.response.status.observation.decoderDelivery.scopeID = id(20);
    // Native invalidates its receipt for the scope rollover packet.
    row.deliveryReceiptID = null;
    row.deliverySampleAgeSeconds = null;
  },
})) {
  test(`intervening ${name} retires pending classification authority`, () => {
    const f = fixture();
    retire(interveningReport(f));
    assert.throws(() => qualify(f), /retired/);
  });
}
test('intervening omission remains retired after a fresh same-owner report', () => {
  const f = fixture(),
    omitted = interveningReport(f);
  delete omitted.response.status.observation.decoderDelivery;
  omitted.deliveryReceiptID = null;
  omitted.deliverySampleAgeSeconds = null;
  const renewed = interveningReport(f, 12.615, 12);
  renewed.deliverySampleAgeSeconds = 0.04;
  renewed.response.status.observation.decoderDelivery.sampledAtMs += 1;
  assert.throws(() => qualify(f), /retired/);
});
