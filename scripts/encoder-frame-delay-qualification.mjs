import assert from 'node:assert/strict';
import { fixtureFrameID } from './video-observation-qualification.mjs';

const names = ['defaultIdle', 'limitedIdle', 'limitedContinuous', 'defaultRepeat'];
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
function identity(value, label) {
  assert.ok(
    typeof value === 'string' && /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value),
    `${label} must be a UUID`,
  );
  return value.toLowerCase();
}
function integer(value, min, max, label) {
  assert.ok(Number.isSafeInteger(value) && value >= min && value <= max, `${label} out of bounds`);
}

/** Specific simulator reproduction only. Actual pre-mux video cost and native
 * property readback do not establish uplink capacity or physical-device safety. */
export function qualifyEncoderFrameDelay(report) {
  assert.ok(report && typeof report === 'object', 'Missing frame delay report');
  assert.equal(report.formatVersion, 1);
  assert.equal(report.experiment, 'candidate-frame-delay');
  assert.equal(report.platform, 'iOS Simulator');
  assert.equal(report.workload, 'motion-blocks16');
  assert.equal(report.inputWidth, 1920);
  assert.equal(report.inputHeight, 1080);
  assert.equal(report.profile, '360p30');
  assert.equal(report.firstSourceFrame, 758);
  assert.ok(
    Array.isArray(report.runs) && report.runs.length === names.length,
    'Expected exactly four cases',
  );
  const ids = new Set(),
    sessions = new Set();
  let previousEnd = 0;
  const cases = report.runs.map((run, index) => {
    const name = names[index],
      limited = name.startsWith('limited'),
      continuous = name === 'limitedContinuous';
    const count = continuous ? 121 : 4;
    assert.equal(run.name, name, 'Cases must be in experimental order');
    const id = identity(run.id, `${name} identity`);
    assert.equal(run.requestedMaxFrameDelayCount, limited ? 3 : null);
    assert.equal(
      run.propertySetStatus,
      limited ? 0 : null,
      limited
        ? `${name} MaxFrameDelayCount set failed (OSStatus ${run.propertySetStatus})`
        : 'Default controls must not set MaxFrameDelayCount',
    );
    integer(run.propertyCopyStatus, -(2 ** 31), 2 ** 31 - 1, `${name} native copy status`);
    if (run.propertyCopyStatus === 0)
      integer(run.propertyValue, -1, Number.MAX_SAFE_INTEGER, `${name} property readback`);
    else
      assert.equal(
        run.propertyValue,
        null,
        'Unavailable native property cannot have a readback value',
      );
    if (limited) {
      assert.equal(
        run.propertyCopyStatus,
        0,
        `${name} MaxFrameDelayCount copy failed (OSStatus ${run.propertyCopyStatus})`,
      );
      assert.equal(run.propertyValue, 3, 'Native MaxFrameDelayCount readback must be 3');
    }
    // Property preparation may fail before a session can submit any frame.
    // Preserve that native cause instead of masking it with absent identity.
    const session = identity(run.encoderSessionID, `${name} session`);
    assert.ok(
      !ids.has(id) && !sessions.has(session),
      'Each case must use fresh measurement and native session identities',
    );
    ids.add(id);
    sessions.add(session);
    assert.deepEqual(run.requested, requested);
    assert.equal(run.outcome, 'completed');
    assert.equal(run.failure, null);
    assert.equal(run.nativeFailure, null);
    assert.equal(run.acceptedInputCount, count);
    assert.equal(run.outputCount, count);
    assert.ok(
      Array.isArray(run.inputs) && run.inputs.length === count,
      'Every admitted source must be recorded',
    );
    assert.ok(
      Array.isArray(run.frames) && run.frames.length === count,
      'Every accepted input must have one output',
    );
    for (const key of ['startedAt', 'propertyObservedAt', 'beforeFinishAt', 'endedAt'])
      time(run[key], `${name} ${key}`);
    assert.ok(
      run.startedAt >= previousEnd &&
        run.beforeFinishAt > run.startedAt &&
        run.endedAt >= run.beforeFinishAt,
      'Runs must have ordered, nonoverlapping joined lifetimes',
    );
    previousEnd = run.endedAt;
    assert.ok(
      run.beforeFinishAt - run.startedAt < 8,
      'SDK admission must close before eight seconds; joined native completion may be later',
    );
    assert.ok(
      run.propertyObservedAt >= run.startedAt &&
        run.propertyObservedAt <= run.frames[0].submittedAt,
      'Native property must be observed before first submission',
    );
    integer(run.beforeFinishOutputs, 0, count, `${name} pre-finish output count`);
    let observedBeforeFinish = 0,
      payloadBytes = 0,
      maximumFrameBytes = 0;
    let maximumCallbackLatencySeconds = 0,
      maximumOutputLatencySeconds = 0,
      maximumUnresolvedInputs = 0;
    let outstanding = [],
      previousInput,
      previousFrame;
    for (let i = 0; i < count; i++) {
      const input = run.inputs[i],
        frame = run.frames[i];
      assert.equal(
        input.frame,
        758 + i,
        'Admitted fixture identities must be complete and ordered',
      );
      assert.equal(input.accepted, true);
      time(input.offeredAt, `${name} offeredAt`);
      assert.ok(
        input.offeredAt >= run.startedAt &&
          input.offeredAt < run.startedAt + 8 &&
          input.offeredAt <= run.beforeFinishAt,
        'Input must belong to the open SDK admission window',
      );
      assert.equal(fixtureFrameID(frame.sourcePTS), input.frame);
      assert.equal(fixtureFrameID(frame.outputPTS), input.frame);
      assert.equal(frame.encoderSessionID, run.encoderSessionID);
      assert.equal(frame.width, 640);
      assert.equal(frame.height, 360);
      integer(frame.byteCount, 1, 2 * 1024 * 1024, `${name} compressed frame bytes`);
      assert.equal(typeof frame.isSync, 'boolean');
      if (i === 0) assert.equal(frame.isSync, true, 'Cost must include initial keyframe');
      for (const key of ['submittedAt', 'completedAt', 'dequeuedAt', 'observedAt'])
        time(frame[key], `${name} ${key}`);
      assert.ok(
        input.offeredAt <= frame.submittedAt &&
          frame.submittedAt <= frame.completedAt &&
          frame.completedAt <= frame.dequeuedAt &&
          frame.dequeuedAt <= frame.observedAt &&
          frame.observedAt <= run.endedAt,
        'Native submission/callback/dequeue/observation must reconcile within joined lifetime',
      );
      if (previousInput)
        assert.ok(input.offeredAt > previousInput.offeredAt, 'Offers must be ordered');
      if (previousFrame)
        assert.ok(
          frame.submittedAt > previousFrame.submittedAt &&
            frame.dequeuedAt >= previousFrame.dequeuedAt &&
            frame.observedAt >= previousFrame.observedAt,
          'No-reordering native output must remain ordered',
        );
      // Native submissions are known to be retained until SDK dequeue. Offers
      // are timestamped before calling the SDK, not at atomic admission, so this
      // is an observed native lower bound, not a complete raw-queue receipt.
      outstanding = outstanding.filter((end) => end > frame.submittedAt);
      outstanding.push(frame.dequeuedAt);
      maximumUnresolvedInputs = Math.max(maximumUnresolvedInputs, outstanding.length);
      assert.ok(maximumUnresolvedInputs <= 4, 'Impossible more than four unresolved inputs');
      if (frame.observedAt <= run.beforeFinishAt) observedBeforeFinish++;
      if (!limited)
        assert.ok(
          frame.completedAt >= run.beforeFinishAt,
          'Default native callbacks must all wait for drain',
        );
      payloadBytes += frame.byteCount;
      maximumFrameBytes = Math.max(maximumFrameBytes, frame.byteCount);
      maximumCallbackLatencySeconds = Math.max(
        maximumCallbackLatencySeconds,
        frame.completedAt - frame.submittedAt,
      );
      maximumOutputLatencySeconds = Math.max(
        maximumOutputLatencySeconds,
        frame.observedAt - input.offeredAt,
      );
      previousInput = input;
      previousFrame = frame;
    }
    assert.equal(
      run.beforeFinishOutputs,
      observedBeforeFinish,
      'Atomic pre-finish snapshot must match observer timestamps',
    );
    if (!limited)
      assert.equal(
        observedBeforeFinish,
        0,
        'Default controls must retain all four frames until drain',
      );
    else assert.ok(observedBeforeFinish >= 1, 'Verified limit3 must produce output before drain');
    const admissionSeconds = run.inputs.at(-1).offeredAt - run.inputs[0].offeredAt;
    const submissionSeconds = run.frames.at(-1).submittedAt - run.frames[0].submittedAt;
    const joinedSeconds = run.endedAt - run.startedAt;
    const sourceSpanSeconds = (count - 1) / 30;
    if (continuous) {
      assert.ok(
        admissionSeconds > 0 &&
          admissionSeconds <= 5 &&
          submissionSeconds > 0 &&
          submissionSeconds <= 5 &&
          joinedSeconds <= 5,
        'Continuous measurement must fully reconcile at least24fps over the four-second source window',
      );
    } else {
      assert.ok(
        run.beforeFinishAt - run.frames.at(-1).submittedAt >= 1 - 1e-9,
        'Idle cases must demonstrate one second of native idle after the last submission',
      );
    }
    return {
      name,
      id: run.id,
      encoderSessionID: run.encoderSessionID,
      inputCount: count,
      outputCount: count,
      propertyAvailable: run.propertyCopyStatus === 0,
      propertyCopyStatus: run.propertyCopyStatus,
      propertyValue: run.propertyValue,
      beforeFinishOutputs: observedBeforeFinish,
      sourceSpanSeconds,
      admissionSeconds,
      submissionSeconds,
      joinedSeconds,
      payloadBytes,
      payloadBitsPerSecond: (payloadBytes * 8) / Math.min(sourceSpanSeconds, joinedSeconds),
      maximumFrameBytes,
      maximumUnresolvedInputs,
      maximumCallbackLatencySeconds,
      maximumOutputLatencySeconds,
    };
  });
  return {
    experiment: 'candidate-frame-delay',
    bufferingHypothesisSupported: true,
    cases,
    interpretation:
      'Both default controls retained native callbacks until drain; verified MaxFrameDelayCount 3 released output within the four-input budget and completed the continuous window in this simulator. This supports native buffering as the observed cause; it does not establish network capacity or physical-device support.',
  };
}
