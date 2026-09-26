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
const watchRuntime = 'com.apple.CoreSimulator.SimRuntime.watchOS-26-2';
const phoneType = 'com.apple.CoreSimulator.SimDeviceType.iPhone-14';
const watchType = 'com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-7-41mm';
const testID =
  'ScorebugAppUITests/PhysicalStreamingTests/testOrdinarySimulatorPublishScoreAdaptStopAndExport';
const pairedTestID =
  'ScorebugAppUITests/PhysicalStreamingTests/testOrdinaryPairedSimulatorAdaptWatchScoreStopAndExport';
const watchTestID =
  'ScorebugWatchUITests/CompanionWatchScoringTests/testScoreUsingRealCompanionSetup';

export function ordinaryNativeOptions(args, interfaces = networkInterfaces()) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index],
      value = args[index + 1];
    assert(
      ['--host', '--source', '--encoder', '--lane'].includes(key) && value && !values.has(key),
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
  const lane = values.get('--lane');
  assert(lane === undefined || ['phone', 'paired'].includes(lane), 'Unsupported ordinary lane');
  return { host, source, encoder, ...(lane === undefined ? {} : { lane }) };
}

export function ordinaryTestEnvironment({ paired, watch = false, setup }) {
  assert(!watch || paired, 'Watch runner requires the paired lane');
  if (watch) return { SCOREBUG_PAIRED_ORDINARY_SIMULATOR: '1' };
  return {
    SCOREBUG_DEVICE_API_URL: setup.endpoint,
    SCOREBUG_DEVICE_TOKEN: setup.installationToken,
    SCOREBUG_ORDINARY_SIMULATOR: '1',
    ...(paired ? { SCOREBUG_PAIRED_ORDINARY_SIMULATOR: '1' } : {}),
  };
}

export function ordinaryTestConfiguration(files, scheme, isWatch) {
  // This launcher fixes Xcode/SDK 26.2 and arm64. Generic Watch builds may
  // leave an iPhone-named sibling; only the concrete destination is eligible.
  const expected = `${scheme}_${isWatch ? 'watchsimulator' : 'iphonesimulator'}26.2-arm64.xctestrun`;
  const configs = files.filter((file) => file === expected);
  assert.equal(
    configs.length,
    1,
    'Expected destination/SDK/architecture test configuration required',
  );
  return configs[0];
}

// Let the other bounded test finish its stop/export path after a peer fails.
// External cancellation still aborts both process groups through their signal.
export async function joinOrdinaryWorkflows(actions) {
  const results = await Promise.allSettled(actions.map((action) => Promise.resolve().then(action)));
  const failures = results
    .filter((result) => result.status === 'rejected')
    .map((result) => result.reason);
  if (failures.length)
    throw new AggregateError(failures, 'Ordinary workflow failed; inspect both private test logs');
}

export async function recoverOrdinaryOwnership(owner, run) {
  const recovered = { ...owner, failures: [] };
  if (!recovered.simulator || (owner.paired && !recovered.watch)) {
    try {
      const devices = JSON.parse(
        await run('xcrun', ['simctl', 'list', 'devices', '--json'], 'recover-owned-devices'),
      );
      const all = Object.values(devices.devices).flat();
      recovered.simulator ??= all.find((device) => device.name === owner.phoneName)?.udid;
      if (owner.paired)
        recovered.watch ??= all.find((device) => device.name === owner.watchName)?.udid;
    } catch {
      recovered.failures.push('owned simulator discovery');
    }
  }
  if (owner.paired && recovered.simulator && recovered.watch && !recovered.pairId) {
    try {
      const pairs = JSON.parse(
        await run('xcrun', ['simctl', 'list', 'pairs', '--json'], 'recover-owned-pair'),
      );
      recovered.pairId = Object.entries(pairs.pairs).find(
        ([, pair]) =>
          pair.phone?.udid === recovered.simulator && pair.watch?.udid === recovered.watch,
      )?.[0];
    } catch {
      recovered.failures.push('owned pair discovery');
    }
  }
  return recovered;
}

