import assert from 'node:assert/strict';
import test from 'node:test';
const implementation = await import('../capacity-diagnostics.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const select = (args, capacityRecovery) => {
  assert.equal(typeof implementation.nativeCapacityDiagnostics, 'function');
  return implementation.nativeCapacityDiagnostics({ args, capacityRecovery });
};
test('diagnostics require a unique explicit flag and the complete independently selected capacity route', () => {
  assert.equal(select([], false), false);
  assert.equal(select([], true), false);
  assert.equal(select(['--streaming', '--capacity-diagnostics'], true), true);
  assert.throws(() => select(['--capacity-diagnostics'], false));
  assert.throws(() => select(['--capacity-diagnostics', '--capacity-diagnostics'], true));
  assert.throws(() => select(['--capacity-diagnostics'], 'true'));
});
const stages = ['stopStatus', 'saveStatus', 'stopWorker', 'stopUplink', 'finishRecorder'];
test('diagnostics preserve bounded nested clock causes including cyclic chains', async () => {
  const clock = new Error('Clock exchange exceeds 250ms');
  const wrapped = new Error('Owned fault collection failed', { cause: clock });
  clock.cause = wrapped;
  const operations = Object.fromEntries(
    stages.map((stage) => [
      stage,
      async () => {
        if (stage === 'stopStatus') throw wrapped;
        return stage === 'finishRecorder' ? '/local/live.mp4' : undefined;
      },
    ]),
  );
  const result = await collect(operations);
  assert.deepEqual(result.errors[0].causes, [
    { name: 'Error', message: 'Clock exchange exceeds 250ms' },
  ]);
  let deep = Error('end');
  for (let n = 0; n < 10; n++) deep = new Error('x'.repeat(4000), { cause: deep });
  operations.stopStatus = async () => {
    throw deep;
  };
  const bounded = await collect(operations);
  assert.equal(bounded.errors[0].message.length, 2000);
  assert.equal(bounded.errors[0].causes.length, 3);
  assert(bounded.errors[0].causes.every((c) => c.message.length <= 2000));
});
async function collect(operations) {
  assert.equal(typeof implementation.collectCapacityDiagnostics, 'function');
  return implementation.collectCapacityDiagnostics(operations);
}
test('diagnostic collection joins every owned stage in order and grants no qualification', async () => {
  const calls = [];
  const operations = Object.fromEntries(
    stages.map((stage) => [
      stage,
      async () => {
        calls.push(stage);
        return stage === 'finishRecorder' ? '/local/live.mp4' : undefined;
      },
    ]),
  );
  const result = await collect(operations);
  assert.deepEqual(calls, stages);
  assert.deepEqual(result, {
    formatVersion: 1,
    diagnosticOnly: true,
    recoveryQualified: false,
    mediaQualified: false,
    freshRampQualified: false,
    errors: [],
    recording: '/local/live.mp4',
  });
});
for (const failed of stages)
  test(`diagnostic collection retains ${failed} failure and still joins remaining stages`, async () => {
    const calls = [];
    const result = await collect(
      Object.fromEntries(
        stages.map((stage) => [
          stage,
          async () => {
            calls.push(stage);
            if (stage === failed) throw Error('deliberate stage failure');
            return stage === 'finishRecorder' ? '/local/live.mp4' : undefined;
          },
        ]),
      ),
    );
    assert.deepEqual(calls, stages);
    assert.equal(result.recoveryQualified, false);
    assert.deepEqual(result.errors, [
      { stage: failed, name: 'Error', message: 'deliberate stage failure' },
    ]);
    assert.equal(result.recording, failed === 'finishRecorder' ? null : '/local/live.mp4');
  });
test(
  'collection never starts the next stage before pending file/process work joins',
  { timeout: 2000 },
  async () => {
    let release, started;
    const calls = [];
    const began = new Promise((resolve) => (started = resolve));
    const result = collect(
      Object.fromEntries(
        stages.map((stage) => [
          stage,
          async () => {
            calls.push(stage);
            if (stage === 'stopStatus') {
              started();
              await new Promise((resolve) => (release = resolve));
            }
            return stage === 'finishRecorder' ? '/local/live.mp4' : undefined;
          },
        ]),
      ),
    );
    await Promise.race([began, result]);
    assert.deepEqual(calls, ['stopStatus']);
    release();
    await result;
    assert.deepEqual(calls, stages);
  },
);
