import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import {
  copyNativeFailureArtifacts,
  preserveNativeFailureArtifacts,
} from '../native-failure-artifacts.mjs';

async function fixture(t) {
  const root = await fs.mkdtemp(join(tmpdir(), 'scorebug-failure-test-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const container = join(root, 'container');
  const artifact = join(root, 'artifact');
  const source = join(container, 'Library/Application Support/Scorebug');
  await fs.mkdir(source, { recursive: true });
  await fs.mkdir(artifact);
  async function put(path, contents = 'evidence') {
    await fs.mkdir(join(source, path, '..'), { recursive: true });
    await fs.writeFile(join(source, path), contents);
  }
  return { root, container, artifact, source, put };
}

test('copies only Recordings and QA, preserves sources, and creates fresh destinations', async (t) => {
  const f = await fixture(t);
  await f.put('Recordings/session/recording-status.json', '{"state":"failed"}');
  await f.put('QA/video-observation.json', '{"frames":1}');
  await f.put('setup.json', 'private');
  await fs.mkdir(join(f.container, 'Library/Preferences'));
  await fs.writeFile(join(f.container, 'Library/Preferences/private.plist'), 'private');
  const before = await fs.stat(join(f.source, 'Recordings/session/recording-status.json'));
  const result = await copyNativeFailureArtifacts(f);
  assert.deepEqual((await fs.readdir(result.destination)).sort(), [
    'QA',
    'Recordings',
    'manifest.json',
  ]);
  assert.equal(
    await fs.readFile(join(result.destination, 'QA/video-observation.json'), 'utf8'),
    '{"frames":1}',
  );
  assert.equal(result.manifest.copiedFiles, 2);
  assert.equal(result.manifest.incomplete, false);
  const after = await fs.stat(join(f.source, 'Recordings/session/recording-status.json'));
  assert.equal(after.mtimeMs, before.mtimeMs);
  assert.equal(
    await fs.readFile(join(f.source, 'Recordings/session/recording-status.json'), 'utf8'),
    '{"state":"failed"}',
  );
  const again = await copyNativeFailureArtifacts(f);
  assert.notEqual(again.destination, result.destination);
  assert.deepEqual(
    JSON.parse(await fs.readFile(join(result.destination, 'manifest.json'), 'utf8')),
    result.manifest,
  );
});

test('a missing Recordings tree does not prevent QA preservation', async (t) => {
  const f = await fixture(t);
  await f.put('QA/observation.json');
  const { destination, manifest } = await copyNativeFailureArtifacts(f);
  assert.ok(
    manifest.entries.some((entry) => entry.path === 'Recordings' && entry.status === 'missing'),
  );
  assert.equal(manifest.copiedFiles, 1);
  assert.equal(manifest.incomplete, true);
  assert.equal(await fs.readFile(join(destination, 'QA/observation.json'), 'utf8'), 'evidence');
});

test('rejects file and directory symlinks without reading outside the whitelist', async (t) => {
  const f = await fixture(t);
  await f.put('QA/good.json');
  await fs.mkdir(join(f.source, 'Recordings'));
  await fs.writeFile(join(f.root, 'secret'), 'do not copy');
  await fs.symlink(join(f.root, 'secret'), join(f.source, 'Recordings/linked-file'));
  await fs.symlink(f.root, join(f.source, 'Recordings/linked-directory'));
  const { manifest, destination } = await copyNativeFailureArtifacts(f);
  assert.equal(manifest.copiedFiles, 1);
  assert.equal(manifest.entries.filter((entry) => entry.reason === 'symlink').length, 2);
  assert.deepEqual(await fs.readdir(join(destination, 'Recordings')), []);
  assert.equal(JSON.stringify(manifest).includes('do not copy'), false);
  assert.equal(JSON.stringify(manifest).includes(f.root), false);
});

test('rejects a symlink in a whitelist ancestor', async (t) => {
  const f = await fixture(t);
  await fs.rename(f.source, join(f.root, 'outside'));
  await fs.symlink(join(f.root, 'outside'), f.source);
  const { manifest } = await copyNativeFailureArtifacts(f);
  assert.equal(manifest.copiedFiles, 0);
  assert.equal(manifest.incomplete, true);
  assert.ok(manifest.entries.some((entry) => entry.reason === 'symlink'));
});

test('byte budget skips oversized recordings but still copies a small QA file', async (t) => {
  const f = await fixture(t);
  await f.put('Recordings/large.mp4', '123456789');
  await f.put('QA/observation.json', '1234');
  const { manifest, destination } = await copyNativeFailureArtifacts({
    ...f,
    limits: { maxBytes: 4 },
  });
  assert.equal(manifest.copiedBytes, 4);
  assert.equal(manifest.copiedFiles, 1);
  assert.ok(manifest.entries.some((entry) => entry.reason === 'byte-limit'));
  assert.equal(await fs.readFile(join(destination, 'QA/observation.json'), 'utf8'), '1234');
});

test('entry count bounds inspection and manifest size', async (t) => {
  const f = await fixture(t);
  for (let index = 0; index < 12; index++) await f.put(`Recordings/${index}.mp4`, 'x');
  await f.put('QA/observation.json');
  let inspected = 0;
  const io = {
    ...fs,
    lstat: async (path) => {
      inspected++;
      return fs.lstat(path);
    },
  };
  const { manifest } = await copyNativeFailureArtifacts({ ...f, io, limits: { maxEntries: 7 } });
  assert.equal(manifest.inspectedEntries, 7);
  assert.equal(inspected, 7);
  assert.equal(manifest.incomplete, true);
  assert.ok(manifest.entries.some((entry) => entry.reason === 'entry-limit'));
  assert.ok(manifest.entries.length <= 5);
});

test('depth bounds descent while preserving the other tree', async (t) => {
  const f = await fixture(t);
  await f.put('Recordings/a/b/c.mp4', 'x');
  await f.put('QA/observation.json', 'x');
  const { manifest } = await copyNativeFailureArtifacts({ ...f, limits: { maxDepth: 1 } });
  assert.equal(manifest.copiedFiles, 1);
  assert.ok(manifest.entries.some((entry) => entry.reason === 'depth-limit'));
});

test('special files are skipped without opening them', async (t) => {
  const f = await fixture(t);
  await f.put('Recordings/special');
  await f.put('QA/good');
  const io = {
    ...fs,
    lstat: async (path) => {
      if (path === join(f.source, 'Recordings/special'))
        return { isSymbolicLink: () => false, isDirectory: () => false, isFile: () => false };
      return fs.lstat(path);
    },
  };
  const { manifest } = await copyNativeFailureArtifacts({ ...f, io });
  assert.equal(manifest.copiedFiles, 1);
  assert.ok(manifest.entries.some((entry) => entry.reason === 'special-file'));
});

test('partial read failures are recorded with bounded safe errors and copying continues', async (t) => {
  const f = await fixture(t);
  await f.put('Recordings/broken.mp4', '12345678');
  await f.put('QA/good', 'good');
  const io = {
    ...fs,
    open: async (path, ...args) => {
      const handle = await fs.open(path, ...args);
      if (path !== join(f.source, 'Recordings/broken.mp4')) return handle;
      let reads = 0;
      return {
        stat: () => handle.stat(),
        close: () => handle.close(),
        read: async (buffer, offset, length, position) => {
          if (reads++)
            throw Object.assign(new Error('secret arbitrary source path'), { code: 'EIO' });
          return handle.read(buffer, offset, Math.min(3, length), position);
        },
      };
    },
  };
  const { manifest, destination } = await copyNativeFailureArtifacts({ ...f, io });
  assert.equal(manifest.copiedFiles, 1);
  assert.equal(manifest.copiedBytes, 7);
  assert.equal(manifest.incomplete, true);
  assert.ok(
    manifest.entries.some(
      (entry) => entry.status === 'incomplete' && entry.code === 'EIO' && entry.bytes === 3,
    ),
  );
  assert.equal(await fs.readFile(join(destination, 'Recordings/broken.mp4'), 'utf8'), '123');
  assert.equal(await fs.readFile(join(f.source, 'Recordings/broken.mp4'), 'utf8'), '12345678');
  assert.equal(JSON.stringify(manifest).includes('secret'), false);
});

test('directory read failures do not prevent the other tree from being copied', async (t) => {
  const f = await fixture(t);
  await f.put('Recordings/clip.mp4');
  await f.put('QA/good');
  const io = {
    ...fs,
    opendir: async (path) => {
      if (path === join(f.source, 'Recordings'))
        throw Object.assign(new Error('private'), { code: 'EACCES' });
      return fs.opendir(path);
    },
  };
  const { manifest } = await copyNativeFailureArtifacts({ ...f, io });
  assert.equal(manifest.copiedFiles, 1);
  assert.ok(manifest.entries.some((entry) => entry.status === 'error' && entry.code === 'EACCES'));
});

test('failure capture addresses only the owned simulator and boots it only when shut down', async (t) => {
  const f = await fixture(t);
  await f.put('QA/good');
  for (const state of ['Shutdown', 'Booted']) {
    const calls = [];
    const result = await preserveNativeFailureArtifacts({
      ...f,
      simulator: 'owned-id',
      run: async (binary, args, name, options) => {
        calls.push({ binary, args, name, options });
        if (args[1] === 'list')
          return JSON.stringify({
            devices: {
              runtime: [
                { udid: 'unrelated', state: 'Shutdown' },
                { udid: 'owned-id', state },
              ],
            },
          });
        if (args[1] === 'get_app_container') return f.container;
        return '';
      },
    });
    assert.equal(result.manifest.copiedFiles, 1);
    const ownedCommands = calls.filter((call) => call.args[1] !== 'list');
    assert.ok(ownedCommands.every((call) => call.args[2] === 'owned-id'));
    assert.ok(calls.every((call) => call.options.cleanup && call.options.logOutput === false));
    assert.equal(
      calls.some((call) => call.args[1] === 'boot'),
      state === 'Shutdown',
    );
    assert.equal(
      calls.some((call) => call.args[1] === 'bootstatus'),
      state === 'Shutdown',
    );
    assert.deepEqual(calls.at(-1).args, [
      'simctl',
      'get_app_container',
      'owned-id',
      'live.scorebug.app',
      'data',
    ]);
  }
});

test('container resolution failures produce a safe manifest instead of throwing', async (t) => {
  const f = await fixture(t);
  const result = await preserveNativeFailureArtifacts({
    ...f,
    simulator: 'owned-id',
    run: async () => {
      throw new Error('sensitive raw subprocess output');
    },
  });
  assert.equal(result.manifest.incomplete, true);
  assert.equal(result.manifest.copiedFiles, 0);
  assert.equal(JSON.stringify(result.manifest).includes('sensitive'), false);
  assert.ok(result.manifest.entries.some((entry) => entry.reason === 'container-resolution'));
});

test('missing owned simulator does not resolve another device container', async (t) => {
  const f = await fixture(t);
  const calls = [];
  const result = await preserveNativeFailureArtifacts({
    ...f,
    simulator: 'owned-id',
    run: async (...args) => {
      calls.push(args);
      return JSON.stringify({ devices: { runtime: [{ udid: 'unrelated', state: 'Booted' }] } });
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(result.manifest.incomplete, true);
  assert.equal(result.manifest.copiedFiles, 0);
});

async function resolutionScenario(t, { states, failedLookups = 0, failCommand } = {}) {
  const f = await fixture(t);
  await f.put('Recordings/session/recording-status.json', 'recording');
  await f.put('QA/observation.json', 'observation');
  const calls = [],
    delays = [];
  let stateReads = 0,
    lookupAttempts = 0;
  const result = await preserveNativeFailureArtifacts({
    ...f,
    simulator: 'owned-id',
    delay: async (milliseconds) => {
      delays.push(milliseconds);
    },
    run: async (binary, args, name, options) => {
      calls.push({ binary, args, name, options });
      if (args[1] === failCommand) throw new Error('secret subprocess error /private/path');
      if (args[1] === 'list') {
        const state = states[Math.min(stateReads++, states.length - 1)];
        return JSON.stringify({
          devices: {
            runtime: [
              { udid: 'unrelated-id', state: 'Shutdown', secret: 'private device metadata' },
              ...(state === null ? [] : [{ udid: 'owned-id', state }]),
            ],
          },
        });
      }
      if (args[1] === 'get_app_container') {
        if (lookupAttempts++ < failedLookups) throw new Error('secret container resolution error');
        return f.container;
      }
      return '';
    },
  });
  assert.ok(calls.every(({ binary }) => binary === 'xcrun'));
  assert.ok(calls.every(({ args }) => args[0] === 'simctl'));
  assert.ok(
    calls.filter(({ args }) => args[1] !== 'list').every(({ args }) => args[2] === 'owned-id'),
  );
  assert.ok(
    calls
      .filter(({ args }) => args[1] === 'get_app_container')
      .every(({ args }) => args[3] === 'live.scorebug.app' && args[4] === 'data'),
  );
  return { ...f, ...result, calls, delays, operations: calls.map(({ args }) => args[1]) };
}

test('recovers a booted-to-shutdown lookup race within one shared boot and lookup budget', async (t) => {
  const result = await resolutionScenario(t, { states: ['Booted', 'Shutdown'], failedLookups: 1 });
  assert.equal(result.manifest.copiedFiles, 2);
  assert.equal(result.manifest.incomplete, false);
  assert.deepEqual(result.operations, [
    'list',
    'get_app_container',
    'list',
    'boot',
    'bootstatus',
    'get_app_container',
  ]);
  assert.deepEqual(result.manifest.resolution, {
    stage: 'complete',
    state: 'Shutdown',
    stateReads: 2,
    lookupAttempts: 2,
    bootAttempts: 1,
  });
  assert.equal(
    await fs.readFile(join(result.destination, 'QA/observation.json'), 'utf8'),
    'observation',
  );
  assert.equal(
    await fs.readFile(join(result.source, 'Recordings/session/recording-status.json'), 'utf8'),
    'recording',
  );
  assert.equal(
    new Set(result.calls.map(({ name }) => name)).size,
    result.calls.length,
    'Each diagnostic outcome has its own log',
  );
  for (const call of result.calls) {
    assert.equal(call.options.timeout, call.args[1] === 'bootstatus' ? 30_000 : 10_000);
    assert.equal(call.options.cleanup, true);
    assert.equal(call.options.logOutput, false);
  }
});

test('initial shutdown and a later shutdown share the same one-boot budget', async (t) => {
  const first = await resolutionScenario(t, { states: ['Shutdown'] });
  assert.equal(first.manifest.incomplete, false);
  assert.equal(first.manifest.resolution.bootAttempts, 1);
  assert.equal(first.manifest.resolution.lookupAttempts, 1);
  const repeated = await resolutionScenario(t, { states: ['Shutdown'], failedLookups: 1 });
  assert.equal(repeated.manifest.incomplete, true);
  assert.equal(repeated.manifest.copiedFiles, 0);
  assert.deepEqual(repeated.operations, [
    'list',
    'boot',
    'bootstatus',
    'get_app_container',
    'list',
  ]);
  assert.deepEqual(repeated.manifest.resolution, {
    stage: 'boot',
    state: 'Shutdown',
    stateReads: 2,
    lookupAttempts: 1,
    bootAttempts: 1,
  });
});

test('stable booted lookup failures never trigger a boot or more than two lookups', async (t) => {
  const result = await resolutionScenario(t, { states: ['Booted'], failedLookups: 10 });
  assert.equal(result.manifest.incomplete, true);
  assert.equal(result.manifest.copiedFiles, 0);
  assert.deepEqual(result.operations, ['list', 'get_app_container', 'list', 'get_app_container']);
  assert.deepEqual(result.manifest.resolution, {
    stage: 'lookup',
    state: 'Booted',
    stateReads: 2,
    lookupAttempts: 2,
    bootAttempts: 0,
  });
  assert.deepEqual(result.delays, []);
  assert.equal(JSON.stringify(result.manifest).includes('secret'), false);
});

test('stable booted success uses one lookup without rebooting', async (t) => {
  const result = await resolutionScenario(t, { states: ['Booted'] });
  assert.equal(result.manifest.incomplete, false);
  assert.deepEqual(result.operations, ['list', 'get_app_container']);
  assert.deepEqual(result.manifest.resolution, {
    stage: 'complete',
    state: 'Booted',
    stateReads: 1,
    lookupAttempts: 1,
    bootAttempts: 0,
  });
});

test('waits for initial shutdown transitions without resolving or booting a transitioning device', async (t) => {
  const result = await resolutionScenario(t, {
    states: ['Shutting Down', 'ShuttingDown', 'Shutdown'],
  });
  assert.equal(result.manifest.incomplete, false);
  assert.deepEqual(result.delays, [200, 200]);
  assert.deepEqual(result.operations, [
    'list',
    'list',
    'list',
    'boot',
    'bootstatus',
    'get_app_container',
  ]);
  assert.equal(result.manifest.resolution.stateReads, 3);
});

test('allows exactly five transition delays after the first lookup failure', async (t) => {
  const result = await resolutionScenario(t, {
    states: ['Booted', ...Array(5).fill('ShuttingDown'), 'Shutdown'],
    failedLookups: 1,
  });
  assert.equal(result.manifest.incomplete, false);
  assert.deepEqual(result.delays, Array(5).fill(200));
  assert.deepEqual(result.manifest.resolution, {
    stage: 'complete',
    state: 'Shutdown',
    stateReads: 7,
    lookupAttempts: 2,
    bootAttempts: 1,
  });
});

test('transition exhaustion fails after six state reads and five delays', async (t) => {
  const result = await resolutionScenario(t, { states: ['ShuttingDown'] });
  assert.equal(result.manifest.incomplete, true);
  assert.equal(result.manifest.copiedFiles, 0);
  assert.deepEqual(result.operations, Array(6).fill('list'));
  assert.deepEqual(result.delays, Array(5).fill(200));
  assert.deepEqual(result.manifest.resolution, {
    stage: 'waiting-shutdown',
    state: 'ShuttingDown',
    stateReads: 6,
    lookupAttempts: 0,
    bootAttempts: 0,
  });
});

test('two waits remain bounded without resetting the shared boot budget', async (t) => {
  const result = await resolutionScenario(t, {
    states: [...Array(5).fill('ShuttingDown'), 'Shutdown', ...Array(6).fill('ShuttingDown')],
    failedLookups: 1,
  });
  assert.equal(result.manifest.incomplete, true);
  assert.equal(result.manifest.resolution.stateReads, 12);
  assert.equal(result.manifest.resolution.bootAttempts, 1);
  assert.equal(result.manifest.resolution.lookupAttempts, 1);
  assert.deepEqual(result.delays, Array(10).fill(200));
  assert.equal(result.operations.filter((operation) => operation === 'bootstatus').length, 1);
});

for (const state of [null, 'Booting', 'secret arbitrary /state', { secret: 'untrusted' }]) {
  test(`unavailable or unsupported state ${JSON.stringify(state)} fails without a device mutation`, async (t) => {
    const result = await resolutionScenario(t, { states: [state] });
    assert.equal(result.manifest.incomplete, true);
    assert.deepEqual(result.operations, ['list']);
    assert.deepEqual(result.manifest.resolution, {
      stage: 'state',
      state: state === null ? 'Missing' : 'Unknown',
      stateReads: 1,
      lookupAttempts: 0,
      bootAttempts: 0,
    });
    assert.equal(JSON.stringify(result.manifest).includes('secret'), false);
    assert.equal(JSON.stringify(result.manifest).includes('unrelated-id'), false);
  });
}

for (const failCommand of ['boot', 'bootstatus']) {
  test(`failed ${failCommand} stops recovery without spending another boot`, async (t) => {
    const result = await resolutionScenario(t, { states: ['Shutdown'], failCommand });
    assert.equal(result.manifest.incomplete, true);
    assert.equal(result.manifest.resolution.bootAttempts, 1);
    assert.equal(result.manifest.resolution.lookupAttempts, 0);
    assert.equal(result.manifest.resolution.stage, failCommand);
    assert.equal(result.operations.filter((operation) => operation === 'boot').length, 1);
    assert.equal(JSON.stringify(result.manifest).includes('secret'), false);
  });
}

// Exercise the runner's actual catch/finally block in isolation. The UI workflow
// is deliberately excluded; this regression concerns failure and cleanup order.
async function runnerFailureHandler() {
  const source = await fs.readFile(new URL('../test-native-app.mjs', import.meta.url), 'utf8');
  const tail = source.slice(source.indexOf('\n} catch (error) {\n') + 1);
  assert.ok(tail.startsWith('} catch (error) {'));
  return new (Object.getPrototypeOf(async function () {}).constructor)(
    'original',
    'simulator',
    'artifact',
    'run',
    'preserveNativeFailureArtifacts',
    'proxy',
    'api',
    'join',
    'console',
    `let nativeFailed = false; const streaming = true; try { throw original; ${tail}`,
  );
}

test('runner retains the original native failure when artifact capture and cleanup also fail', async () => {
  const handler = await runnerFailureHandler();
  const original = new Error('original native failure');
  const events = [];
  await assert.rejects(
    handler(
      original,
      'owned-id',
      '/artifact',
      async (binary, args, name) => {
        events.push(name);
        throw new Error('secondary process failure');
      },
      async () => {
        events.push('preserve');
        throw new Error('secondary filesystem failure');
      },
      {
        stop: async () => {
          events.push('proxy');
          throw new Error('proxy failure');
        },
      },
      {
        stop: async () => {
          events.push('api');
        },
      },
      join,
      { warn: () => {} },
    ),
    (error) => error === original,
  );
  assert.ok(events.includes('preserve'));
  assert.ok(events.indexOf('preserve') < events.indexOf('delete'));
  assert.ok(events.includes('proxy'));
  assert.ok(events.includes('api'));
  assert.ok(events.includes('shutdown'));
  assert.ok(events.includes('delete'));
});
