import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';

const MiB = 1024 * 1024;
const cases = [
  ['default4', 4],
  ['default8', 8],
  ['default16', 16],
  ['default20', 20],
  ['defaultRepeat4', 4],
];
const requested = {
  width: 640,
  height: 360,
  bitRate: 600000,
  profileLevel: 'H264_High_AutoLevel',
  expectedFrameRate: 30,
  maxKeyFrameIntervalDuration: 2,
  allowFrameReordering: false,
};
function time(value, label) {
  assert.ok(
    typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e12,
    `${label} must be finite nonnegative uptime`,
  );
}
function integer(value, min, max, label) {
  assert.ok(Number.isSafeInteger(value) && value >= min && value <= max, `${label} out of bounds`);
}
function identity(value, label) {
  assert.ok(
    typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value),
    `${label} must be a UUID`,
  );
  return value.toLowerCase();
}

/** Diagnostic only: raw payload accounting excludes opaque native allocation.
 * An observed output threshold is specific to this pacing and simulator. */
export function qualifyEncoderBufferDepth(report) {
  assert.ok(report && typeof report === 'object', 'Missing buffer depth report');
  assert.equal(report.formatVersion, 1);
  assert.equal(report.experiment, 'candidate-buffer-depth');
  assert.equal(report.platform, 'iOS Simulator');
  assert.equal(report.workload, 'motion-blocks16');
  assert.equal(report.inputWidth, 1920);
  assert.equal(report.inputHeight, 1080);
  assert.equal(report.profile, '360p30');
  assert.equal(report.firstSourceFrame, 758);
  assert.equal(report.rawByteBudget, 64 * MiB);
  assert.equal(report.allocationReservation, 4 * MiB);
  assert.ok(
    Array.isArray(report.runs) && report.runs.length === cases.length,
    'Expected five ordered cases',
  );
  const ids = new Set(),
    sessions = new Set();
  let previousEnd = 0;
  const results = report.runs.map((run, index) => {
    const [name, count] = cases[index];
    assert.equal(run.name, name);
    assert.equal(run.count, count);
    const id = identity(run.id, `${name} identity`);
    assert.ok(!ids.has(id), 'Case identity must be fresh');
    ids.add(id);
    assert.deepEqual(run.requested, requested);
    assert.ok(
      Array.isArray(run.errors) && run.errors.length === 0,
      'Native diagnostic errors must be empty',
    );
    assert.equal(run.nativeFailure, null);
    assert.ok(
      Array.isArray(run.inputs) && run.inputs.length === count,
      'Every intended source input must be recorded',
    );
    assert.ok(
      Array.isArray(run.frames) && run.frames.length === count,
      'Every source must join one callback and compressed output',
    );
    for (const key of ['startedAt', 'beforeFinishAt', 'endedAt']) time(run[key], `${name} ${key}`);
    assert.ok(
      run.startedAt >= previousEnd &&
        run.beforeFinishAt > run.startedAt &&
        run.endedAt >= run.beforeFinishAt,
      'Cases require ordered, nonoverlapping joined lifetimes',
    );
    assert.ok(
      run.beforeFinishAt - run.startedAt < 8,
      'SDK admission must close before eight seconds',
    );
    previousEnd = run.endedAt;
    integer(run.rawBytesAllocated, 1, report.rawByteBudget, `${name} cumulative raw bytes`);
    integer(run.beforeFinishOutputs, 0, count, `${name} before-finish outputs`);
    const sessionText = run.inputs[0].encoderSessionID,
      session = identity(sessionText, `${name} native session`);
    assert.ok(!sessions.has(session), 'Native session must be unique per case');
    sessions.add(session);
    let totalRawBytes = 0,
      payloadBytes = 0,
      beforeFinishOutputs = 0;
    const events = [];
    for (let i = 0; i < count; i++) {
      const input = run.inputs[i],
        frame = run.frames[i];
      assert.equal(input.frame, 758 + i, 'Source input IDs must be complete and ordered');
      assert.equal(frame.frame, input.frame, 'Native output identity must match input');
      assert.equal(fixtureFrameID(input.sourcePTS), input.frame);
      assert.equal(fixtureFrameID(frame.sourcePTS), input.frame);
      assert.equal(fixtureFrameID(frame.outputPTS), input.frame);
      assert.equal(input.encoderSessionID, sessionText);
      assert.equal(frame.encoderSessionID, sessionText);
      integer(input.rawBytes, 1, report.allocationReservation, `${name} input payload`);
      assert.ok(
        totalRawBytes + report.allocationReservation <= report.rawByteBudget,
        'Each allocation must reserve four MiB against cumulative raw budget without reclaim',
      );
      totalRawBytes += input.rawBytes;
      assert.ok(totalRawBytes <= report.rawByteBudget, 'Cumulative raw payload exceeds budget');
      assert.equal(frame.width, 640);
      assert.equal(frame.height, 360);
      assert.equal(typeof frame.isSync, 'boolean');
      if (i === 0) assert.equal(frame.isSync, true, 'Initial keyframe must be included');
      integer(frame.byteCount, 1, 2 * MiB, `${name} compressed payload`);
      for (const key of ['offeredAt', 'returnedAt']) time(input[key], `${name} ${key}`);
      for (const key of ['submittedAt', 'completedAt', 'dequeuedAt'])
        time(frame[key], `${name} ${key}`);
      assert.ok(
        run.startedAt <= input.offeredAt &&
          input.offeredAt <= frame.submittedAt &&
          frame.submittedAt <= input.returnedAt &&
          input.returnedAt <= run.beforeFinishAt,
        'Native submission must be bracketed by its synchronous append within admission',
      );
      assert.ok(
        frame.submittedAt <= frame.completedAt &&
          frame.completedAt <= frame.dequeuedAt &&
          frame.dequeuedAt <= run.endedAt,
        'Callback and output must reconcile within joined lifetime',
      );
      if (i > 0)
        assert.ok(
          input.offeredAt >= run.inputs[i - 1].returnedAt,
          'Serial append cannot overlap previous append',
        );
      if (i > 0)
        assert.ok(
          input.offeredAt - run.inputs[i - 1].returnedAt >= 1 / 60 - 1e-6,
          'Controlled pacing requires at least 1/60 second after the prior append returns',
        );
      if (frame.dequeuedAt <= run.beforeFinishAt) beforeFinishOutputs++;
      payloadBytes += frame.byteCount;
      // Empty intervals retain no unresolved work. For nonempty intervals, the
      // chronological sweep releases before admitting at an identical timestamp.
      if (frame.dequeuedAt > frame.submittedAt) {
        events.push({ at: frame.submittedAt, delta: 1, bytes: input.rawBytes });
        events.push({ at: frame.dequeuedAt, delta: -1, bytes: -input.rawBytes });
      }
    }
    assert.equal(
      run.rawBytesAllocated,
      totalRawBytes,
      'Cumulative raw payload must reconcile exactly',
    );
    assert.equal(
      run.beforeFinishOutputs,
      beforeFinishOutputs,
      'Atomic output snapshot must match dequeue timestamps',
    );
    assert.ok(
      run.beforeFinishAt - run.inputs.at(-1).returnedAt >= 1 - 1e-9,
      'Idle checkpoint must follow last native append return by at least one second',
    );
    events.sort((a, b) => a.at - b.at || a.delta - b.delta);
    let unresolved = 0,
      unresolvedBytes = 0,
      peakUnresolvedInputs = 0,
      peakUnresolvedRawBytes = 0;
    for (const event of events) {
      unresolved += event.delta;
      unresolvedBytes += event.bytes;
      assert.ok(
        unresolved >= 0 && unresolvedBytes >= 0,
        'Impossible negative unresolved occupancy',
      );
      peakUnresolvedInputs = Math.max(peakUnresolvedInputs, unresolved);
      peakUnresolvedRawBytes = Math.max(peakUnresolvedRawBytes, unresolvedBytes);
    }
    assert.equal(unresolved, 0);
    assert.equal(unresolvedBytes, 0);
    const earliestCompletedAt = Math.min(...run.frames.map((frame) => frame.completedAt));
    return {
      name,
      count,
      inputCount: count,
      outputCount: count,
      totalRawBytes,
      beforeFinishOutputs,
      firstOutputAfterInputCount: run.frames.filter(
        (frame) => frame.submittedAt <= earliestCompletedAt,
      ).length,
      peakUnresolvedInputs,
      peakUnresolvedRawBytes,
      payloadBytes,
      sourceSpanSeconds: (count - 1) / 30,
      admissionSeconds: run.inputs.at(-1).returnedAt - run.inputs[0].offeredAt,
      joinedSeconds: run.endedAt - run.startedAt,
    };
  });
  const smallest = results
    .filter((run) => run.beforeFinishOutputs > 0)
    .sort((a, b) => a.count - b.count)[0];
  return {
    experiment: 'candidate-buffer-depth',
    remedyQualified: false,
    smallestCaseWithOutputBeforeFinish: smallest?.name ?? null,
    cases: results,
    interpretation:
      'Observed startup output threshold under this simulator pacing only; unresolved raw payload excludes native opaque allocations. Neither a production resource remedy nor network capacity is qualified.',
  };
}
