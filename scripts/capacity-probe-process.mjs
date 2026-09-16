import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
// Owned loopback laboratory process; every permanent pipe-error listener routes through joined cleanup.
export function startProbeProcess(binary, args, { cwd, role, now }) {
  const child = spawn(binary, args, {
    cwd,
    detached: true,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const owner = {
    role,
    child,
    rows: [],
    sample: null,
    pending: '',
    output: '',
    error: '',
    closed: false,
    code: null,
    failure: null,
  };
  const kill = () => {
    if (child.pid && !owner.closed)
      try {
        process.kill(-child.pid, 'SIGKILL');
      } catch (e) {
        if (e.code !== 'ESRCH') owner.failure = String(e);
      }
  };
  owner.kill = kill;
  owner.done = new Promise((resolve) =>
    child.once('close', (code) => {
      owner.closed = true;
      owner.code = code;
      resolve();
    }),
  );
  child.on('error', (e) => {
    owner.failure = String(e);
    kill();
  });
  for (const stream of [child.stdin, child.stdout, child.stderr])
    stream.on('error', (e) => {
      owner.failure ??= String(e);
      kill();
    });
  child.stdout.on('data', (data) => {
    if (owner.output.length + data.length > 2 * 1024 * 1024) {
      owner.failure = 'stdout bound';
      kill();
      return;
    }
    owner.output += data;
    owner.pending += data;
    let end;
    while ((end = owner.pending.indexOf('\n')) >= 0) {
      const line = owner.pending.slice(0, end);
      owner.pending = owner.pending.slice(end + 1);
      try {
        const row = JSON.parse(line);
        assert(Number.isFinite(row.at));
        row.receivedAt = now();
        owner.rows.push(row);
        if (owner.rows.length > 2500) throw Error('row bound');
        if (row.kind === 'sample') owner.sample = row;
      } catch (e) {
        owner.failure = String(e);
        kill();
        break;
      }
    }
  });
  child.stderr.on('data', (data) => {
    if (owner.error.length + data.length > 128 * 1024) {
      owner.failure = 'stderr bound';
      kill();
      return;
    }
    owner.error += data;
  });
  return owner;
}
export function requestProbeStop(owner) {
  if (!owner.closed && !owner.stopRequested) {
    owner.stopRequested = true;
    try {
      owner.child.stdin.write('stop\n');
    } catch {}
  }
}
export async function stopProbeProcess(owner) {
  requestProbeStop(owner);
  if (!owner.closed) {
    const timer = new AbortController();
    try {
      await Promise.race([owner.done, delay(1500, undefined, { signal: timer.signal })]);
    } finally {
      timer.abort();
    }
  }
  if (!owner.closed) {
    owner.kill();
    await owner.done;
  }
  owner.child.stdin.destroy();
  assert(owner.closed, 'Native owner not joined');
}
