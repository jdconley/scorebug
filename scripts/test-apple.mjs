import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const runtime = process.env.SCOREBUG_IOS_RUNTIME ?? '26.2';
const runtimeID = `com.apple.CoreSimulator.SimRuntime.iOS-${runtime.replaceAll('.', '-')}`;
let simulator;
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
  const runtimes = JSON.parse(
    await run('xcrun', ['simctl', 'list', 'runtimes', '--json'], { capture: true }),
  );
  if (!runtimes.runtimes.some((item) => item.identifier === runtimeID && item.isAvailable)) {
    throw new Error(
      `Install iOS ${runtime} in Xcode, or set SCOREBUG_IOS_RUNTIME to an installed version`,
    );
  }
  simulator = await run(
    'xcrun',
    [
      'simctl',
      'create',
      `Scorebug Scoring Smoke ${randomUUID()}`,
      'com.apple.CoreSimulator.SimDeviceType.iPhone-15',
      runtimeID,
    ],
    { capture: true },
  );
  console.log(`Dedicated Scorebug simulator: ${simulator}`);
  await run(
    'xcodebuild',
    [
      ...common,
      '-destination',
      `platform=iOS Simulator,id=${simulator}`,
      '-destination-timeout',
      '60',
      '-parallel-testing-enabled',
      'NO',
      '-maximum-concurrent-test-simulator-destinations',
      '1',
      '-resultBundlePath',
      `ios/build/scoring-${randomUUID()}.xcresult`,
      'test',
      'CODE_SIGNING_ALLOWED=NO',
    ],
    { timeout: 600_000 },
  );
  console.log(
    'PASS: shared Swift tests, unsigned iOS 17 deployment build, and native scoring setup UI smoke.',
  );
  console.log('This does not validate scoring, camera/SRT, Watch, or physical devices.');
} catch (error) {
  console.error(error.message);
  console.error(
    'For an incomplete default Xcode installation, set DEVELOPER_DIR to a fully installed Xcode.',
  );
  process.exitCode = 1;
} finally {
  if (simulator) {
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
