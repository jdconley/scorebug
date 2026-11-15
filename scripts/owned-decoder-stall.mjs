import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { basename } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { isDeepStrictEqual } from 'node:util';
const execute = promisify(execFile);
const inventory = inventoryDecoderProcesses;
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
export async function inventoryDecoderProcesses(workerPID) {
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
  return readProcessRows(ids);
}
async function readProcessRows(ids, run = execute) {
  const { stdout } = await run('/bin/ps', ['-p', ids.join(','), '-o', 'pid=,ppid=,lstart=,comm='], {
    timeout: 1500,
    maxBuffer: 65536,
  });
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
/** Recheck only the three already-discovered identities in one scoped ps call.
 * This never discovers or adopts a replacement process. */
export async function revalidateDecoderIdentity(identity, { execute: run = execute } = {}) {
  const ids = [identity.worker.pid, identity.guardian.pid, identity.decoder.pid];
  assert(
    ids.every((pid) => Number.isSafeInteger(pid) && pid > 0) && new Set(ids).size === 3,
    'Invalid known decoder identity',
  );
  const rows = await readProcessRows(ids, run);
  assert(
    rows.length === 3 && new Set(rows.map((row) => row.pid)).size === 3,
    'Owned decoder identity changed before pause',
  );
  const current = resolveDecoderIdentity(rows, identity.worker.pid);
  assert(isDeepStrictEqual(current, identity), 'Owned decoder identity changed before pause');
  return current;
}
/** One fixture-owned fault; finally resumes before caller joins worker teardown.
 * Process arguments and media URLs are never queried or exported. */
export async function runOwnedDecoderStall({
  worker,
  signal,
  delayBeforePauseMs = 20000,
  save,
  observeBeforePause,
  observePaused,
  inventory: read = inventory,
  revalidate = read === inventory
    ? revalidateDecoderIdentity
    : async (identity) =>
        resolveDecoderIdentity(await read(identity.worker.pid), identity.worker.pid),
  signalProcess = (pid, kind) => process.kill(pid, kind),
  wait = (ms) => delay(ms, undefined, { signal }),
}) {
  assert(
    delayBeforePauseMs === 20000 || delayBeforePauseMs === 70000,
    'Owned decoder stall schedule must be exactly 20000 or 70000 milliseconds',
  );
  const evidence = {
    formatVersion: 1,
    delayBeforePauseMs,
    closed: false,
    failed: false,
    identity: null,
    pauseSentAt: null,
    resumeSentAt: null,
  };
  const sample = async (observe) => {
    const requestStartedAt = performance.now();
    const value = await observe();
    return { requestStartedAt, receivedAt: performance.now(), value };
  };
  let paused = false,
    failure;
  const alive = () =>
    assert(
      worker.pid > 0 && worker.exitCode === null && worker.signalCode === null,
      'Owned worker exited',
    );
  try {
    await wait(delayBeforePauseMs);
    alive();
    evidence.identity = resolveDecoderIdentity(await read(worker.pid), worker.pid);
    if (observeBeforePause) evidence.beforePauseSample = await sample(observeBeforePause);
    signal?.throwIfAborted();
    // The status sample can suspend while the owned decoder or its guardian exits.
    // Recheck the discovered identities without repeating process-tree discovery.
    const beforePauseIdentity = await revalidate(evidence.identity);
    signal?.throwIfAborted();
    alive();
    assert(
      isDeepStrictEqual(beforePauseIdentity, evidence.identity),
      'Owned decoder identity changed before pause',
    );
    signalProcess(beforePauseIdentity.decoder.pid, 'SIGSTOP');
    paused = true;
    evidence.pauseSentAt = performance.now();
    await save(evidence);
    await wait(1800);
    if (observePaused) evidence.pausedSample = await sample(observePaused);
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
