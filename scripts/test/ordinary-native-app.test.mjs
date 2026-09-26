import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  ordinaryNativeOptions,
  ordinaryEnvironment,
  runOrdinaryCommand,
} from '../test-ordinary-native-app.mjs';
const interfaces = { en0: [{ address: '192.168.1.130', internal: false }] };
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
