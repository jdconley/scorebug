import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

/** POSIX-only validation command. Own, kill and join one process group before
 * releasing resources it could still use. Never signal unrelated processes. */
export async function ownedCommand(
  binary,
  args,
  { cwd, env = process.env, timeout = 60000, maxOutputBytes = 4 * 1024 * 1024, signal } = {},
) {
  assert.notEqual(process.platform, 'win32');
  assert.ok(Number.isSafeInteger(timeout) && timeout > 0);
  assert.ok(Number.isSafeInteger(maxOutputBytes) && maxOutputBytes > 0);
  if (signal?.aborted)
    return {
      ok: false,
      reason: 'aborted',
      pid: null,
      code: null,
      signal: null,
      stdout: '',
      stderr: '',
    };
  return await new Promise((resolve) => {
    const child = spawn(binary, args, {
      cwd,
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let reason = null,
      error = null,
      bytes = 0;
    const stdout = [],
      stderr = [];
    function killGroup() {
      if (!child.pid) return;
      try {
        process.kill(-child.pid, 'SIGKILL');
      } catch (failure) {
        if (failure.code !== 'ESRCH') error = String(failure);
      }
    }
    function stop(cause) {
      reason ??= cause;
      // SIGKILL also handles tools/descendants that ignore TERM. Completion is
      // still awaited: sending a signal alone does not release ownership.
      killGroup();
    }
    function collect(chunks, chunk) {
      const remaining = maxOutputBytes - bytes;
      const accepted = chunk.subarray(0, remaining);
      if (accepted.length) chunks.push(accepted);
      bytes += accepted.length;
      if (chunk.length > remaining) stop('output-limit');
    }
    child.stdout.on('data', (chunk) => collect(stdout, chunk));
    child.stderr.on('data', (chunk) => collect(stderr, chunk));
    child.on('error', (failure) => {
      error = String(failure);
      stop('spawn-error');
    });
    // Even a successful parent must not leave owned background descendants.
    child.on('exit', killGroup);
    const abort = () => stop('aborted');
    signal?.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(() => stop('timeout'), timeout);
    child.on('close', (code, terminationSignal) => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      resolve({
        ok: code === 0 && reason === null && error === null,
        reason,
        error,
        pid: child.pid ?? null,
        code,
        signal: terminationSignal,
        stdout: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
      });
    });
    if (signal?.aborted) abort();
  });
}
