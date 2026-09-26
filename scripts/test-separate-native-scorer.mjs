import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import {
  physicalRecoveryOptions,
  readPhysicalRecoveryInputs,
  verifyPhysicalRecoveryInputs,
  configurePhysicalTestRunPython,
} from './test-physical-recovery.mjs';
import { startDeviceLab } from './device-lab.mjs';
import { isPrivateLabIPv4 } from './private-lab-network.mjs';
import { runOrdinaryCommand, requireOrdinaryTestResult } from './test-ordinary-native-app.mjs';
const root = fileURLToPath(new URL('..', import.meta.url));
export const separateScorerTests = {
  camera:
    'ScorebugAppUITests/PhysicalStreamingTests/testPhysicalIPhoneWhileSeparateNativePhoneScores',
  scorer:
    'ScorebugAppUITests/PhysicalStreamingTests/testSeparateNativeScorerWhileOtherPhonePublishes',
};
export function separateScorerOptions(args, interfaces) {
  for (let i = 0; i < args.length; i += 2)
    assert(
      ['--device', '--host', '--team', '--encoder'].includes(args[i]),
      'Unknown separate scorer option',
    );
  const { lane, ...options } = physicalRecoveryOptions(args, interfaces);
  return options;
}
export function separateScorerEnvironment(lab, role) {
  assert(['camera', 'scorer'].includes(role), 'Invalid native role');
  const endpoint = lab.setup.endpoint;
  const literal = /^http:\/\/([0-9]+(?:\.[0-9]+){3}):([1-9][0-9]*)$/.exec(endpoint);
  const parsed = new URL(endpoint);
  assert(
    literal && literal[1] === parsed.hostname && isPrivateLabIPv4(literal[1]),
    'Canonical private HTTP endpoint required',
  );
  assert(
    typeof lab.setup.installationToken === 'string' && lab.setup.installationToken.length > 0,
    'Installation token required',
  );
  return {
    SCOREBUG_DEVICE_API_URL: endpoint,
    SCOREBUG_DEVICE_TOKEN: lab.setup.installationToken,
    [role === 'camera' ? 'SCOREBUG_PHYSICAL_SEPARATE_SCORER' : 'SCOREBUG_SEPARATE_NATIVE_SCORER']:
      '1',
  };
}
export async function recordScorerCaptureInventory(container, destination) {
  const recordingRoot = join(container, 'Library/Application Support/Scorebug/Recordings');
  const entries = await readdir(recordingRoot).catch((error) => {
    if (error.code === 'ENOENT') return [];
    throw error;
  });
  const exports = entries.includes('Exports') ? await readdir(join(recordingRoot, 'Exports')) : [];
  const noLocalRecordings = entries.every((name) => name === 'Exports') && exports.length === 0;
  const report = { noLocalRecordings, recordingEntries: entries, exportEntries: exports };
  await writeFile(destination, JSON.stringify(report, null, 2), { flag: 'wx', mode: 0o600 });
  return report;
}
async function hash(path) {
  const bytes = await readFile(path);
  return { path, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
}
async function main() {
  assert.equal(process.platform, 'darwin');
  const options = separateScorerOptions(process.argv.slice(2));
  await mkdir(join(root, 'artifacts/qa'), { recursive: true });
  const artifact = await mkdtemp(join(root, 'artifacts/qa/separate-native-scorer-'));
  await chmod(artifact, 0o700);
  const controller = new AbortController(),
    commands = [],
    cleanupFailures = [],
    outcomes = {};
  const interrupt = () => controller.abort();
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', interrupt);
  const run = (command, args, label, timeout = 60000, cleanup = false) =>
    runOrdinaryCommand(command, args, {
      artifact,
      label,
      timeout,
      commands,
      ...(cleanup ? {} : { signal: controller.signal }),
    });
  let simulator,
    lab,
    cameraJob,
    scorerJob,
    sourceHead,
    failure,
    workflowPassed = false;
  console.log(
    JSON.stringify({
      artifact,
      scope: 'Physical camera and separate native simulator scorer; media qualification separate',
    }),
  );
  try {
    sourceHead = await run('git', ['rev-parse', 'HEAD'], 'source-head');
    assert.equal(
      await run(
        'git',
        [
          'status',
          '--porcelain',
          '--untracked-files=normal',
          '--',
          'ios',
          'vendor',
          'apps',
          'packages',
          'scripts',
        ],
        'source-cleanliness',
      ),
      '',
      'Commit reviewed source before building the native experiment',
    );
    const runtimes = JSON.parse(
      await run('xcrun', ['simctl', 'list', 'runtimes', '-j'], 'runtimes'),
    );
    const runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-2';
    assert(
      runtimes.runtimes.some((r) => r.identifier === runtime && r.isAvailable),
      'Installed iOS26.2 runtime required; no downloads',
    );
    const phoneDerived = join(root, 'ios/DerivedData/PhysicalPhone'),
      simDerived = join(root, 'ios/DerivedData/SeparateScorerSimulator');
    for (const [name, derived, destination, signing] of [
      [
        'phone',
        phoneDerived,
        'generic/platform=iOS',
        [`DEVELOPMENT_TEAM=${options.team}`, '-allowProvisioningUpdates'],
      ],
      ['simulator', simDerived, 'generic/platform=iOS Simulator', ['CODE_SIGNING_ALLOWED=NO']],
    ])
      await run(
        'xcodebuild',
        [
          '-project',
          join(root, 'ios/Scorebug.xcodeproj'),
          '-scheme',
          'Scorebug',
          '-configuration',
          'Debug',
          '-destination',
          destination,
          '-derivedDataPath',
          derived,
          ...signing,
          'build-for-testing',
        ],
        `build-${name}`,
        900000,
      );
    simulator = await run(
      'xcrun',
      [
        'simctl',
        'create',
        `Scorebug Separate Scorer ${randomUUID()}`,
        'com.apple.CoreSimulator.SimDeviceType.iPhone-14',
        runtime,
      ],
      'create-simulator',
    );
    assert.match(simulator, /^[0-9A-F-]{36}$/i);
    await run('xcrun', ['simctl', 'boot', simulator], 'boot-simulator');
    await run('xcrun', ['simctl', 'bootstatus', simulator, '-b'], 'simulator-ready', 120000);
    const lockPath = join(artifact, 'phone-lock.json');
    await run(
      'xcrun',
      [
        'devicectl',
        'device',
        'info',
        'lockState',
        '--device',
        options.device,
        '--timeout',
        '20',
        '--json-output',
        lockPath,
      ],
      'phone-readiness',
      30000,
    );
    assert.equal(
      JSON.parse(await readFile(lockPath)).result?.passcodeRequired,
      false,
      'Physical phone must be unlocked',
    );
    const phoneProducts = join(phoneDerived, 'Build/Products'),
      simProducts = join(simDerived, 'Build/Products');
    const simRuns = (await readdir(simProducts)).filter((n) => n.endsWith('.xctestrun'));
    assert.equal(simRuns.length, 1);
    const roles = {
      camera: {
        device: options.device,
        products: phoneProducts,
        sourceRun: join(phoneProducts, 'Scorebug_iphoneos26.2-arm64.xctestrun'),
        allowance: 480,
        timeout: 600000,
      },
      scorer: {
        device: simulator,
        products: simProducts,
        sourceRun: join(simProducts, simRuns[0]),
        allowance: 480,
        timeout: 600000,
      },
    };
    const inputs = await readPhysicalRecoveryInputs(phoneProducts, [
      fileURLToPath(import.meta.url),
      join(root, 'scripts/test-physical-recovery.mjs'),
      join(root, 'ios/AppUITests/PhysicalStreamingTests.swift'),
      join(root, 'ios/Project.yml'),
      join(root, 'scripts/device-lab.mjs'),
      join(root, 'scripts/test-ordinary-native-app.mjs'),
      roles.scorer.sourceRun,
      ...[
        'Scorebug.app/Scorebug',
        'Scorebug.app/Scorebug.debug.dylib',
        'ScorebugAppUITests-Runner.app/ScorebugAppUITests-Runner',
        'ScorebugAppUITests-Runner.app/PlugIns/ScorebugAppUITests.xctest/ScorebugAppUITests',
      ].map((p) => join(simProducts, 'Debug-iphonesimulator', p)),
    ]);
    lab = await startDeviceLab(options, { signal: controller.signal });
    const configure = join(artifact, 'configure.py');
    await writeFile(configure, configurePhysicalTestRunPython, { flag: 'wx', mode: 0o600 });
    for (const [name, role] of Object.entries(roles)) {
      const environment = join(artifact, `${name}-environment.json`);
      role.privateRun = join(artifact, `${name}.xctestrun`);
      await writeFile(environment, JSON.stringify(separateScorerEnvironment(lab, name)), {
        flag: 'wx',
        mode: 0o600,
      });
      await run(
        'python3',
        [
          configure,
          role.sourceRun,
          role.privateRun,
          'ScorebugAppUITests',
          environment,
          role.products,
        ],
        `configure-${name}`,
      );
      inputs.push(await hash(role.privateRun));
    }
    await writeFile(
      join(artifact, 'inputs.json'),
      JSON.stringify({ sourceHead, inputs }, null, 2),
      { flag: 'wx', mode: 0o600 },
    );
    async function workflow(name) {
      const role = roles[name],
        resultBundle = join(artifact, `${name}.xcresult`);
      try {
        await run(
          'xcodebuild',
          [
            'test-without-building',
            '-xctestrun',
            role.privateRun,
            '-destination',
            `id=${role.device}`,
            '-destination-timeout',
            '120',
            '-resultBundlePath',
            resultBundle,
            '-parallel-testing-enabled',
            'NO',
            '-maximum-test-execution-time-allowance',
            String(role.allowance),
            `-only-testing:${separateScorerTests[name]}`,
          ],
          `${name}-workflow`,
          role.timeout,
        );
        const summary = JSON.parse(
          await run(
            'xcrun',
            ['xcresulttool', 'get', 'test-results', 'summary', '--path', resultBundle],
            `${name}-summary`,
          ),
        );
        const tests = JSON.parse(
          await run(
            'xcrun',
            ['xcresulttool', 'get', 'test-results', 'tests', '--path', resultBundle],
            `${name}-tests`,
          ),
        );
        requireOrdinaryTestResult(summary, tests, separateScorerTests[name]);
        outcomes[name] = { passed: true };
      } catch (error) {
        outcomes[name] = { passed: false, error: String(error.message) };
      }
    }
    let scorerDone = false;
    scorerJob = workflow('scorer').finally(() => {
      scorerDone = true;
    });
    let ready = false;
    const readyDeadline = performance.now() + 120000;
    while (!scorerDone && performance.now() < readyDeadline && !controller.signal.aborted) {
      const log = await readFile(join(artifact, 'scorer-workflow.log'), 'utf8').catch(() => '');
      if (log.includes("Added attachment named 'SeparateNativeScorer-ready'")) {
        ready = true;
        break;
      }
      await delay(250);
    }
    assert(
      ready,
      'Scorer did not reach its native joined readiness marker; camera was not started',
    );
    console.log(
      JSON.stringify({ artifact, phase: 'Separate native scorer ready; starting physical camera' }),
    );
    cameraJob = workflow('camera');
    await Promise.all([cameraJob, scorerJob]);
    await verifyPhysicalRecoveryInputs(inputs);
    assert(
      outcomes.camera?.passed && outcomes.scorer?.passed,
      'Native role workflow failed; preserve both results',
    );
    workflowPassed = true;
  } catch (error) {
    failure = String(error.message);
  } finally {
    await Promise.allSettled([cameraJob, scorerJob].filter(Boolean));
    try {
      await lab?.stop();
    } catch (error) {
      cleanupFailures.push(`lab: ${error.message}`);
    }
    if (simulator) {
      if (scorerJob) {
        try {
          const container = await run(
            'xcrun',
            ['simctl', 'get_app_container', simulator, 'live.scorebug.app', 'data'],
            'scorer-container',
            60000,
            true,
          );
          const inventory = await recordScorerCaptureInventory(
            container,
            join(artifact, 'scorer-camera-free.json'),
          );
          assert(
            inventory.noLocalRecordings,
            'Separate scorer unexpectedly created a recording; inventory retained',
          );
        } catch (error) {
          await writeFile(
            join(artifact, 'scorer-inventory-error.json'),
            JSON.stringify({ error: String(error.message) }),
            { flag: 'wx', mode: 0o600 },
          );
          failure ??= String(error.message);
        }
      }
      try {
        await run('xcrun', ['simctl', 'shutdown', simulator], 'shutdown-simulator', 60000, true);
      } catch (error) {
        cleanupFailures.push(`simulator shutdown: ${error.message}`);
      }
      try {
        await run('xcrun', ['simctl', 'delete', simulator], 'delete-simulator', 60000, true);
      } catch (error) {
        cleanupFailures.push(`simulator delete: ${error.message}`);
      }
    }
    workflowPassed = workflowPassed && !failure && !cleanupFailures.length;
    await writeFile(
      join(artifact, 'result.json'),
      JSON.stringify(
        {
          formatVersion: 1,
          lane: 'separate-native-scorer',
          sourceHead,
          device: options.device,
          simulator,
          labArtifact: lab?.artifact,
          outcomes,
          workflowPassed,
          mediaQualified: false,
          failure,
          cleanupFailures,
          commands,
        },
        null,
        2,
      ),
      { flag: 'wx', mode: 0o600 },
    );
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
  }
  console.log(
    JSON.stringify({ artifact, workflowPassed, mediaQualified: false, failure, cleanupFailures }),
  );
  if (!workflowPassed) process.exitCode = 1;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href)
  await main();
