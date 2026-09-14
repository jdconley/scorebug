import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startScoringTestServer } from './scoring-test-server.mjs';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const runtime = process.env.SCOREBUG_IOS_RUNTIME ?? '26.2';
const runtimeID = `com.apple.CoreSimulator.SimRuntime.iOS-${runtime.replaceAll('.', '-')}`;
const deviceType = process.env.SCOREBUG_IOS_DEVICE_TYPE ?? 'iPhone-15';
const simulators = [];
const twoPhones = process.argv.includes('--two-phones');
let api;
let databaseDirectory;
let activeProcess;
let interrupted = false;

function stopChild() {
  if (activeProcess?.pid) {
    try {
      process.kill(-activeProcess.pid, 'SIGKILL');
    } catch {
      /* already exited */
    }
  }
}
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    interrupted = true;
    stopChild();
  });
}

function run(command, args, { timeout = 120_000, capture = false, cleanup = false } = {}) {
  if (interrupted && !cleanup) throw new Error('Apple validation interrupted');
  console.log(`> ${command} ${args.join(' ')}`);
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: root,
      env: process.env,
      detached: true,
      stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    });
    activeProcess = child;
    let output = '';
    let timedOut = false;
    child.stdout?.on('data', (chunk) => {
      output += chunk;
    });
    const timer = setTimeout(() => {
      timedOut = true;
      stopChild();
    }, timeout);
    child.on('error', (error) => {
      clearTimeout(timer);
      activeProcess = undefined;
      reject(error);
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      activeProcess = undefined;
      if (code === 0) resolve(output.trim());
      else reject(new Error(`${command} ${timedOut ? 'timed out' : `failed (${code ?? signal})`}`));
    });
  });
}

try {
  if (process.platform !== 'darwin')
    throw new Error('Apple validation requires macOS and full Xcode');
  await run('xcodebuild', ['-version']);
  await run('xcodegen', ['generate', '--spec', 'ios/Scoring.yml']);
  await run('swift', [
    'test',
    '--package-path',
    'ios/Packages/ScorebugCore',
    '--scratch-path',
    'ios/.build/core',
  ]);
  await run(
    'xcodebuild',
    [
      '-project',
      'ios/ScorebugScoring.xcodeproj',
      '-scheme',
      'ScorebugScoringModelTests',
      '-configuration',
      'Debug',
      '-derivedDataPath',
      'ios/DerivedData/ScoringModel',
      '-destination',
      'platform=macOS',
      'test',
      'CODE_SIGNING_ALLOWED=YES',
      'CODE_SIGN_IDENTITY=-',
    ],
    { timeout: 600_000 },
  );
  const common = [
    '-project',
    'ios/ScorebugScoring.xcodeproj',
    '-scheme',
    'ScorebugScoring',
    '-configuration',
    'Debug',
    '-derivedDataPath',
    'ios/DerivedData/Scoring',
  ];
  await run(
    'xcodebuild',
    [
      ...common,
      '-destination',
      'generic/platform=iOS',
      'build',
      'CODE_SIGNING_ALLOWED=NO',
      'IPHONEOS_DEPLOYMENT_TARGET=17.0',
    ],
    { timeout: 600_000 },
  );
  databaseDirectory = await mkdtemp(join(tmpdir(), 'scorebug-apple-'));
  api = await startScoringTestServer(join(databaseDirectory, 'matches.sqlite'));
  const runtimes = JSON.parse(
    await run('xcrun', ['simctl', 'list', 'runtimes', '--json'], { capture: true }),
  );
  if (!runtimes.runtimes.some((item) => item.identifier === runtimeID && item.isAvailable)) {
    throw new Error(
      `Install iOS ${runtime} in Xcode, or set SCOREBUG_IOS_RUNTIME to an installed version`,
    );
  }
  async function createSimulator(role) {
    const id = await run(
      'xcrun',
      [
        'simctl',
        'create',
        `Scorebug Scoring ${role} ${randomUUID()}`,
        `com.apple.CoreSimulator.SimDeviceType.${deviceType}`,
        runtimeID,
      ],
      { capture: true },
    );
    simulators.push(id);
    console.log(`Dedicated Scorebug simulator (${role}): ${id}`);
    return id;
  }
  async function testSimulator(id, scenario) {
    await run(
      'xcodebuild',
      [
        ...common,
        '-destination',
        `platform=iOS Simulator,id=${id}`,
        '-destination-timeout',
        '60',
        '-parallel-testing-enabled',
        'NO',
        '-maximum-concurrent-test-simulator-destinations',
        '1',
        '-resultBundlePath',
        `ios/build/scoring-${scenario}-${randomUUID()}.xcresult`,
        'test',
        `SCOREBUG_TEST_API_URL=${api.baseURL}`,
        `SCOREBUG_TEST_SCENARIO=${scenario}`,
        'CODE_SIGNING_ALLOWED=YES',
        'CODE_SIGN_IDENTITY=-',
      ],
      { timeout: 600_000 },
    );
  }
  const first = await createSimulator('A');
  if (twoPhones) {
    await testSimulator(first, 'create');
    const second = await createSimulator('B');
    await testSimulator(second, 'join');
    await testSimulator(first, 'observe');
  } else {
    await testSimulator(first, 'lifecycle');
  }
  console.log(
    `PASS: shared Swift tests, unsigned iOS 17 deployment build, and native scoring ${twoPhones ? 'across two phone simulators' : 'lifecycle'}.`,
  );
  console.log(
    'Camera/SRT, Watch, and physical-device behavior remain separate qualification gates.',
  );
} catch (error) {
  console.error(error.message);
  console.error(
    'For an incomplete default Xcode installation, set DEVELOPER_DIR to a fully installed Xcode.',
  );
  process.exitCode = 1;
} finally {
  if (api) await api.stop();
  if (databaseDirectory) await rm(databaseDirectory, { recursive: true, force: true });
  for (const simulator of simulators) {
    const devices = await run('xcrun', ['simctl', 'list', 'devices', '--json'], {
      capture: true,
      cleanup: true,
    })
      .then(JSON.parse)
      .catch(() => undefined);
    const state =
      devices &&
      Object.values(devices.devices)
        .flat()
        .find((item) => item.udid === simulator)?.state;
    if (state && state !== 'Shutdown') {
      await run('xcrun', ['simctl', 'shutdown', simulator], { cleanup: true }).catch(() => {});
    }
    await run('xcrun', ['simctl', 'delete', simulator], { cleanup: true }).catch((error) => {
      console.error(`Could not remove dedicated simulator ${simulator}: ${error.message}`);
      process.exitCode = 1;
    });
  }
}
