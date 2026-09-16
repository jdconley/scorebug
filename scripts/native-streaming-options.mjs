import assert from 'node:assert/strict';

/** Called after continuity qualification of the known 30 fps source fixture. */
export function qualifyNativeStreamingHold({ holdSeconds, savedFrames }) {
  assert.ok(
    Number.isSafeInteger(holdSeconds) && holdSeconds >= 12 && holdSeconds <= 600,
    'Invalid hold duration',
  );
  assert.ok(Number.isSafeInteger(savedFrames) && savedFrames > 0, 'Invalid saved frame count');
  const sourceDurationSeconds = savedFrames / 30;
  assert.ok(
    sourceDurationSeconds >= holdSeconds,
    'Saved live coverage is shorter than the requested hold',
  );
  return sourceDurationSeconds;
}

/** Validated before creating native test resources; production has no hold override. */
export function nativeStreamingOptions({ streaming, environment }) {
  const raw = environment.SCOREBUG_TEST_STREAM_HOLD_SECONDS;
  if (raw === undefined) return { holdSeconds: 12, completedWindowLimit: 8, extended: false };
  assert.ok(
    streaming && environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1',
    'Extended hold requires native streaming and the direct RTMP recorder',
  );
  const holdSeconds = Number(raw);
  assert.ok(
    typeof raw === 'string' &&
      /^(0|[1-9]\d*)$/.test(raw) &&
      Number.isSafeInteger(holdSeconds) &&
      holdSeconds >= 12 &&
      holdSeconds <= 600,
    'Native streaming hold must be a canonical integer from 12 through 600 seconds',
  );
  return { holdSeconds, completedWindowLimit: holdSeconds > 180 ? 128 : 64, extended: true };
}

export function nativeStreamingTestBudget(holdSeconds) {
  assert.ok(
    Number.isSafeInteger(holdSeconds) && holdSeconds >= 12 && holdSeconds <= 600,
    'Invalid hold duration',
  );
  return {
    workflowTimeoutMs: 600_000 + Math.max(0, holdSeconds - 180) * 1000,
    testExecutionAllowanceSeconds: holdSeconds > 180 ? holdSeconds + 180 : null,
  };
}

/** Explicit test workload; reject bad flags before any native resources exist. */
export function nativeFixtureWorkload({ streaming, environment }) {
  const raw = environment.SCOREBUG_TEST_MOTION_FIXTURE;
  if (raw === undefined) return 'barcode';
  assert.ok(
    raw === '1' || raw === 'blocks16',
    'Motion fixture requires exact opt-in 1 or blocks16',
  );
  assert.ok(
    streaming && environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1',
    'Motion fixture requires native streaming and the direct RTMP recorder',
  );
  return raw === 'blocks16' ? 'motion-blocks16' : 'motion';
}

/** Verification strength is explicit and validated before creating fixture resources. */
export function nativeQualityOptions({ environment, requireProcessing, holdSeconds }) {
  const quality = environment.SCOREBUG_TEST_NATIVE_QUALITY;
  const confirmation = environment.SCOREBUG_TEST_NATIVE_CONFIRMATION;
  assert.ok(
    quality === undefined ||
      (quality === '1' &&
        requireProcessing &&
        holdSeconds >= 90 &&
        environment.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1'),
    'Native quality requires exact opt-in 1, processing/publication evidence, direct recorder and at least90s hold',
  );
  assert.ok(
    confirmation === undefined || (confirmation === '1' && quality === '1'),
    'Native confirmation requires exact opt-in 1 and native quality qualification',
  );
  return { requireQuality: quality === '1', requireConfirmation: confirmation === '1' };
}
