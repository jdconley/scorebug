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

// Full synthetic native format + independently reconstructable deadline packets.
// These fixtures exercise proof composition; they never qualify a hardware run.
function profileResetFixture() {
  const f = fixture();
  const pts = (n) => ({ value: String(7395 + n * 2), timescale: 60, epoch: '0', flags: 1 });
  const configuration = { id: id(2), encoderSessionID: id(3), bitRate: 1500000 };
  const receipt = { generation: '7', configuration, acceptedAt: 100.012, lastSubmittedPTS: pts(0) };
  const boot = {
    profileID: '540p30',
    revision: '0',
    acknowledgedAt: 100.02,
    receipt: {
      generation: '7',
      configurationID: id(2),
      encoderSessionID: id(3),
      bitRate: 1500000,
      acceptedAt: 100.012,
      lastSubmittedPTS: pts(0),
    },
  };
  const template = structuredClone(f.audit.rows[0]);
  const context = template.context;
  const clock = { generation: '7', sourceOrigin: pts(0) };
  const allCapture = Array.from({ length: 1800 }, (_, n) => ({
    sourcePTS: pts(n),
    observedAt: 100 + n / 30,
    encoding: null,
  }));
  const allArrivals = allCapture.flatMap((frame, n) =>
    n >= 811 && n <= 818
      ? []
      : [
          [
            n * 3000,
            (n > 810
              ? Math.max(frame.observedAt + 0.1, 128.3 + (n - 819) * 0.001)
              : frame.observedAt + 0.1) * 1000,
          ],
        ],
  );
  const makeReport = (evaluatedUptime, number, stalled = false) => {
    const sampledAtMs = Math.round((evaluatedUptime - 0.04) * 1000);
    const arrivals = allArrivals.filter((a) => a[1] <= sampledAtMs);
    const afterOrdinal = Math.max(0, arrivals.length - 256);
    const packet = {
      formatVersion: 1,
      scopeID: id(7),
      sampledAtMs,
      coverageAtMs: afterOrdinal ? arrivals[afterOrdinal - 1][1] : 0,
      afterOrdinal,
      lastOrdinal: arrivals.length,
      arrivals: arrivals.slice(afterOrdinal),
      invalidReason: null,
      ended: false,
    };
    const report = structuredClone(f.reports.rows[1]);
    Object.assign(report, {
      receivedUptime: evaluatedUptime - 0.01,
      evaluatedUptime,
      deliveryReceiptID: id(number),
      observedStall: stalled,
    });
    report.response.status.observation.decoderDelivery = packet;
    report.response.status.observation.decoderCadence.progress = {
      lastFreshPTS: stalled ? 810 * 3000 : arrivals.at(-1)[0],
      ageMs: stalled ? 1050 : 100,
      stalled,
    };
    return report;
  };
  const windows = [1, 2, 3, 4, 5].map((n) => [100 + n, 101 + n]);
  windows.push([101, 103], [103, 105], [105, 107], [127, 128]);
  windows.sort((a, b) => a[1] - b[1] || a[0] - b[0]);
  const reports = new Map();
  f.audit.rows = windows.map(([start, end]) => {
    const evaluatedAt = end + 1.6;
    if (!reports.has(evaluatedAt))
      reports.set(evaluatedAt, makeReport(evaluatedAt - 0.01, 30 + reports.size));
    const report = reports.get(evaluatedAt),
      packet = report.response.status.observation.decoderDelivery;
    const capture = allCapture.filter((r) => r.observedAt + 0.002 <= evaluatedAt);
    const encoded = capture.map((r) => ({
      ...structuredClone(r),
      observedAt: r.observedAt + 0.002,
      encoding: {
        encoderSessionID: id(3),
        configuration: structuredClone(configuration),
        submittedAt: r.observedAt + 0.001,
        completedAt: r.observedAt + 0.002,
      },
    }));
    const frames = capture
      .filter((r) => r.observedAt >= start && r.observedAt < end)
      .map((r) => ({
        pts: String(((Number(r.sourcePTS.value) - 7395) / 2) * 3000),
        sourcePTS: r.sourcePTS,
        capturedAt: r.observedAt,
        wasEncoded: true,
      }));
    const missingFrames = start === 127 ? 8 : 0,
      expectedFrames = frames.length;
    return {
      ...structuredClone(template),
      start,
      end,
      evaluatedAt,
      videoBitrate: 1500000,
      profileID: '540p30',
      acknowledgedAt: boot.acknowledgedAt,
      receipt: structuredClone(receipt),
      deliveryReceiptID: report.deliveryReceiptID,
      clock: structuredClone(clock),
      history: { ...structuredClone(template.history), capture, encoded },
      diagnostics: {
        ...structuredClone(template.diagnostics),
        clock: structuredClone(clock),
        receipt: structuredClone(receipt),
      },
      timeline: deliverySnapshot(packet),
      anchorSourcePTS: pts(packet.arrivals.at(-1)[0] / 3000),
      frames,
      result: {
        expectedFrames,
        onTimeFrames: expectedFrames - missingFrames,
        lateFrames: 0,
        missingFrames,
        uncertainFrames: 0,
        onTimeFPS: (expectedFrames - missingFrames) / (end - start),
        failureFraction: missingFrames / expectedFrames,
      },
    };
  });
  f.reports.rows = [...reports.values(), makeReport(128.19, 60, true)].sort(
    (a, b) => a.evaluatedUptime - b.evaluatedUptime,
  );
  const paused = f.reports.rows.find((r) => r.observedStall);
  f.fault.pausedSample = {
    requestStartedAt: 101800,
    receivedAt: 101850,
    value: {
      context: structuredClone(context),
      decoderCadence: structuredClone(paused.response.status.observation.decoderCadence),
      decoderCadenceAgeUpperBoundMs: 20,
      serverTime: paused.response.serverTime,
      expiresAt: paused.response.status.expiresAt,
    },
  };
  f.fault.beforePauseSample = structuredClone(f.fault.pausedSample);
  Object.assign(f.fault.beforePauseSample, { requestStartedAt: 99900, receivedAt: 99950 });
  f.fault.beforePauseSample.value.decoderCadence.progress = {
    lastFreshPTS: 810 * 3000,
    ageMs: 50,
    stalled: false,
  };
  const row = f.audit.rows.at(-1);
  const action = {
    kind: 'reset',
    profileID: '240p30',
    bitRate: 350000,
    fromRevision: '0',
    validUntil: 129.8,
  };
  const profileReceipt = {
    profile: '240p30',
    publishingGeneration: '7',
    previousEncoderSessionID: id(3),
    encoderSessionID: id(20),
    lastOldSourcePTS: pts(899),
    firstNewSourcePTS: pts(900),
    width: 426,
    height: 240,
    rawVideoFramesDropped: '0',
    acknowledgedAt: 130.02,
  };
  const after = {
    profileID: '240p30',
    revision: '1',
    acknowledgedAt: 130.04,
    profileReceipt,
    receipt: {
      generation: '7',
      configurationID: id(21),
      encoderSessionID: id(20),
      bitRate: 350000,
      acceptedAt: 130.03,
      lastSubmittedPTS: pts(900),
    },
  };
  f.quality.events = [
    { ...structuredClone(boot), kind: 'bootstrap' },
    {
      ...structuredClone(boot),
      kind: 'deliveryFailure',
      evaluatedAt: 129.62,
      state: 'degraded',
      reasons: ['freshFrameFloor'],
      action: structuredClone(action),
      deliveryFailure: {
        ...failure(f),
        classifiedAt: row.evaluatedAt,
        deliveryReceiptID: row.deliveryReceiptID,
        context: structuredClone(context),
        start: row.start,
        end: row.end,
        observedAtLowerBound: 129.55,
      },
    },
    {
      ...structuredClone(after),
      kind: 'applied',
      action: structuredClone(action),
      application: {
        id: id(22),
        admittedAt: 129.63,
        completionDeadline: 131.63,
        attemptID: id(1),
        fromRevision: '0',
        windowSequence: '1',
      },
    },
    { ...structuredClone(after), kind: 'stopped', closed: true },
  ];
  f.quality.events.at(-1).application = structuredClone(f.quality.events[2].application);
  const phases = [0, 1].map((n) => ({
    width: n ? 426 : 960,
    height: n ? 240 : 540,
    frames: 900,
    firstSourcePTS: pts(n * 900),
    lastSourcePTS: pts(n * 900 + 899),
    maximumSourceGapSeconds: 1 / 30,
    firstObservedAt: 100.01 + n * 30,
    lastObservedAt: 100.01 + n * 30 + 899 / 30,
    maximumObservationGapSeconds: 1 / 30,
  }));
  f.format = {
    formatVersion: 7,
    sequence: 'stall540',
    scope: structuredClone(f.scope),
    isClosed: true,
    invalid: false,
    frames: 1800,
    publishingGeneration: '7',
    phases,
    receipts: [profileReceipt],
    encoderSessions: phases.map((p, n) => ({
      encoderSessionID: id(n ? 20 : 3),
      frames: 900,
      firstSourcePTS: p.firstSourcePTS,
      lastSourcePTS: p.lastSourcePTS,
      firstCompletedAt: 100 + n * 30,
      lastCompletedAt: 100 + n * 30 + 899 / 30,
      maximumCompletionGapSeconds: 1 / 30,
      maximumEncodeLatencySeconds: 0.2,
    })),
    compressedFrames: phases.flatMap((p, n) =>
      Array.from({ length: 900 }, (_, i) => ({
        sourcePTS: pts(n * 900 + i),
        observedAt: p.firstObservedAt + i / 30,
        byteCount: 1000,
        isSync: i % 60 === 0,
      })),
    ),
  };
  f.snapshot = {
    scope: structuredClone(f.scope),
    isClosed: true,
    monotonicAnchor: 99,
    captureDetachedAt: 161,
    omittedCompletedWindowCount: '0',
    publishingClockObservation: { publishingGeneration: '7' },
    completed: [
      { encodedVideo: { callbackCount: '1800', firstSourcePTS: pts(0), lastSourcePTS: pts(1799) } },
    ],
    current: { encodedVideo: { callbackCount: '0' } },
  };
  f.liveIDs = Array.from({ length: 1770 }, (_, n) => n + 30);
  return f;
}
let qualifyReset;
test('qualifies exactly one deadline-caused native 540p to 240p reset after healthy baseline', async () => {
  const module = await import('../native-deadline-decisions.mjs');
  assert.equal(
    typeof module.qualifyNativeDeadlineReset,
    'function',
    'independent reset verifier must exist',
  );
  qualifyReset = module.qualifyNativeDeadlineReset;
  const result = qualifyReset(profileResetFixture());
  assert.equal(result.higherProfileResetWriteQualified, true);
  assert.equal(result.ownedFaultAssociationQualified, true);
  assert.equal(result.deadlineFailureDecisionCount, 1);
  assert.equal(result.healthyHigherProfileOneSecondWindows, 5);
  assert.equal(result.healthyHigherProfileTwoSecondWindows, 3);
  assert.equal(result.automaticAdaptationQualified, false);
  assert.equal(result.recoveryQualified, false);
});
for (const [name, damage] of Object.entries({
  changedPersistedApplication: (f) => (f.quality.events.at(-1).application.id = id(90)),
  applicationBeforeWrite: (f) =>
    (f.quality.events[1].application = structuredClone(f.quality.events[2].application)),
  pausedSamplePreexistingStall: (f) =>
    (f.fault.pausedSample.value.decoderCadence.progress.ageMs = 3000),
  wrongAction: (f) => (f.quality.events[2].action.kind = 'decrease'),
  wrongRecommendation: (f) => (f.quality.events[1].action.bitRate = 500000),
  wrongExpiry: (f) => (f.quality.events[2].action.validUntil += 1),
  jointlyWrongExpiry: (f) =>
    f.quality.events.filter((e) => e.action).forEach((e) => (e.action.validUntil += 1)),
  lateAdmission: (f) => (f.quality.events[2].application.admittedAt = 129.81),
  beforeDecision: (f) => (f.quality.events[2].application.admittedAt = 129.61),
  wrongAttempt: (f) => (f.quality.events[2].application.attemptID = id(90)),
  wrongSequence: (f) => (f.quality.events[2].application.windowSequence = '2'),
  wrongFromRevision: (f) => (f.quality.events[2].application.fromRevision = '1'),
  wrongRevision: (f) => (f.quality.events[2].revision = '2'),
  sameConfiguration: (f) => (f.quality.events[2].receipt.configurationID = id(2)),
  sameEncoder: (f) => (f.quality.events[2].receipt.encoderSessionID = id(3)),
  wrongNativeReceipt: (f) => (f.quality.events[2].profileReceipt.width = 960),
  wrongOldReceipt: (f) => (f.quality.events[0].receipt.configurationID = id(90)),
  missingFormat: (f) => delete f.format,
  missingRawFrames: (f) => delete f.format.compressedFrames,
  extraApplication: (f) => f.quality.events.splice(3, 0, structuredClone(f.quality.events[2])),
  oldReceiptPostAck: (f) =>
    (f.quality.events[3].receipt = structuredClone(f.quality.events[0].receipt)),
  oldDecisionPostAck: (f) => f.quality.events.splice(3, 0, structuredClone(f.quality.events[1])),
  decisionAfterAck: (f) => (f.quality.events[1].evaluatedAt = 130.05),
  lateCompletion: (f) => (f.quality.events[2].acknowledgedAt = 132),
  wideCompletionDeadline: (f) => (f.quality.events[2].application.completionDeadline = 132),
  enabledWatchdog: (f) => (f.quality.decoderStallEnabled = true),
  falseHealthyCredit: (f) => (f.quality.events[1].state = 'healthy'),
  failedWrite: (f) => (f.quality.events[2].kind = 'failed'),
  skippedWrite: (f) => (f.quality.events[2].kind = 'skipped'),
  noBaseline: (f) => (f.audit.rows = f.audit.rows.slice(-1)),
  insufficientOneSecondBaseline: (f) =>
    f.audit.rows.splice(
      f.audit.rows.findIndex((r) => r.end - r.start === 1),
      1,
    ),
  insufficientTwoSecondBaseline: (f) =>
    f.audit.rows.splice(
      f.audit.rows.findIndex((r) => r.end - r.start === 2),
      1,
    ),
  noBeforePauseSample: (f) => delete f.fault.beforePauseSample,
  alreadyStalledBeforePause: (f) =>
    (f.fault.beforePauseSample.value.decoderCadence.progress.stalled = true),
  staleBeforePauseProgress: (f) =>
    (f.fault.beforePauseSample.value.decoderCadence.progress.ageMs = 131),
  futureBeforePausePTS: (f) =>
    (f.fault.beforePauseSample.value.decoderCadence.progress.lastFreshPTS += 3000),
  differentBeforePauseScope: (f) =>
    (f.fault.beforePauseSample.value.decoderCadence.scopeID = id(90)),
  differentBeforePauseOwner: (f) => (f.fault.beforePauseSample.value.context.workerId = 'other'),
  beforeSampleAfterPause: (f) => (f.fault.beforePauseSample.receivedAt = 100001),
  beforeSampleExpiredAtPause: (f) =>
    (f.fault.beforePauseSample.value.expiresAt = '2040-01-01T00:00:01.100Z'),
  noPausedSample: (f) => delete f.fault.pausedSample,
  pausedSampleBeforePause: (f) => (f.fault.pausedSample.requestStartedAt = 99999),
  pausedSampleAfterResume: (f) => (f.fault.pausedSample.receivedAt = 101901),
  pausedSampleTimeReversal: (f) => (f.fault.pausedSample.receivedAt = 101799),
  pausedSampleWrongContext: (f) => (f.fault.pausedSample.value.context.workerId = 'unrelated'),
  pausedSampleWrongPTS: (f) =>
    (f.fault.pausedSample.value.decoderCadence.progress.lastFreshPTS += 3000),
  pausedSampleWrongScope: (f) => (f.fault.pausedSample.value.decoderCadence.scopeID = id(90)),
  pausedSampleStale: (f) => (f.fault.pausedSample.value.decoderCadenceAgeUpperBoundMs = 201),
  pausedSampleNegativeAge: (f) => (f.fault.pausedSample.value.decoderCadenceAgeUpperBoundMs = -1),
  pausedSampleNoStall: (f) => (f.fault.pausedSample.value.decoderCadence.progress.stalled = false),
  pausedSampleTooYoung: (f) => (f.fault.pausedSample.value.decoderCadence.progress.ageMs = 999),
  pausedSampleInvalid: (f) => (f.fault.pausedSample.value.decoderCadence.invalidReason = 'reset'),
  pausedSampleEnded: (f) => (f.fault.pausedSample.value.decoderCadence.ended = true),
  pausedSampleExpired: (f) => (f.fault.pausedSample.value.expiresAt = '2040-01-01T00:00:01.050Z'),
  pausedSampleInvalidDate: (f) => (f.fault.pausedSample.value.serverTime = 'invalid'),
  noFaultAssociation: (f) =>
    (f.reports.rows.find(
      (r) => r.observedStall,
    ).response.status.observation.decoderCadence.progress.lastFreshPTS = 9999999),
}))
  test(`reset rejects ${name}`, () => {
    assert.equal(typeof qualifyReset, 'function');
    const f = profileResetFixture();
    damage(f);
    assert.throws(() => qualifyReset(f));
  });

