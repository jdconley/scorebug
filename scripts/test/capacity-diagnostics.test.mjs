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
test('owned measurement can collect diagnostics but cannot enter the passing runner', () => {
  const selectOwned = (args, ownedMeasurement = '1', capacityRecovery = true) =>
    implementation.nativeCapacityDiagnostics({ args, ownedMeasurement, capacityRecovery });
  assert.equal(selectOwned(['--capacity-diagnostics']), true);
  assert.throws(() => selectOwned([]), /Owned recovery runner awaits its whole-history qualifier/);
  for (const invalid of ['', 'true', '0', 1, null])
    assert.throws(() => selectOwned(['--capacity-diagnostics'], invalid), /exact opt-in/);
  assert.throws(
    () => selectOwned(['--capacity-diagnostics'], '1', false),
    /complete capacity route/,
  );
});
const stages = ['stopStatus', 'saveStatus', 'stopWorker', 'stopUplink', 'finishRecorder'];
async function workflow(operations) {
  assert.equal(typeof implementation.runCapacityDiagnosticWorkflow, 'function');
  return implementation.runCapacityDiagnosticWorkflow(operations);
}
for (const uiFailed of [false, true])
  test(`diagnostic workflow joins and saves after UI ${uiFailed ? 'failure' : 'success'}, then fails`, async () => {
    const calls = [];
    const original = new Error('UI qualification failed');
    const report = { diagnosticOnly: true, recoveryQualified: false };
    await assert.rejects(
      workflow({
        workflow: async () => {
          calls.push('workflow');
          if (uiFailed) throw original;
        },
        collect: async () => {
          calls.push('collect');
          return report;
        },
        save: async (value) => {
          calls.push('save');
          assert.strictEqual(value, report);
        },
      }),
      (error) => (uiFailed ? error === original : /NOT qualified/.test(error.message)),
    );
    assert.deepEqual(calls, ['workflow', 'collect', 'save']);
  });
for (const failedStage of ['collect', 'save'])
  for (const uiFailed of [false, true])
    test(`diagnostic ${failedStage} failure retains ${uiFailed ? 'original UI' : 'collection'} error`, async () => {
      const original = new Error('UI qualification failed'),
        secondary = new Error(failedStage);
      const calls = [];
      await assert.rejects(
        workflow({
          workflow: async () => {
            calls.push('workflow');
            if (uiFailed) throw original;
          },
          collect: async () => {
            calls.push('collect');
            if (failedStage === 'collect') throw secondary;
            return {};
          },
          save: async () => {
            calls.push('save');
            throw secondary;
          },
          onSecondaryFailure: (error) => {
            calls.push('secondary');
            assert.strictEqual(error, secondary);
          },
        }),
        (error) => error === (uiFailed ? original : secondary),
      );
      assert.deepEqual(calls, [
        'workflow',
        'collect',
        ...(failedStage === 'save' ? ['save'] : []),
        ...(uiFailed ? ['secondary'] : []),
      ]);
    });
test('pending diagnostics must finish before the workflow rejects', async () => {
  let release, began;
  const started = new Promise((resolve) => {
    began = resolve;
  });
  let settled = false;
  const pending = workflow({
    workflow: async () => {
      throw new Error('UI failure');
    },
    collect: async () => {
      began();
      await new Promise((resolve) => {
        release = resolve;
      });
      return {};
    },
    save: async () => {},
  }).catch((error) => {
    settled = true;
    return error;
  });
  await Promise.race([started, pending]);
  assert.equal(settled, false);
  release();
  assert.equal((await pending).message, 'UI failure');
});
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

test('explicit reconnecting diagnostics preserve the closed session manifest without qualifying media', async () => {
  const manifest = {
    formatVersion: 1,
    diagnosticOnly: true,
    mediaQualified: false,
    recoveryQualified: false,
    closed: true,
    sessions: [
      {
        sequence: 1,
        recordingRelativePath: 'reconnecting-recorder/session-1/sink-recordings/direct.mp4',
      },
    ],
  };
  const operations = Object.fromEntries(
    ['stopStatus', 'saveStatus', 'stopWorker', 'stopUplink'].map((k) => [k, async () => {}]),
  );
  operations.finishRecorder = async () => manifest;
  const result = await implementation.collectCapacityDiagnostics(operations, {
    recorderMode: 'reconnecting',
  });
  assert.equal(result.recording, null);
  assert.deepEqual(result.recorderSessions, manifest);
  assert.equal(result.mediaQualified, false);
  assert.equal(result.recoveryQualified, false);
  assert.deepEqual(result.errors, []);
  assert.equal((await implementation.collectCapacityDiagnostics(operations)).errors.length, 1);
});
for (const mutate of [
  (m) => (m.closed = false),
  (m) => (m.mediaQualified = true),
  (m) => (m.recoveryQualified = true),
  (m) => (m.diagnosticOnly = false),
  (m) => (m.sessions = Array(9).fill({})),
])
  test('reconnecting diagnostic result requires bounded closed nonqualifying evidence', async () => {
    const manifest = {
      formatVersion: 1,
      diagnosticOnly: true,
      mediaQualified: false,
      recoveryQualified: false,
      closed: true,
      sessions: [],
    };
    mutate(manifest);
    const operations = Object.fromEntries(
      ['stopStatus', 'saveStatus', 'stopWorker', 'stopUplink'].map((k) => [k, async () => {}]),
    );
    operations.finishRecorder = async () => manifest;
    const result = await implementation.collectCapacityDiagnostics(operations, {
      recorderMode: 'reconnecting',
    });
    assert.equal(result.recorderSessions, null);
    assert.equal(result.errors.length, 1);
  });
