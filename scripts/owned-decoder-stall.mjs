import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { basename } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { isDeepStrictEqual } from 'node:util';
const execute = promisify(execFile);
export function resolveDecoderIdentity(rows, workerPID) {
  const worker = rows.find((r) => r.pid === workerPID);
  assert(worker && basename(worker.command) === 'node' && worker.start, 'Owned worker missing');
  const guardians = rows.filter((r) => r.ppid === workerPID && basename(r.command) === 'node');
  const candidates = rows.filter(
    (r) => basename(r.command) === 'ffmpeg' && guardians.some((g) => g.pid === r.ppid),
  );
  assert.equal(candidates.length, 1, 'Expected exactly one owned worker decoder');
  const decoder = candidates[0],
    guardian = guardians.find((g) => g.pid === decoder.ppid);
  assert(decoder.start && guardian.start);
  return structuredClone({ worker, guardian, decoder });
}
async function inventory(workerPID) {
  assert.equal(
    process.platform,
    'darwin',
    'Owned decoder fault is a local macOS simulator fixture',
  );
  const children = async (pid) => {
    try {
      const { stdout } = await execute('/usr/bin/pgrep', ['-P', String(pid)], {
        timeout: 1500,
        maxBuffer: 65536,
      });
      return stdout
        .trim()
        .split(/\s+/)
        .map(Number)
        .filter((n) => Number.isSafeInteger(n) && n > 0);
    } catch (e) {
      if (e.code === 1) return [];
      throw e;
    }
  };
  const direct = await children(workerPID),
    nested = [];
  assert(direct.length <= 8, 'Unexpected worker child count');
  for (const child of direct) {
    nested.push(...(await children(child)));
    assert(direct.length + nested.length <= 31, 'Unexpected worker process tree');
  }
  const ids = [workerPID, ...direct, ...nested];
  assert(ids.length <= 32, 'Unexpected worker process tree');
  const { stdout } = await execute(
    '/bin/ps',
    ['-p', ids.join(','), '-o', 'pid=,ppid=,lstart=,comm='],
    { timeout: 1500, maxBuffer: 65536 },
  );
  return stdout
    .trim()
    .split('\n')
    .map((line) => {
      const m = line.match(
        /^\s*(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.+)$/,
      );
      assert(m, 'Unrecognized owned process identity');
      return { pid: Number(m[1]), ppid: Number(m[2]), start: m[3], command: m[4] };
    });
}
/** One fixture-owned fault; finally resumes before caller joins worker teardown.
 * Process arguments and media URLs are never queried or exported. */
export async function runOwnedDecoderStall({
  worker,
  signal,
  save,
  inventory: read = inventory,
  signalProcess = (pid, kind) => process.kill(pid, kind),
  wait = (ms) => delay(ms, undefined, { signal }),
}) {
  const evidence = {
    formatVersion: 1,
    closed: false,
    failed: false,
    identity: null,
    pauseSentAt: null,
    resumeSentAt: null,
  };
  let paused = false,
    failure;
  const alive = () =>
    assert(
      worker.pid > 0 && worker.exitCode === null && worker.signalCode === null,
      'Owned worker exited',
    );
  try {
    await wait(20000);
    alive();
    evidence.identity = resolveDecoderIdentity(await read(worker.pid), worker.pid);
    alive();
    signalProcess(evidence.identity.decoder.pid, 'SIGSTOP');
    paused = true;
    evidence.pauseSentAt = performance.now();
    await save(evidence);
    await wait(1800);
  } catch (error) {
    failure = error;
  } finally {
    if (paused) {
      try {
        alive();
        const current = resolveDecoderIdentity(await read(worker.pid), worker.pid);
        alive();
        assert(
          isDeepStrictEqual(current, evidence.identity),
          'Owned decoder identity changed while paused',
        );
        signalProcess(current.decoder.pid, 'SIGCONT');
        evidence.resumeSentAt = performance.now();
        paused = false;
      } catch (error) {
        failure ??= error;
      }
    }
    evidence.closed = true;
    evidence.failed = Boolean(failure);
    await save(evidence);
  }
  if (failure) throw failure;
  return evidence;
}
