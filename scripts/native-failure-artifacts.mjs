import * as fs from 'node:fs/promises';
import { constants } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';

const defaultLimits = { maxBytes: 1024 ** 3, maxEntries: 10_000, maxDepth: 32 };
const safeCodes = new Set([
  'ENOENT',
  'EACCES',
  'EPERM',
  'EIO',
  'ENOSPC',
  'ELOOP',
  'EEXIST',
  'ENOTDIR',
]);
const errorCode = (error) => (safeCodes.has(error?.code) ? error.code : 'UNKNOWN');

async function createSnapshot(artifact, limits, io) {
  const boundedLimits = { ...defaultLimits, ...limits };
  for (const [name, maximum] of Object.entries(defaultLimits)) {
    if (
      !Number.isSafeInteger(boundedLimits[name]) ||
      boundedLimits[name] < 0 ||
      boundedLimits[name] > maximum
    )
      throw new Error('Invalid failure artifact limit');
  }
  const destination = await io.mkdtemp(join(artifact, 'failure-app-data-'));
  return {
    destination,
    manifest: {
      schemaVersion: 1,
      snapshot: 'best-effort; files may change during copying; media validity is not assessed',
      limits: boundedLimits,
      incomplete: false,
      inspectedEntries: 0,
      copiedFiles: 0,
      copiedBytes: 0,
      entries: [],
    },
  };
}

async function saveManifest(snapshot, io) {
  await io.writeFile(
    join(snapshot.destination, 'manifest.json'),
    JSON.stringify(snapshot.manifest, null, 2),
    { flag: 'wx' },
  );
  return snapshot;
}

async function copyTrees(container, snapshot, io) {
  const { destination, manifest } = snapshot;
  const { maxBytes, maxEntries, maxDepth } = manifest.limits;
  function mark(entry, status, details = {}) {
    Object.assign(entry, { status }, details);
    if (status !== 'copied' && status !== 'directory') manifest.incomplete = true;
  }

  // These fixed ancestors must also be directories, never links into setup or
  // another container. Only the two allowlisted trees below are traversed.
  let base = container;
  try {
    if (!isAbsolute(container)) throw new Error('Invalid container');
    for (const component of ['', 'Library', 'Application Support', 'Scorebug']) {
      if (manifest.inspectedEntries >= maxEntries) {
        manifest.incomplete = true;
        for (const path of ['Recordings', 'QA'])
          manifest.entries.push({ path, status: 'skipped', reason: 'entry-limit' });
        return;
      }
      manifest.inspectedEntries++;
      base = join(base, component);
      const stat = await io.lstat(base);
      if (stat.isSymbolicLink() || !stat.isDirectory()) {
        for (const path of ['Recordings', 'QA']) {
          const entry = { path };
          mark(entry, 'skipped', { reason: stat.isSymbolicLink() ? 'symlink' : 'special-file' });
          manifest.entries.push(entry);
        }
        return;
      }
    }
  } catch (error) {
    for (const path of ['Recordings', 'QA']) {
      const entry = { path };
      mark(entry, error?.code === 'ENOENT' ? 'missing' : 'error', { code: errorCode(error) });
      manifest.entries.push(entry);
    }
    return;
  }

  async function visit(path, depth) {
    const entry = { path };
    manifest.entries.push(entry);
    if (manifest.inspectedEntries >= maxEntries) {
      mark(entry, 'skipped', { reason: 'entry-limit' });
      return;
    }
    manifest.inspectedEntries++;
    const source = join(base, path);
    const target = join(destination, path);
    let input, output;
    try {
      const stat = await io.lstat(source);
      if (stat.isSymbolicLink()) {
        mark(entry, 'skipped', { reason: 'symlink' });
      } else if (stat.isDirectory()) {
        if (depth >= maxDepth) {
          mark(entry, 'skipped', { reason: 'depth-limit' });
          return;
        }
        await io.mkdir(target);
        mark(entry, 'directory');
        const directory = await io.opendir(source);
        try {
          // opendir reads incrementally; a very wide tree cannot allocate an
          // unbounded readdir array before the inspected-entry budget applies.
          while (true) {
            if (manifest.inspectedEntries >= maxEntries) {
              mark(entry, 'incomplete', { reason: 'entry-limit' });
              break;
            }
            const child = await directory.read();
            if (!child) break;
            await visit(join(path, child.name), depth + 1);
          }
        } finally {
          await directory.close();
        }
      } else if (stat.isFile()) {
        if (stat.size > maxBytes - manifest.copiedBytes) {
          mark(entry, 'skipped', { reason: 'byte-limit', bytes: 0 });
          return;
        }
        input = await io.open(source, constants.O_RDONLY | constants.O_NOFOLLOW);
        const opened = await input.stat();
        if (
          !opened.isFile() ||
          opened.dev !== stat.dev ||
          opened.ino !== stat.ino ||
          opened.size !== stat.size
        ) {
          mark(entry, 'skipped', { reason: 'source-changed', bytes: 0 });
          return;
        }
        output = await io.open(
          target,
          constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
          0o600,
        );
        entry.bytes = 0;
        const buffer = Buffer.alloc(Math.min(64 * 1024, stat.size));
        while (entry.bytes < stat.size) {
          const { bytesRead } = await input.read(
            buffer,
            0,
            Math.min(buffer.length, stat.size - entry.bytes),
            entry.bytes,
          );
          if (bytesRead === 0) {
            mark(entry, 'incomplete', { reason: 'source-changed' });
            return;
          }
          let written = 0;
          while (written < bytesRead) {
            const { bytesWritten } = await output.write(buffer, written, bytesRead - written);
            if (bytesWritten === 0) throw new Error('Incomplete artifact write');
            written += bytesWritten;
            entry.bytes += bytesWritten;
            manifest.copiedBytes += bytesWritten;
          }
        }
        const finished = await input.stat();
        if (finished.size !== opened.size || finished.mtimeMs !== opened.mtimeMs) {
          mark(entry, 'incomplete', { reason: 'source-changed' });
        } else {
          mark(entry, 'copied');
          manifest.copiedFiles++;
        }
      } else {
        mark(entry, 'skipped', { reason: 'special-file' });
      }
    } catch (error) {
      mark(entry, output ? 'incomplete' : error?.code === 'ENOENT' ? 'missing' : 'error', {
        code: errorCode(error),
      });
    } finally {
      for (const handle of [output, input]) {
        if (!handle) continue;
        try {
          await handle.close();
        } catch (error) {
          if (entry.status === 'copied') manifest.copiedFiles--;
          mark(entry, 'incomplete', { code: errorCode(error) });
        }
      }
    }
  }

  for (const path of ['Recordings', 'QA']) await visit(path, 0);
}

