import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { chmod, cp, mkdir, mkdtemp, readdir, writeFile } from 'node:fs/promises';
import { networkInterfaces } from 'node:os';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deviceLabOptions, startDeviceLab } from './device-lab.mjs';
import { nativeFileFixtureHash, stageNativeFileFixture } from './native-file-fixture.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const developer = '/Applications/Xcode-26.2.0.app/Contents/Developer';
const runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-2';
const testID =
  'ScorebugAppUITests/PhysicalStreamingTests/testOrdinarySimulatorPublishScoreAdaptStopAndExport';

export function ordinaryNativeOptions(args, interfaces = networkInterfaces()) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index],
      value = args[index + 1];
    assert(
      ['--host', '--source', '--encoder'].includes(key) && value && !values.has(key),
      'Invalid or duplicate ordinary simulator option',
    );
    values.set(key, value);
  }
  const source = values.get('--source');
  assert(source && isAbsolute(source), 'Supply --source with the absolute prepared input path');
  const { host, encoder } = deviceLabOptions(
    ['--host', values.get('--host'), '--encoder', values.get('--encoder') ?? 'software'],
    interfaces,
  );
  return { host, source, encoder };
}

export function ordinaryEnvironment(environment = process.env) {
  return {
    ...Object.fromEntries(Object.entries(environment).filter(([key]) => !key.includes('SCOREBUG'))),
    DEVELOPER_DIR: developer,
  };
}

/** Each finite command owns a process group. Timeout/signal kills descendants and joins the leader. */
export async function runOrdinaryCommand(
  command,
  args,
  { artifact, label, timeout = 60_000, grace = 3_000, signal, commands } = {},
) {
  signal?.throwIfAborted();
  commands?.push({ command, args, label }); // Callers never put credentials in argv.
  const log = createWriteStream(join(artifact, `${label}.log`), { flags: 'wx', mode: 0o600 });
  const child = spawn(command, args, {
    cwd: root,
    env: ordinaryEnvironment(),
    detached: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '',
    timedOut = false,
    interrupted = false,
    forceTimer;
  const kill = (signalName) => {
    try {
      process.kill(-child.pid, signalName);
    } catch (error) {
      if (error.code !== 'ESRCH') throw error;
    }
  };
  const stop = () => {
    kill('SIGTERM');
    forceTimer ??= setTimeout(() => kill('SIGKILL'), grace);
  };
  const abort = () => {
    interrupted = true;
    stop();
  };
  child.stdout.on('data', (chunk) => {
    output = (output + chunk.toString()).slice(-2 * 1024 * 1024);
  });
  child.stdout.pipe(log, { end: false });
  child.stderr.pipe(log, { end: false });
  const timer = setTimeout(() => {
    timedOut = true;
    stop();
  }, timeout);
  signal?.addEventListener('abort', abort, { once: true });
  try {
    const result = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', (code, signal) => resolve({ code, signal }));
    });
    // A leader may exit before its descendants; do not leave its process group running.
    kill('SIGKILL');
    let groupJoined = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        process.kill(-child.pid, 0);
      } catch (error) {
        if (error.code === 'ESRCH') {
          groupJoined = true;
          break;
        }
        throw error;
      }
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert(groupJoined, `${label} process group did not finish after SIGKILL`);
    if (timedOut) throw new Error(`${label} timed out; inspect its private log`);
    if (interrupted) throw new Error(`${label} interrupted; inspect its private log`);
    assert.equal(
      result.code,
      0,
      `${label} failed (${result.code ?? result.signal}); inspect its private log`,
    );
    return output.trim();
  } finally {
    clearTimeout(timer);
    clearTimeout(forceTimer);
    signal?.removeEventListener('abort', abort);
    await new Promise((resolve) => log.end(resolve));
  }
}

