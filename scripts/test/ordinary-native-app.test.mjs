import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  ordinaryNativeOptions,
  ordinaryEnvironment,
  runOrdinaryCommand,
  ordinaryTestEnvironment,
  joinOrdinaryWorkflows,
  requireOrdinaryTestResult,
  recoverOrdinaryOwnership,
} from '../test-ordinary-native-app.mjs';
const interfaces = { en0: [{ address: '192.168.1.130', internal: false }] };
for (const interrupted of ['create-phone', 'create-watch', 'pair']) {
  test(`recovers only owned identities after interrupted ${interrupted} returned no UUID`, async () => {
    const calls = [];
    const owner = {
      paired: true,
      phoneName: 'unique-phone',
      watchName: 'unique-watch',
      simulator: interrupted === 'create-phone' ? undefined : 'owned-phone',
      watch: interrupted === 'pair' ? 'owned-watch' : undefined,
    };
    const recovered = await recoverOrdinaryOwnership(owner, async (command, args, label) => {
      calls.push(label);
      assert.equal(command, 'xcrun');
      assert.deepEqual(args.slice(0, 2), ['simctl', 'list']);
      if (args[2] === 'devices')
        return JSON.stringify({
          devices: {
            runtime: [
              { name: 'unrelated', udid: 'other-phone' },
              { name: owner.phoneName, udid: 'owned-phone' },
              ...(interrupted === 'create-phone'
                ? []
                : [{ name: owner.watchName, udid: 'owned-watch' }]),
            ],
          },
        });
      return JSON.stringify({
        pairs: {
          unrelated: { phone: { udid: 'other-phone' }, watch: { udid: 'owned-watch' } },
          owned: { phone: { udid: 'owned-phone' }, watch: { udid: 'owned-watch' } },
        },
      });
    });
    assert.equal(recovered.simulator, 'owned-phone');
    assert.equal(recovered.watch, interrupted === 'create-phone' ? undefined : 'owned-watch');
    assert.equal(recovered.pairId, interrupted === 'create-phone' ? undefined : 'owned');
    assert(calls.length <= 2, 'Recovery must remain bounded');
  });
}
test('failed pair discovery retains recovered device IDs and reports cleanup failure', async () => {
  const recovered = await recoverOrdinaryOwnership(
    { paired: true, phoneName: 'ours-phone', watchName: 'ours-watch' },
    async (_command, args) => {
      if (args[2] === 'pairs') throw new Error('bounded inventory failure');
      return JSON.stringify({
        devices: {
          runtime: [
            { name: 'ours-phone', udid: 'p' },
            { name: 'ours-watch', udid: 'w' },
          ],
        },
      });
    },
  );
  assert.equal(recovered.simulator, 'p');
  assert.equal(recovered.watch, 'w');
  assert.deepEqual(recovered.failures, ['owned pair discovery']);
});
test('paired lane is explicit and cannot alter runtime or timing policy', () => {
  assert.deepEqual(
    ordinaryNativeOptions(
      ['--host', '192.168.1.130', '--source', '/p.mov', '--lane', 'paired'],
      interfaces,
    ),
    { host: '192.168.1.130', source: '/p.mov', encoder: 'software', lane: 'paired' },
  );
  for (const lane of ['physical', 'laboratory', '']) {
    assert.throws(() =>
      ordinaryNativeOptions(
        ['--host', '192.168.1.130', '--source', '/p.mov', '--lane', lane],
        interfaces,
      ),
    );
  }
});
test('Watch private test environment never receives phone credentials or source selectors', () => {
  const setup = { endpoint: 'http://192.168.1.130:8080', installationToken: 'private-sentinel' };
  assert.deepEqual(ordinaryTestEnvironment({ paired: true, watch: true, setup }), {
    SCOREBUG_PAIRED_ORDINARY_SIMULATOR: '1',
  });
  const phone = ordinaryTestEnvironment({ paired: true, setup });
  assert.equal(phone.SCOREBUG_DEVICE_TOKEN, setup.installationToken);
  assert.equal(phone.SCOREBUG_ORDINARY_SIMULATOR, '1');
  assert.equal(phone.SCOREBUG_PAIRED_ORDINARY_SIMULATOR, '1');
  assert.throws(() => ordinaryTestEnvironment({ paired: false, watch: true, setup }));
});
test('a failed peer still joins the bounded export workflow before returning', async () => {
  let joined = false;
  await assert.rejects(
    joinOrdinaryWorkflows([
      () => {
        throw new Error('Watch failed');
      },
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 20));
        joined = true;
      },
    ]),
    AggregateError,
  );
  assert.equal(joined, true);
});
test('result qualification rejects skips and a different passing method', () => {
  const summary = {
    result: 'Passed',
    totalTestCount: 1,
    passedTests: 1,
    failedTests: 0,
    skippedTests: 0,
  };
  const expected = 'UITests/Case/testOrdinary';
  const tests = {
    testNodes: [
      {
        children: [
          {
            nodeType: 'Test Case',
            result: 'Passed',
            nodeIdentifierURL: `test://project/${expected}`,
          },
        ],
      },
    ],
  };
  requireOrdinaryTestResult(summary, tests, expected);
  assert.throws(() => requireOrdinaryTestResult({ ...summary, skippedTests: 1 }, tests, expected));
  assert.throws(() => requireOrdinaryTestResult(summary, tests, 'UITests/Case/testOther'));
});
test('cancellation joins both active workflow process groups', async () => {
  const artifact = await mkdtemp(join(tmpdir(), 'scorebug-paired-cancel-'));
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 300);
  try {
    await assert.rejects(
      joinOrdinaryWorkflows(
        ['phone', 'watch'].map(
          (label) => () =>
            runOrdinaryCommand(
              process.execPath,
              ['-e', 'console.log(process.pid);setInterval(()=>{},1000)'],
              { artifact, label, timeout: 2000, grace: 100, signal: controller.signal },
            ),
        ),
      ),
      AggregateError,
    );
    for (const label of ['phone', 'watch']) {
      const pid = Number((await readFile(join(artifact, `${label}.log`), 'utf8')).trim());
      assert(pid > 0);
      assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    }
  } finally {
    clearTimeout(timer);
    await rm(artifact, { recursive: true, force: true });
  }
});
test('requires an explicit assigned private host and absolute prepared source', () => {
  assert.deepEqual(
    ordinaryNativeOptions(['--host', '192.168.1.130', '--source', '/prepared.mov'], interfaces),
    { host: '192.168.1.130', source: '/prepared.mov', encoder: 'software' },
  );
  for (const args of [
    [],
    ['--host', '127.0.0.1', '--source', '/p.mov'],
    ['--host', '192.168.1.131', '--source', '/p.mov'],
    ['--host', '192.168.1.130', '--source', 'p.mov'],
    ['--host', '192.168.1.130', '--source', '/p.mov', '--duration', '900'],
    ['--host', '192.168.1.130', '--source', '/p.mov', '--source', '/q.mov'],
  ]) {
    assert.throws(() => ordinaryNativeOptions(args, interfaces));
  }
});
test('strips all inherited laboratory switches, including Xcode test-child injection', () => {
  const environment = ordinaryEnvironment({
    PATH: '/bin',
    SCOREBUG_TEST_NATIVE_QUALITY: '1',
    SIMCTL_CHILD_SCOREBUG_TEST_VIDEO_OBSERVATIONS: '1',
    TEST_RUNNER_SCOREBUG_TEST_MEASURED_TRIAL: '1',
  });
  assert.equal(environment.PATH, '/bin');
  assert.equal(Object.keys(environment).filter((key) => key.includes('SCOREBUG')).length, 0);
  assert.equal(environment.DEVELOPER_DIR, '/Applications/Xcode-26.2.0.app/Contents/Developer');
});
test('a timed-out command joins its child process group before returning', async () => {
  const artifact = await mkdtemp(join(tmpdir(), 'scorebug-command-'));
  try {
    await assert.rejects(
      runOrdinaryCommand(
        process.execPath,
        [
          '-e',
          `const {spawn}=require('child_process'); const c=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'}); console.log(c.pid); setInterval(()=>{},1000)`,
        ],
        { artifact, label: 'timeout', timeout: 500, grace: 100 },
      ),
      /timed out/,
    );
    const pid = Number((await readFile(join(artifact, 'timeout.log'), 'utf8')).trim());
    assert(pid > 0);
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  } finally {
    await rm(artifact, { recursive: true, force: true });
  }
});
