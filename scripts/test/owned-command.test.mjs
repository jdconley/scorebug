import test from 'node:test';
import assert from 'node:assert/strict';
import { ownedCommand } from '../owned-command.mjs';

const tree = `
  const { spawn } = require('node:child_process');
  process.on('SIGTERM', () => {});
  const child = spawn(process.execPath, ['-e',
    "process.on('SIGTERM', () => {}); console.log(process.pid); setInterval(() => {}, 1000)"]);
  child.stdout.pipe(process.stdout);
  setInterval(() => {}, 1000);
`;
async function assertGone(pid) {
  // A killed orphan may briefly remain a zombie until the OS reaps it.
  for (let i = 0; i < 100; i++) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      assert.equal(error.code, 'ESRCH');
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.fail('Owned descendant survived command completion: ' + pid);
}
test('timeout kills a TERM-resistant process group and joins its output', async () => {
  const result = await ownedCommand(process.execPath, ['-e', tree], { timeout: 1000 });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'timeout');
  assert.equal(result.signal, 'SIGKILL');
  const descendant = Number(result.stdout.trim());
  assert.ok(Number.isInteger(descendant) && descendant > 1);
  await assertGone(descendant);
});
test('abort kills and joins the owned group; pre-abort starts no process', async () => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 1000);
  try {
    const result = await ownedCommand(process.execPath, ['-e', tree], {
      timeout: 10000,
      signal: controller.signal,
    });
    assert.equal(result.reason, 'aborted');
    await assertGone(Number(result.stdout.trim()));
    const skipped = await ownedCommand(process.execPath, ['-e', 'throw Error("started")'], {
      signal: controller.signal,
    });
    assert.equal(skipped.reason, 'aborted');
    assert.equal(skipped.stdout, '');
    assert.equal(skipped.pid, null);
  } finally {
    clearTimeout(timer);
  }
});
test('bounds combined output and stops the writer instead of silently truncating success', async () => {
  const result = await ownedCommand(
    process.execPath,
    [
      '-e',
      'setInterval(() => { process.stdout.write("a".repeat(8192)); process.stderr.write("b".repeat(8192)); }, 1)',
    ],
    { maxOutputBytes: 1024 },
  );
  assert.equal(result.reason, 'output-limit');
  assert.equal(result.ok, false);
  assert.ok(Buffer.byteLength(result.stdout + result.stderr) <= 1024);
});
test('preserves ordinary success, exit failure and spawn failure', async () => {
  const success = await ownedCommand(process.execPath, ['-e', 'console.log("done")']);
  assert.equal(success.ok, true);
  assert.equal(success.stdout, 'done\n');
  const failed = await ownedCommand(process.execPath, ['-e', 'process.exit(7)']);
  assert.equal(failed.ok, false);
  assert.equal(failed.code, 7);
  const missing = await ownedCommand('/scorebug-does-not-exist', []);
  assert.equal(missing.ok, false);
  assert.equal(missing.reason, 'spawn-error');
});
