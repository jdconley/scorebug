import assert from 'node:assert/strict';

export function nativeCapacityDiagnostics({ args, capacityRecovery, ownedMeasurement }) {
  assert(Array.isArray(args) && args.every((arg) => typeof arg === 'string'));
  assert.equal(typeof capacityRecovery, 'boolean');
  const count = args.filter((arg) => arg === '--capacity-diagnostics').length;
  assert(count <= 1, 'Duplicate capacity diagnostics flag');
  assert(!count || capacityRecovery, 'Capacity diagnostics require the complete capacity route');
  if (ownedMeasurement !== undefined) {
    assert.equal(ownedMeasurement, '1', 'Owned diagnostics require exact opt-in 1');
    assert.equal(count, 1, 'Owned recovery runner awaits its whole-history qualifier');
  }
  return count === 1;
}

/** Join raw diagnostic collection even when the UI workflow fails. This route
 * never grants a passing verdict, and secondary failures cannot mask the UI error. */
export async function runCapacityDiagnosticWorkflow({
  workflow,
  collect,
  save,
  onSecondaryFailure,
}) {
  assert([workflow, collect, save].every((operation) => typeof operation === 'function'));
  assert(onSecondaryFailure === undefined || typeof onSecondaryFailure === 'function');
  let workflowFailed = false,
    workflowError;
  try {
    await workflow();
  } catch (error) {
    workflowFailed = true;
    workflowError = error;
  }
  try {
    await save(await collect());
  } catch (error) {
    if (!workflowFailed) throw error;
    try {
      onSecondaryFailure?.(error);
    } catch {
      /* Preserve the primary failure. */
    }
  }
  if (workflowFailed) throw workflowError;
  throw new Error(
    'Capacity diagnostics collected; adaptation, media and recovery are NOT qualified',
  );
}

function failureFields(error) {
  return {
    name: String(error?.name ?? 'Error').slice(0, 100),
    message: String(error?.message ?? 'Unknown collection failure').slice(0, 2000),
  };
}

/** Diagnostic collection only: failures cannot skip later owned shutdown stages
 * or turn a raw recording into recovery/media permission. */
export async function collectCapacityDiagnostics(operations, { recorderMode = 'single' } = {}) {
  assert(['single', 'reconnecting'].includes(recorderMode), 'Unknown diagnostic recorder mode');
  const stages = ['stopStatus', 'saveStatus', 'stopWorker', 'stopUplink', 'finishRecorder'];
  assert(stages.every((stage) => typeof operations[stage] === 'function'));
  const result = {
    formatVersion: 1,
    diagnosticOnly: true,
    recoveryQualified: false,
    mediaQualified: false,
    freshRampQualified: false,
    errors: [],
    recording: null,
    ...(recorderMode === 'reconnecting' ? { recorderSessions: null } : {}),
  };
  for (const stage of stages) {
    try {
      const value = await operations[stage]();
      if (stage === 'finishRecorder') {
        if (recorderMode === 'reconnecting') {
          assert(
            value?.formatVersion === 1 &&
              value.diagnosticOnly === true &&
              value.mediaQualified === false &&
              value.recoveryQualified === false &&
              value.closed === true &&
              Array.isArray(value.sessions) &&
              value.sessions.length <= 8,
            'Missing bounded closed diagnostic recorder sessions',
          );
          result.recorderSessions = value;
        } else {
          assert(typeof value === 'string' && value.length > 0, 'Missing diagnostic recording');
          result.recording = value;
        }
      }
    } catch (error) {
      const causes = [],
        seen = new Set([error]);
      let cause = error?.cause;
      while (cause && causes.length < 3 && !seen.has(cause)) {
        seen.add(cause);
        causes.push(failureFields(cause));
        cause = cause.cause;
      }
      result.errors.push({
        stage,
        ...failureFields(error),
        ...(causes.length ? { causes } : {}),
      });
    }
  }
  return result;
}
