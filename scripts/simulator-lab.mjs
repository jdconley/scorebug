import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { chmod, mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deviceLabOptions, startDeviceLab } from './device-lab.mjs';
import {
  ordinaryEnvironment,
  runOrdinaryCommand,
  issueOrdinaryDirectWatchFixture,
} from './test-ordinary-native-app.mjs';
import { nativeFileFixtureHash, stageNativeFileFixture } from './native-file-fixture.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const execute = promisify(execFile);

export function simulatorLabOptions(args) {
  const labArgs = [];
  let source;
  for (let i = 0; i < args.length; i += 2) {
    if (args[i] === '--source') {
      assert(
        !source && args[i + 1] && isAbsolute(args[i + 1]),
        'One absolute source path required',
      );
      source = args[i + 1];
    } else {
      assert(
        ['--host', '--duration', '--worker-image'].includes(args[i]),
        'Use --host, --duration, optional --source and --worker-image',
      );
      labArgs.push(args[i], args[i + 1]);
    }
  }
  return { ...deviceLabOptions(labArgs), source, apiLoopback: true };
}

async function main() {
  assert.equal(process.platform, 'darwin', 'The simulator lab requires macOS');
  const options = simulatorLabOptions(process.argv.slice(2));
  // Validate the optional source before allocating services/devices.
  const sourceHash = options.source ? await nativeFileFixtureHash(options.source) : undefined;
  await mkdir(join(root, 'artifacts/qa'), { recursive: true });
  const artifact = await mkdtemp(join(root, 'artifacts/qa/manual-simulators-'));
  await chmod(artifact, 0o700);
  const controller = new AbortController();
  const interrupt = () => controller.abort();
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', interrupt);
  const roles = {};
  let lab, timer;
  const save = () =>
    writeFile(join(artifact, 'devices.json'), JSON.stringify(roles, null, 2), { mode: 0o600 });
  const run = (binary, args, label, timeout = 60000) =>
    runOrdinaryCommand(binary, args, {
      artifact,
      label,
      timeout,
      signal: controller.signal,
    });
  console.log(JSON.stringify({ starting: true, artifact }));
  try {
    const runtimes = JSON.parse(
      await run('xcrun', ['simctl', 'list', 'runtimes', '-j'], 'runtimes'),
    );
    for (const os of ['iOS', 'watchOS']) {
      assert(
        runtimes.runtimes.some(
          (r) => r.identifier === `com.apple.CoreSimulator.SimRuntime.${os}-26-2` && r.isAvailable,
        ),
        `Installed ${os}26.2 required; no runtime downloads`,
      );
    }
    for (const role of ['camera', 'scorer', 'watch']) {
      const watch = role === 'watch';
      const name = `Scorebug Manual ${role} ${artifact.split('/').at(-1)}`;
      const id = await run(
        'xcrun',
        [
          'simctl',
          'create',
          name,
          `com.apple.CoreSimulator.SimDeviceType.${watch ? 'Apple-Watch-Series-7-41mm' : 'iPhone-14'}`,
          `com.apple.CoreSimulator.SimRuntime.${watch ? 'watchOS' : 'iOS'}-26-2`,
        ],
        `create-${role}`,
      );
      assert.match(id, /^[a-f0-9-]{36}$/i);
      roles[role] = {
        id,
        name,
        bundleId: watch ? 'live.scorebug.app.watchkitapp' : 'live.scorebug.app',
      };
      await save();
      await run('xcrun', ['simctl', 'boot', id], `boot-${role}`);
      await run('xcrun', ['simctl', 'bootstatus', id, '-b'], `ready-${role}`, 120000);
    }
    roles.watch.pairId = await run(
      'xcrun',
      ['simctl', 'pair', roles.watch.id, roles.scorer.id],
      'pair',
    );
    await save();
    const derived = join(root, 'ios/DerivedData/OrdinaryNativeApp');
    for (const [scheme, role, platform] of [
      ['Scorebug', 'camera', 'iOS'],
      ['ScorebugWatch', 'watch', 'watchOS'],
    ]) {
      console.log(JSON.stringify({ building: scheme }));
      await run(
        'xcodebuild',
        [
          '-project',
          'ios/Scorebug.xcodeproj',
          '-scheme',
          scheme,
          '-configuration',
          'Debug',
          '-destination',
          `platform=${platform} Simulator,id=${roles[role].id}`,
          '-derivedDataPath',
          derived,
          'ARCHS=arm64',
          'ONLY_ACTIVE_ARCH=YES',
          'CODE_SIGNING_ALLOWED=YES',
          'CODE_SIGN_IDENTITY=-',
          'build',
        ],
        `build-${role}`,
        900000,
      );
    }
    for (const [role, device] of Object.entries(roles)) {
      const app =
        role === 'watch'
          ? 'Debug-watchsimulator/ScorebugWatch.app'
          : 'Debug-iphonesimulator/Scorebug.app';
      await run(
        'xcrun',
        ['simctl', 'install', device.id, join(derived, 'Build/Products', app)],
        `install-${role}`,
      );
      device.container = await run(
        'xcrun',
        ['simctl', 'get_app_container', device.id, device.bundleId, 'data'],
        `container-${role}`,
      );
    }
    await save();
    if (options.source)
      await stageNativeFileFixture({
        source: options.source,
        destination: join(
          roles.camera.container,
          'Library/Application Support/Scorebug/QA/input.mov',
        ),
        sha256: sourceHash,
      });
    lab = await startDeviceLab(options, { signal: controller.signal });
    const watchFixture = await issueOrdinaryDirectWatchFixture(lab.setup);
    for (const [role, device] of Object.entries(roles)) {
      const environment =
        role === 'watch'
          ? { SCOREBUG_TEST_WATCH_SETUP: JSON.stringify(watchFixture) }
          : {
              SCOREBUG_TEST_API_URL: lab.setup.endpoint,
              SCOREBUG_TEST_TOKEN: lab.setup.installationToken,
              ...(role === 'camera' && options.source ? { SCOREBUG_TEST_FILE_CAPTURE: '1' } : {}),
            };
      // Credentials travel only in this child's environment, never argv or logs.
      try {
        const result = await execute('xcrun', ['simctl', 'launch', device.id, device.bundleId], {
          cwd: root,
          timeout: 30000,
          signal: controller.signal,
          env: {
            ...ordinaryEnvironment(),
            ...Object.fromEntries(
              Object.entries(environment).map(([k, v]) => [`SIMCTL_CHILD_${k}`, v]),
            ),
          },
        });
        await writeFile(join(artifact, `launch-${role}.log`), result.stdout, { mode: 0o600 });
      } catch {
        throw new Error(`Could not launch ${role}; devices and private setup are preserved`);
      }
      await run(
        'open',
        [
          '-a',
          '/Applications/Xcode-26.2.0.app/Contents/Developer/Applications/Simulator.app',
          '--args',
          '-CurrentDeviceUDID',
          device.id,
        ],
        `show-${role}`,
      );
    }
    await writeFile(
      join(artifact, 'session.json'),
      JSON.stringify(
        {
          lab: lab.artifact,
          setupFile: join(lab.artifact, 'setup.json'),
          source: options.source ?? 'synthetic',
          sourceHash,
          durationSeconds: options.duration,
          ready: true,
          mediaQualified: false,
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );
    console.log(
      JSON.stringify({
        ready: true,
        artifact,
        setupFile: join(lab.artifact, 'setup.json'),
        durationSeconds: options.duration,
        instructions:
          'Connect Score on each phone to HOME/AWAY. Configure Film from setup.json. Start recording, then streaming. Tap Join offered match on Watch first; it uses direct HTTP. Stop streaming and recording before Ctrl-C. Devices and recordings are retained.',
      }),
    );
    await Promise.race([
      new Promise((resolve) => {
        if (controller.signal.aborted) return resolve();
        controller.signal.addEventListener('abort', resolve, { once: true });
        timer = setTimeout(resolve, options.duration * 1000);
      }),
      lab.workerClosed.then(() => {
        throw new Error('Lab worker exited unexpectedly');
      }),
    ]);
  } finally {
    clearTimeout(timer);
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
    await lab?.stop();
    // Keep app containers, recording libraries and pending scoring state intact.
    // The manifest identifies only this session's devices for later user cleanup.
    console.log(JSON.stringify({ stopped: true, artifact, devicesRetained: true }));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