async function main() {
  const options = ordinaryNativeOptions(process.argv.slice(2));
  assert.equal(process.platform, 'darwin', 'Installed Xcode and iOS simulator required');
  const sourceSHA256 = await nativeFileFixtureHash(options.source);
  await mkdir(join(root, 'artifacts/qa'), { recursive: true });
  const artifact = await mkdtemp(join(root, 'artifacts/qa/ordinary-native-'));
  await chmod(artifact, 0o700);
  console.log(JSON.stringify({ artifact, scope: 'ordinary simulator file-source smoke' }));
  const controller = new AbortController(),
    commands = [];
  const interrupt = () => controller.abort();
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', interrupt);
  const run = (command, args, label, extra = {}) =>
    runOrdinaryCommand(command, args, {
      artifact,
      label,
      commands,
      signal: controller.signal,
      ...extra,
    });
  const cleanup = (command, args, label) => run(command, args, label, { signal: undefined });
  let simulator,
    lab,
    container,
    failure,
    head,
    workflowPassed = false;
  const cleanupFailures = [];
  try {
    head = await run('git', ['rev-parse', 'HEAD'], 'head');
    const runtimes = JSON.parse(
      await run('xcrun', ['simctl', 'list', 'runtimes', '--json'], 'runtimes'),
    );
    assert(
      runtimes.runtimes.some((entry) => entry.identifier === runtime && entry.isAvailable),
      'Installed iOS 26.2 runtime required; no downloads are performed',
    );
    simulator = await run(
      'xcrun',
      [
        'simctl',
        'create',
        `Scorebug Ordinary ${randomUUID()}`,
        'com.apple.CoreSimulator.SimDeviceType.iPhone-14',
        runtime,
      ],
      'create',
    );
    assert.match(simulator, /^[0-9a-f-]{36}$/i);
    await run('xcrun', ['simctl', 'boot', simulator], 'boot');
    await run('xcrun', ['simctl', 'bootstatus', simulator, '-b'], 'boot-ready', {
      timeout: 120_000,
    });
    const derived = join(root, 'ios/DerivedData/OrdinaryNativeApp');
    await run(
      'xcodebuild',
      [
        '-project',
        'ios/Scorebug.xcodeproj',
        '-scheme',
        'Scorebug',
        '-configuration',
        'Debug',
        '-derivedDataPath',
        derived,
        '-destination',
        `platform=iOS Simulator,id=${simulator}`,
        '-destination-timeout',
        '60',
        'build-for-testing',
        `-only-testing:${testID}`,
        'ARCHS=arm64',
        'ONLY_ACTIVE_ARCH=YES',
        'CODE_SIGNING_ALLOWED=YES',
        'CODE_SIGN_IDENTITY=-',
      ],
      'build',
      { timeout: 900_000 },
    );
    const products = join(derived, 'Build/Products');
    await run(
      'xcrun',
      ['simctl', 'install', simulator, join(products, 'Debug-iphonesimulator/Scorebug.app')],
      'install',
    );
    container = await run(
      'xcrun',
      ['simctl', 'get_app_container', simulator, 'live.scorebug.app', 'data'],
      'container',
    );
    const staged = join(container, 'Library/Application Support/Scorebug/QA/input.mov');
    await stageNativeFileFixture({
      source: options.source,
      destination: staged,
      sha256: sourceSHA256,
    });
    await writeFile(
      join(artifact, 'source.json'),
      JSON.stringify(
        { source: options.source, sourceSHA256, stagedSHA256: sourceSHA256 },
        null,
        2,
      ) + '\n',
      { mode: 0o600 },
    );
    controller.signal.throwIfAborted();
    lab = await startDeviceLab(
      { host: options.host, encoder: options.encoder, duration: 600 },
      { signal: controller.signal },
    );
    const configs = (await readdir(products)).filter(
      (name) => name.startsWith('Scorebug_') && name.endsWith('.xctestrun'),
    );
    assert.equal(configs.length, 1, 'One built test configuration required');
    // Private plist carries credentials to the test runner. No credentials in argv, command manifests or console output.
    const privateRun = join(artifact, 'ordinary.xctestrun');
    const configure = join(artifact, 'configure.py');
    await writeFile(
      configure,
      `import json, plistlib, sys, os\nsource, destination, setup_path, products = sys.argv[1:]\nwith open(source, 'rb') as f: config = plistlib.load(f)\nwith open(setup_path) as f: setup = json.load(f)\ndef clean(value):\n    if isinstance(value, dict): return {key: clean(item) for key, item in value.items() if 'SCOREBUG' not in key}\n    if isinstance(value, list): return [clean(item) for item in value]\n    if isinstance(value, str): return value.replace('__TESTROOT__', products)\n    return value\nconfig = clean(config)\nconfigured = []\ndef configure(value):\n    if isinstance(value, dict):\n        if value.get('BlueprintName') == 'ScorebugAppUITests':\n            configured.append(value['BlueprintName'])\n            value.setdefault('EnvironmentVariables', {}).update({'SCOREBUG_DEVICE_API_URL': setup['endpoint'], 'SCOREBUG_DEVICE_TOKEN': setup['installationToken'], 'SCOREBUG_ORDINARY_SIMULATOR': '1'})\n        for child in value.values(): configure(child)\n    elif isinstance(value, list):\n        for child in value: configure(child)\nconfigure(config)\nassert len(configured) == 1, 'Exactly one ScorebugAppUITests target required'\nwith open(destination, 'xb') as f: plistlib.dump(config, f)\nos.chmod(destination, 0o600)\n`,
      { mode: 0o600 },
    );
    await run(
      'python3',
      [
        configure,
        join(products, configs[0]),
        privateRun,
        join(lab.artifact, 'setup.json'),
        products,
      ],
      'configure',
    );
    console.log(
      JSON.stringify({
        simulator,
        labArtifact: lab.artifact,
        head,
        sourceSHA256,
        phase: 'launching ordinary workflow',
      }),
    );
    await run(
      'xcodebuild',
      [
        'test-without-building',
        '-xctestrun',
        privateRun,
        '-destination',
        `platform=iOS Simulator,id=${simulator}`,
        '-destination-timeout',
        '60',
        '-parallel-testing-enabled',
        'NO',
        '-maximum-concurrent-test-simulator-destinations',
        '1',
        '-collect-test-diagnostics',
        'never',
        '-test-timeouts-enabled',
        'YES',
        '-default-test-execution-time-allowance',
        '480',
        '-maximum-test-execution-time-allowance',
        '480',
        '-resultBundlePath',
        join(artifact, 'workflow.xcresult'),
        `-only-testing:${testID}`,
      ],
      'workflow',
      { timeout: 600_000 },
    );
    const summary = JSON.parse(
      await run(
        'xcrun',
        [
          'xcresulttool',
          'get',
          'test-results',
          'summary',
          '--path',
          join(artifact, 'workflow.xcresult'),
        ],
        'test-summary',
      ),
    );
    assert(
      summary.result === 'Passed' &&
        summary.totalTestCount === 1 &&
        summary.passedTests === 1 &&
        summary.failedTests === 0 &&
        summary.skippedTests === 0,
      'Ordinary method must execute and pass exactly once without skips',
    );
    workflowPassed = true;
  } catch (error) {
    failure = error.message;
  } finally {
    // Preserve app-owned media even if the UI workflow failed. Never delete an unpreserved container.
    let preserved = !container;
    if (simulator && container) {
      try {
        const devices = JSON.parse(
          await cleanup('xcrun', ['simctl', 'list', 'devices', '--json'], 'preserve-device-state'),
        );
        const device = Object.values(devices.devices)
          .flat()
          .find((entry) => entry.udid === simulator);
        assert(device, 'Owned simulator disappeared before media preservation');
        if (device.state !== 'Booted')
          await cleanup('xcrun', ['simctl', 'boot', simulator], 'boot-for-preservation');
        await cleanup('xcrun', ['simctl', 'bootstatus', simulator, '-b'], 'preserve-ready');
        const latest = await cleanup(
          'xcrun',
          ['simctl', 'get_app_container', simulator, 'live.scorebug.app', 'data'],
          'final-container',
        );
        await cleanup(
          'xcrun',
          ['simctl', 'terminate', simulator, 'live.scorebug.app'],
          'terminate-app',
        ).catch(() => {});
        await cp(latest, join(artifact, 'app-data'), {
          recursive: true,
          errorOnExist: true,
          force: false,
        });
        preserved = true;
      } catch {
        cleanupFailures.push('app-data preservation');
      }
    }
    try {
      await lab?.stop();
    } catch {
      cleanupFailures.push('device lab shutdown');
    }
    if (simulator) {
      await cleanup('xcrun', ['simctl', 'shutdown', simulator], 'shutdown').catch(() => {
        cleanupFailures.push('simulator shutdown');
      });
      if (preserved)
        await cleanup('xcrun', ['simctl', 'delete', simulator], 'delete').catch(() => {
          cleanupFailures.push('simulator deletion');
        });
    }
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
    const outcome = {
      head,
      sourceSHA256,
      simulator,
      labArtifact: lab?.artifact,
      workflowPassed,
      mediaQualified: false,
      failure,
      cleanupFailures,
      commands,
    };
    await writeFile(join(artifact, 'result.json'), JSON.stringify(outcome, null, 2) + '\n', {
      mode: 0o600,
    });
    console.log(
      JSON.stringify({ artifact, workflowPassed, mediaQualified: false, failure, cleanupFailures }),
    );
  }
  if (failure || cleanupFailures.length) process.exitCode = 1;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
