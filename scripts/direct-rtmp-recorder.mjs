import { execFile, spawn } from 'node:child_process';
import { mkdir, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const failure = (reason) => new Error(`Direct RTMP recorder ${reason}`);
const timeout = Symbol('timeout');

async function bounded(promise, milliseconds) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(timeout), Math.max(0, milliseconds));
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

// Never connect to this listener for readiness: FFmpeg accepts only one publisher.
function ownsListener(stdout, pid, port) {
  let processId;
  for (const line of stdout.split('\n')) {
    if (line.startsWith('p')) processId = line.slice(1);
    if (processId === String(pid) && line === `n127.0.0.1:${port}`) return true;
  }
  return false;
}

export async function startDirectRTMPRecorder({ artifact, ffmpeg, port }, dependencies = {}) {
  if (!Number.isInteger(port) || port < 1 || port > 65_535) throw failure('has invalid port');
  const {
    spawn: spawnChild = spawn,
    execFile: probe = execute,
    now = () => performance.now(),
    startupMs = 5_000,
    finishMs = 5_000,
    killMs = 2_000,
    pollMs = 50,
  } = dependencies;
  const deadline = now() + startupMs;
  const relativePath = 'sink-recordings/direct.mp4';
  const recording = join(artifact, relativePath);
  const manifestPath = join(artifact, 'direct-rtmp-recorder.json');
  await mkdir(join(artifact, 'sink-recordings'), { recursive: true });
  for (const path of [recording, manifestPath]) {
    const exists = await stat(path).then(
      () => true,
      (error) => {
        if (error.code === 'ENOENT') return false;
        throw failure('could not inspect output');
      },
    );
    if (exists) throw failure('refuses to overwrite existing output');
  }
  const url = `rtmp://127.0.0.1:${port}/live/fixture`;
  let child;
  try {
    child = spawnChild(
      ffmpeg,
      [
        '-nostdin',
        '-n',
        '-listen',
        '1',
        '-i',
        url,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0',
        '-c',
        'copy',
        '-movflags',
        '+frag_keyframe+empty_moov',
        '-f',
        'mp4',
        recording,
      ],
      { stdio: 'ignore' },
    );
  } catch {
    throw failure('failed to spawn');
  }

  let outcome;
  let readinessObserved = false;
  let terminationRequested = false;
  let spawnFailed = false;
  const closed = new Promise((resolve) => {
    child.on('error', () => {
      spawnFailed = true;
    });
    child.once('close', (code, signal) => {
      outcome = { actualCode: code, actualSignal: signal };
      resolve({
        formatVersion: 1,
        readinessObserved,
        ...outcome,
        terminationRequested,
        recordingRelativePath: relativePath,
      });
    });
  });
  const persisted = closed.then(async (manifest) => {
    try {
      await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx' });
    } catch {
      throw failure('could not persist its manifest');
    }
  });
  // close can happen before the caller joins; retain persistence errors for that join.
  persisted.catch(() => {});

  let stopping;
  function stop() {
    if (!stopping)
      stopping = (async () => {
        if (!outcome && Number.isInteger(child.pid) && child.pid > 0) {
          terminationRequested = true;
          child.kill('SIGTERM');
          if ((await bounded(closed, killMs)) === timeout && !outcome) child.kill('SIGKILL');
        }
        await closed;
        await persisted;
      })();
    return stopping;
  }

  let finishing;
  function finish() {
    if (!finishing)
      finishing = (async () => {
        if ((await bounded(closed, finishMs)) === timeout) {
          await stop().catch(() => {});
          throw failure('did not finish naturally before its deadline');
        }
        await persisted;
        if (
          spawnFailed ||
          terminationRequested ||
          outcome.actualCode !== 0 ||
          outcome.actualSignal !== null
        ) {
          throw failure('did not exit successfully');
        }
        const output = await stat(recording).catch(() => null);
        if (!output?.isFile() || output.size === 0) throw failure('has no nonempty recording');
        return recording;
      })();
    return finishing;
  }

  try {
    while (now() < deadline && !outcome && !spawnFailed) {
      if (!Number.isInteger(child.pid) || child.pid <= 0) throw failure('failed to spawn');
      const remaining = deadline - now();
      const controller = new AbortController();
      const pendingProbe = probe(
        'lsof',
        ['-nP', '-a', '-p', String(child.pid), `-iTCP:${port}`, '-sTCP:LISTEN', '-Fn'],
        {
          timeout: Math.max(1, Math.min(250, Math.ceil(remaining))),
          killSignal: 'SIGKILL',
          maxBuffer: 16_384,
          encoding: 'utf8',
          signal: controller.signal,
        },
      );
      const probeResult = pendingProbe.catch(() => null);
      const probeClosed = pendingProbe.child
        ? new Promise((resolve) => pendingProbe.child.once('close', resolve))
        : probeResult;
      let result;
      try {
        result = await bounded(Promise.race([probeResult, closed.then(() => null)]), remaining);
      } finally {
        controller.abort();
        // Abort may send TERM and clear execFile's timeout. Reap the owned probe
        // explicitly so a TERM-resistant process cannot keep startup pending.
        const probeChild = pendingProbe.child;
        if (probeChild?.exitCode === null && probeChild.signalCode === null) {
          probeChild.kill('SIGKILL');
        }
        await probeClosed;
        await probeResult;
      }
      if (outcome || spawnFailed) break;
      if (
        result !== timeout &&
        result &&
        now() < deadline &&
        ownsListener(result.stdout, child.pid, port)
      ) {
        readinessObserved = true;
        return { url, finish, stop };
      }
      await bounded(closed, Math.min(pollMs, Math.max(0, deadline - now())));
    }
    throw failure(
      outcome || spawnFailed ? 'exited before readiness' : 'readiness deadline expired',
    );
  } catch {
    const reason =
      outcome || spawnFailed ? 'exited before readiness' : 'readiness deadline expired';
    await stop().catch(() => {});
    // Only fixed messages leave this helper; no child logs or probe errors are retained.
    throw failure(reason);
  }
}
