import assert from 'node:assert/strict';

export function nativeCapacityDiagnostics({ args, capacityRecovery }) {
  assert(Array.isArray(args) && args.every((arg) => typeof arg === 'string'));
  assert.equal(typeof capacityRecovery, 'boolean');
  const count = args.filter((arg) => arg === '--capacity-diagnostics').length;
  assert(count <= 1, 'Duplicate capacity diagnostics flag');
  assert(!count || capacityRecovery, 'Capacity diagnostics require the complete capacity route');
  return count === 1;
}

function failureFields(error) {
  return {
    name: String(error?.name ?? 'Error').slice(0, 100),
    message: String(error?.message ?? 'Unknown collection failure').slice(0, 2000),
  };
}

/** Diagnostic collection only: failures cannot skip later owned shutdown stages
 * or turn a raw recording into recovery/media permission. */
export async function collectCapacityDiagnostics(operations) {
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
  };
  for (const stage of stages) {
    try {
      const value = await operations[stage]();
      if (stage === 'finishRecorder') {
        assert(typeof value === 'string' && value.length > 0, 'Missing diagnostic recording');
        result.recording = value;
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