export function requireOrdinaryTestResult(summary, tests, expectedTest) {
  assert(
    summary.result === 'Passed' &&
      summary.totalTestCount === 1 &&
      summary.passedTests === 1 &&
      summary.failedTests === 0 &&
      summary.skippedTests === 0,
    'Ordinary method must execute and pass exactly once without skips',
  );
  const cases = [];
  function visit(node) {
    if (node.nodeType === 'Test Case') cases.push(node);
    for (const child of node.children ?? []) visit(child);
  }
  for (const node of tests.testNodes ?? []) visit(node);
  assert(
    cases.length === 1 &&
      cases[0].result === 'Passed' &&
      cases[0].nodeIdentifierURL?.endsWith(`/${expectedTest}`),
    'The intended ordinary method must execute',
  );
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
  const paired = options.lane === 'paired';
  const phoneTest = paired ? pairedTestID : testID;
  const phoneName = `Scorebug Ordinary ${randomUUID()}`;
  const watchName = `Scorebug Ordinary Watch ${randomUUID()}`;
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
    watch,
    pairId,
    watchContainer,
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
    for (const required of paired ? [runtime, watchRuntime] : [runtime]) {
      assert(
        runtimes.runtimes.some((entry) => entry.identifier === required && entry.isAvailable),
        `Installed ${required} runtime required; no downloads are performed`,
      );
    }
    const types = JSON.parse(
      await run('xcrun', ['simctl', 'list', 'devicetypes', '--json'], 'device-types'),
    );
    for (const required of paired ? [phoneType, watchType] : [phoneType]) {
      assert(
        types.devicetypes.some((entry) => entry.identifier === required),
        'Required simulator device type missing',
      );
    }
    simulator = await run('xcrun', ['simctl', 'create', phoneName, phoneType, runtime], 'create');
    assert.match(simulator, /^[0-9a-f-]{36}$/i);
    if (paired) {
      watch = await run(
        'xcrun',
        ['simctl', 'create', watchName, watchType, watchRuntime],
        'create-watch',
      );
      assert.match(watch, /^[0-9a-f-]{36}$/i);
      pairId = await run('xcrun', ['simctl', 'pair', watch, simulator], 'pair');
      assert.match(pairId, /^[0-9a-f-]{36}$/i);
    }
    await run('xcrun', ['simctl', 'boot', simulator], 'boot');
    if (watch) {
      await run('xcrun', ['simctl', 'boot', watch], 'boot-watch');
      await run('xcrun', ['simctl', 'bootstatus', watch, '-b'], 'watch-ready', {
        timeout: 120_000,
      });
    }
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
        `-only-testing:${phoneTest}`,
        'ARCHS=arm64',
        'ONLY_ACTIVE_ARCH=YES',
        'CODE_SIGNING_ALLOWED=YES',
        'CODE_SIGN_IDENTITY=-',
      ],
      'build',
      { timeout: 900_000 },
    );
    if (watch) {
      await run(
        'xcodebuild',
        [
          '-project',
          'ios/Scorebug.xcodeproj',
          '-scheme',
          'ScorebugWatch',
          '-configuration',
          'Debug',
          '-derivedDataPath',
          derived,
          '-destination',
          `platform=watchOS Simulator,id=${watch}`,
          '-destination-timeout',
          '60',
          'build-for-testing',
          `-only-testing:${watchTestID}`,
          'ARCHS=arm64',
          'ONLY_ACTIVE_ARCH=YES',
          'CODE_SIGNING_ALLOWED=YES',
          'CODE_SIGN_IDENTITY=-',
        ],
        'build-watch',
        { timeout: 900_000 },
      );
    }
    const products = join(derived, 'Build/Products');
    await run(
      'xcrun',
      ['simctl', 'install', simulator, join(products, 'Debug-iphonesimulator/Scorebug.app')],
      'install',
    );
    if (watch) {
      await run(
        'xcrun',
        ['simctl', 'install', watch, join(products, 'Debug-watchsimulator/ScorebugWatch.app')],
        'install-watch',
      );
      watchContainer = await run(
        'xcrun',
        ['simctl', 'get_app_container', watch, 'live.scorebug.app.watchkitapp', 'data'],
        'watch-container',
      );
    }
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
    // Private plists carry only each target's explicit environment; no credentials in argv.
    const configure = join(artifact, 'configure.py');
    await writeFile(
      configure,
      `import json, plistlib, sys, os
source, destination, target, environment_path, products = sys.argv[1:]
with open(source, 'rb') as f: config = plistlib.load(f)
with open(environment_path) as f: environment = json.load(f)
def clean(value):
    if isinstance(value, dict): return {key: clean(item) for key, item in value.items() if 'SCOREBUG' not in key}
    if isinstance(value, list): return [clean(item) for item in value]
    if isinstance(value, str): return value.replace('__TESTROOT__', products)
    return value
config = clean(config)
configured = []
def configure(value):
    if isinstance(value, dict):
        if value.get('BlueprintName') == target:
            configured.append(target)
            value.setdefault('EnvironmentVariables', {}).update(environment)
        for child in value.values(): configure(child)
    elif isinstance(value, list):
        for child in value: configure(child)
configure(config)
assert len(configured) == 1, 'Exactly one intended UI test target required'
with open(destination, 'xb') as f: plistlib.dump(config, f)
os.chmod(destination, 0o600)
`,
      { mode: 0o600 },
    );
    async function privateTestRun(scheme, target, name, isWatch) {
      const config = ordinaryTestConfiguration(await readdir(products), scheme, isWatch);
      const environmentPath = join(artifact, `${name}-environment.json`);
      await writeFile(
        environmentPath,
        JSON.stringify(ordinaryTestEnvironment({ paired, watch: isWatch, setup: lab.setup })),
        { mode: 0o600 },
      );
      const destination = join(artifact, `${name}.xctestrun`);
      await run(
        'python3',
        [configure, join(products, config), destination, target, environmentPath, products],
        `configure-${name}`,
      );
      return destination;
    }
    const privateRun = await privateTestRun('Scorebug', 'ScorebugAppUITests', 'ordinary', false);
    const privateWatchRun = watch
      ? await privateTestRun('ScorebugWatch', 'ScorebugWatchUITests', 'watch', true)
      : null;
    console.log(
      JSON.stringify({
        simulator,
        labArtifact: lab.artifact,
        head,
        sourceSHA256,
        phase: 'launching ordinary workflow',
      }),
    );
    const workflows = [
      { device: simulator, platform: 'iOS', config: privateRun, test: phoneTest, name: 'workflow' },
    ];
    if (watch)
      workflows.push({
        device: watch,
        platform: 'watchOS',
        config: privateWatchRun,
        test: watchTestID,
        name: 'watch-workflow',
      });
    await joinOrdinaryWorkflows(
      workflows.map((workflow) => async () => {
        await run(
          'xcodebuild',
          [
            'test-without-building',
            '-xctestrun',
            workflow.config,
            '-destination',
            `platform=${workflow.platform} Simulator,id=${workflow.device}`,
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
            paired ? '600' : '480',
            '-maximum-test-execution-time-allowance',
            paired ? '600' : '480',
            '-resultBundlePath',
            join(artifact, `${workflow.name}.xcresult`),
            `-only-testing:${workflow.test}`,
          ],
          workflow.name,
          { timeout: paired ? 720_000 : 600_000 },
        );
        const result = [];
        for (const type of ['summary', 'tests'])
          result.push(
            JSON.parse(
              await run(
                'xcrun',
                [
                  'xcresulttool',
                  'get',
                  'test-results',
                  type,
                  '--path',
                  join(artifact, `${workflow.name}.xcresult`),
                ],
                `${workflow.name}-${type}`,
              ),
            ),
          );
        requireOrdinaryTestResult(result[0], result[1], workflow.test);
      }),
    );
    if (paired) {
      const { readOrdinaryPairedEvidence } = await import('./ordinary-paired-evidence.mjs');
      const evidence = await readOrdinaryPairedEvidence(
        join(lab.artifact, 'scorebug.sqlite'),
        lab.setup.matchId,
      );
      await writeFile(
        join(artifact, 'paired-evidence.json'),
        JSON.stringify(evidence, null, 2) + '\n',
        { mode: 0o600 },
      );
    }
    workflowPassed = true;
  } catch (error) {
    failure = error.message;
  } finally {
    // A create/pair command may finish just as its process is interrupted.
    // Recover exact per-run names and both matching IDs, never unrelated devices.
    const ownership = await recoverOrdinaryOwnership(
      { paired, phoneName, watchName, simulator, watch, pairId },
      cleanup,
    );
    ({ simulator, watch, pairId } = ownership);
    cleanupFailures.push(...ownership.failures);
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
    let watchPreserved = !watchContainer;
    if (watch && watchContainer) {
      try {
        const devices = JSON.parse(
          await cleanup('xcrun', ['simctl', 'list', 'devices', '--json'], 'watch-preserve-state'),
        );
        const device = Object.values(devices.devices)
          .flat()
          .find((entry) => entry.udid === watch);
        assert(device, 'Owned Watch disappeared before preservation');
        if (device.state !== 'Booted')
          await cleanup('xcrun', ['simctl', 'boot', watch], 'watch-boot-for-preservation');
        await cleanup('xcrun', ['simctl', 'bootstatus', watch, '-b'], 'watch-preserve-ready');
        const latest = await cleanup(
          'xcrun',
          ['simctl', 'get_app_container', watch, 'live.scorebug.app.watchkitapp', 'data'],
          'watch-final-container',
        );
        await cleanup(
          'xcrun',
          ['simctl', 'terminate', watch, 'live.scorebug.app.watchkitapp'],
          'watch-terminate-app',
        ).catch(() => {});
        await cp(latest, join(artifact, 'watch-app-data'), {
          recursive: true,
          errorOnExist: true,
          force: false,
        });
        watchPreserved = true;
      } catch {
        cleanupFailures.push('Watch app-data preservation');
      }
    }
    try {
      await lab?.stop();
    } catch {
      cleanupFailures.push('device lab shutdown');
    }
    if (watch)
      await cleanup('xcrun', ['simctl', 'shutdown', watch], 'watch-shutdown').catch(() =>
        cleanupFailures.push('Watch shutdown'),
      );
    if (pairId && preserved && watchPreserved)
      await cleanup('xcrun', ['simctl', 'unpair', pairId], 'unpair').catch(() =>
        cleanupFailures.push('pair removal'),
      );
    if (watch && preserved && watchPreserved)
      await cleanup('xcrun', ['simctl', 'delete', watch], 'watch-delete').catch(() =>
        cleanupFailures.push('Watch deletion'),
      );
    if (simulator) {
      await cleanup('xcrun', ['simctl', 'shutdown', simulator], 'shutdown').catch(() => {
        cleanupFailures.push('simulator shutdown');
      });
      if (preserved && watchPreserved)
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
      watch,
      pairId,
      lane: paired ? 'paired' : 'phone',
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
