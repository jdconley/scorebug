import assert from 'node:assert/strict';
import { replayNativeLocalPressure } from './native-quality-pressure.mjs';
const time = (n) => assert(Number.isFinite(n) && n >= 0 && n <= 1e12, 'Invalid decrease time');
const sequence = (n) => {
  assert(typeof n === 'string' && /^[1-9][0-9]*$/.test(n));
  const v = BigInt(n);
  assert(v <= BigInt(Number.MAX_SAFE_INTEGER));
  return v;
};
/** Local pressure/application correspondence only. Confirmation, fault causality,
 * receiver recovery and later fresh admission require complete route replay. */
export function qualifyCapacityPressureDecrease({ quality, snapshot }) {
  assert.equal(quality.formatVersion, 5);
  assert.equal(quality.transportPolicy, 'recovery-budget-v1');
  assert.equal(quality.overflow, false);
  assert.equal(quality.measuredSourceEvaluationEnabled, true);
  const events = quality.events;
  assert(Array.isArray(events) && events.length <= 512);
  for (let i = 0; i < events.length; i++) {
    time(events[i].at);
    if (i) assert(events[i].at >= events[i - 1].at, 'Quality clock regressed');
  }
  const writes = events.filter((e) => e.kind === 'applied');
  assert.equal(writes.length, 2);
  const [trial, applied] = writes;
  assert.equal(trial.action.kind, 'trial');
  assert.equal(trial.profileID, '360p30');
  assert.equal(trial.revision, '1');
  const appliedIndex = events.indexOf(applied),
    pressureIndex = appliedIndex - 1,
    row = events[pressureIndex],
    previous = events[pressureIndex - 1];
  assert(row && previous && pressureIndex > events.indexOf(trial), 'Missing prior local pressure');
  assert.equal(row.kind, 'localPressure');
  assert.equal(
    previous.kind,
    'evaluated',
    'Pressure must follow the current source policy watermark',
  );
  for (const e of [row, previous]) {
    assert.equal(e.closed, false);
    assert.equal(e.revision, '1');
    assert.equal(e.profileID, '360p30');
    assert.deepEqual(e.receipt, trial.receipt);
    assert.equal(e.acknowledgedAt, trial.acknowledgedAt);
    assert.deepEqual(e.profileReceipt, trial.profileReceipt);
    assert.deepEqual(e.application, trial.application);
    assert.equal(e.window.revision, '1');
    for (const n of [e.window.start, e.window.end, e.evaluatedAt, e.acknowledgedAt]) time(n);
    assert(e.window.start >= e.acknowledgedAt && e.window.end > e.window.start);
    assert(
      e.evaluatedAt >= e.window.end && e.evaluatedAt <= e.at && e.evaluatedAt - e.window.end <= 2,
      'Stale/future pressure decision',
    );
  }
  assert.equal(row.action, undefined, 'Local observation cannot fabricate an action');
  assert.equal(row.state, 'unknown');
  assert.equal(
    sequence(row.window.sequence),
    sequence(previous.window.sequence) + 1n,
    'Pressure must consume next policy sequence',
  );
  assert(row.window.start >= previous.window.end, 'Overlapping pressure watermark');
  assert(row.evaluatedAt >= previous.evaluatedAt);
  const pressure = replayNativeLocalPressure(row, snapshot, {
    after: previous.window.end,
    duration: 0.25,
    transportPolicy: 'recovery-budget-v1',
  });
  assert.equal(
    pressure.transport,
    'elevated',
    'Capacity decrease needs observed transport pressure',
  );
  const w = row.window,
    reasons = [
      ...(w.start !== previous.window.end ? ['telemetryGap'] : []),
      'unknownConnectivity',
      'missingCapture',
      'missingEncoded',
      'missingReceiver',
      'missingSourceLoss',
      ...(w.queue === null ? ['missingQueue'] : []),
      'missingCapacity',
      'unknownPressure',
      ...(w.queue !== null && w.queue >= 0.75 ? ['queuePressure'] : []),
      ...(w.thermal === 'elevated' ? ['thermalPressure'] : []),
      'transportPressure',
    ];
  assert.deepEqual(row.reasons, reasons, 'Decrease reasons disagree with raw local pressure');
  const a = applied.action,
    app = applied.application;
  assert.equal(applied.closed, false);
  assert.equal(applied.revision, '2');
  assert.equal(applied.profileID, '240p30');
  assert.deepEqual(a, {
    kind: 'decrease',
    profileID: '240p30',
    bitRate: 350000,
    fromRevision: '1',
    candidateID: null,
    validUntil: w.end + 2,
  });
  assert.equal(app.fromRevision, '1');
  assert.equal(app.candidateID, null);
  assert.equal(app.windowSequence, w.sequence);
  assert.equal(app.attemptID.toLowerCase(), snapshot.scope.publishingAttemptID.toLowerCase());
  for (const n of [app.admittedAt, app.completionDeadline, applied.acknowledgedAt]) time(n);
  assert(
    app.admittedAt >= row.at && app.admittedAt <= a.validUntil,
    'Decrease not admitted from fresh pressure',
  );
  assert(Math.abs(app.completionDeadline - app.admittedAt - 2) < 1e-6);
  assert(
    applied.acknowledgedAt >= app.admittedAt &&
      applied.acknowledgedAt <= app.completionDeadline &&
      applied.at >= applied.acknowledgedAt,
  );
  return {
    pressureEventIndex: pressureIndex,
    previousWindowEventIndex: pressureIndex - 1,
    appliedEventIndex: appliedIndex,
    windowSequence: w.sequence,
    windowStart: w.start,
    windowEnd: w.end,
    applicationID: app.id,
    admittedAt: app.admittedAt,
    pressure,
    recoveryQualified: false,
    confirmationQualified: false,
  };
}