export async function copyNativeFailureArtifacts({ container, artifact, limits, io = fs }) {
  const snapshot = await createSnapshot(artifact, limits, io);
  await copyTrees(container, snapshot, io);
  return saveManifest(snapshot, io);
}

// The caller records the ID only after creating its simulator. All mutations
// target that same ID, even when Xcode shut the device down after the failure.
export async function preserveNativeFailureArtifacts({
  simulator,
  artifact,
  run,
  limits,
  io = fs,
  delay = wait,
}) {
  const snapshot = await createSnapshot(artifact, limits, io);
  const resolution = {
    stage: 'state',
    // Last observed owned state, not an assumption about a later command.
    state: 'Unknown',
    stateReads: 0,
    lookupAttempts: 0,
    bootAttempts: 0,
  };
  snapshot.manifest.resolution = resolution;
  let diagnosticCalls = 0;
  const diagnostic = (args, name, timeout = 10_000) =>
    run('xcrun', ['simctl', ...args], `${name}-${++diagnosticCalls}`, {
      timeout,
      cleanup: true,
      logOutput: false,
    });

  async function stableOwnedState() {
    // One wait has six reads and at most five short delays. Both waits share
    // the enclosing boot/lookup budget, including an initially shut-down device.
    for (let poll = 0; poll <= 5; poll++) {
      resolution.stage = 'state';
      resolution.stateReads++;
      const devices = JSON.parse(
        await diagnostic(['list', 'devices', '--json'], 'failure-device-state'),
      );
      const owned = Object.values(devices.devices)
        .flat()
        .find((device) => device?.udid === simulator);
      const state = owned?.state === 'Shutting Down' ? 'ShuttingDown' : owned?.state;
      resolution.state = !owned
        ? 'Missing'
        : ['Booted', 'Shutdown', 'ShuttingDown'].includes(state)
          ? state
          : 'Unknown';
      if (resolution.state === 'Booted' || resolution.state === 'Shutdown') return;
      if (resolution.state !== 'ShuttingDown') throw new Error('Owned state unavailable');
      resolution.stage = 'waiting-shutdown';
      if (poll === 5) throw new Error('Owned shutdown wait exhausted');
      await delay(200);
    }
  }

  async function prepareOwnedState() {
    await stableOwnedState();
    if (resolution.state === 'Shutdown') {
      resolution.stage = 'boot';
      if (resolution.bootAttempts === 1) throw new Error('Owned boot budget exhausted');
      resolution.bootAttempts++;
      await diagnostic(['boot', simulator], 'failure-boot-for-export');
      resolution.stage = 'bootstatus';
      await diagnostic(['bootstatus', simulator, '-b'], 'failure-ready-for-export', 30_000);
    }
  }

  try {
    if (!simulator) {
      resolution.state = 'Missing';
      throw new Error('No owned simulator');
    }
    await prepareOwnedState();
    let container;
    for (let attempt = 0; attempt < 2; attempt++) {
      resolution.stage = 'lookup';
      resolution.lookupAttempts++;
      try {
        container = await diagnostic(
          ['get_app_container', simulator, 'live.scorebug.app', 'data'],
          'failure-container',
        );
        break;
      } catch (error) {
        if (attempt === 1) throw error;
        // Xcode may begin shutting the device down after the preceding state
        // read. Recheck only this owned device before the one permitted retry.
        await prepareOwnedState();
      }
    }
    resolution.stage = 'copy';
    await copyTrees(container, snapshot, io);
    resolution.stage = 'complete';
  } catch (error) {
    snapshot.manifest.incomplete = true;
    snapshot.manifest.entries.push({
      status: 'error',
      reason: 'container-resolution',
      code: errorCode(error),
    });
  }
  return saveManifest(snapshot, io);
}