test('permits a post-reset minimum hold only with current acknowledged native evidence', () => {
  const f = profileResetFixture(),
    write = f.quality.events[2];
  const row = structuredClone(f.audit.rows.at(-1)),
    report = structuredClone(f.reports.rows.at(-1));
  const shiftPTS = (pts) => ({ ...pts, value: String(BigInt(pts.value) + 1200n) });
  const configuration = {
    id: write.receipt.configurationID,
    encoderSessionID: write.receipt.encoderSessionID,
    bitRate: 350000,
  };
  const receipt = {
    generation: '7',
    configuration,
    acceptedAt: write.receipt.acceptedAt,
    lastSubmittedPTS: write.receipt.lastSubmittedPTS,
  };
  Object.assign(row, {
    phase: 2,
    start: 147,
    end: 148,
    evaluatedAt: 149.6,
    appliedRevision: '1',
    profileID: '240p30',
    videoBitrate: 350000,
    acknowledgedAt: write.acknowledgedAt,
    receipt,
    deliveryReceiptID: id(70),
  });
  row.history.scope.appliedProfileRevision =
    row.clockScope.appliedProfileRevision =
    row.diagnostics.ingressScope.appliedProfileRevision =
      '1';
  row.diagnostics.receipt = structuredClone(receipt);
  for (const frame of [...row.history.capture, ...row.history.encoded]) {
    frame.sourcePTS = shiftPTS(frame.sourcePTS);
    frame.observedAt += 20;
    if (frame.encoding) {
      Object.assign(frame.encoding, {
        configuration: structuredClone(configuration),
        encoderSessionID: configuration.encoderSessionID,
        submittedAt: frame.encoding.submittedAt + 20,
        completedAt: frame.encoding.completedAt + 20,
      });
    }
  }
  row.frames.forEach((frame) => {
    frame.pts = String(BigInt(frame.pts) + 1800000n);
    frame.sourcePTS = shiftPTS(frame.sourcePTS);
    frame.capturedAt += 20;
  });
  row.anchorSourcePTS = shiftPTS(row.anchorSourcePTS);
  report.receivedUptime += 20;
  report.evaluatedUptime += 20;
  report.deliveryReceiptID = id(70);
  const packet = report.response.status.observation.decoderDelivery;
  packet.sampledAtMs += 20000;
  packet.coverageAtMs += 20000;
  packet.afterOrdinal += 600;
  packet.lastOrdinal += 600;
  packet.arrivals.forEach((r) => {
    r[0] += 1800000;
    r[1] += 20000;
  });
  report.response.status.observation.decoderCadence.progress.lastFreshPTS += 1800000;
  row.timeline = deliverySnapshot(packet);
  f.audit.rows.push(row);
  f.reports.rows.push(report);
  const decision = {
    ...structuredClone(write),
    kind: 'deliveryFailure',
    evaluatedAt: 149.62,
    state: 'degraded',
    reasons: ['freshFrameFloor', 'minimumProfileInsufficient'],
    deliveryFailure: {
      ...structuredClone(failure(f)),
      sequence: '2',
      revision: '1',
      classifiedAt: row.evaluatedAt,
      start: row.start,
      end: row.end,
      deliveryReceiptID: row.deliveryReceiptID,
      observedAtLowerBound: 149.55,
    },
  };
  delete decision.action;
  f.quality.events.splice(3, 0, decision);
  assert.equal(qualifyReset(f).deadlineFailureDecisionCount, 2);
  decision.action = structuredClone(write.action);
  assert.throws(() => qualifyReset(f), /Minimum hold/);
});
for (const kind of ['evaluated', 'transition'])
  test(`reset rejects fictitious legacy ${kind} credit`, () => {
    const f = profileResetFixture();
    f.quality.events.splice(1, 0, {
      ...structuredClone(f.quality.events[0]),
      kind,
      state: 'degraded',
      evaluatedAt: 110,
      window: { sequence: '1', revision: '0' },
    });
    f.quality.events[2].deliveryFailure.sequence = '2';
    f.quality.events[3].application.windowSequence = '2';
    f.quality.events.at(-1).application.windowSequence = '2';
    assert.throws(() => qualifyReset(f), /Unknown event/);
  });
