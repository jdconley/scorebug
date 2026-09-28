import assert from 'node:assert/strict';
import { chmod, cp, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import {
  ordinaryNativeOptions,
  ordinaryTestConfiguration,
  runOrdinaryCommand,
  requireOrdinaryTestResult,
  ordinaryTestEnvironment,
  issueOrdinaryDirectWatchFixture,
} from './test-ordinary-native-app.mjs';
import {
  configurePhysicalTestRunPython,
  verifyPhysicalRecoveryInputs,
} from './test-physical-recovery.mjs';
import {
  separateScorerEnvironment,
  separateScorerTests,
  recordScorerCaptureInventory,
} from './test-separate-native-scorer.mjs';
import { nativeFileFixtureHash, stageNativeFileFixture } from './native-file-fixture.mjs';
import { startDeviceLab } from './device-lab.mjs';
import { readSeparateScorerEvidence } from './separate-scorer-evidence.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
export const nativeCreatedTests = {
  camera:
    'ScorebugAppUITests/PhysicalStreamingTests/testNativeCreatedSimulatorCameraWhileOtherPhoneScores',
  scorer: separateScorerTests.scorer,
  watch: 'ScorebugWatchUITests/CompanionWatchScoringTests/testScoreUsingSimulatorFixtureSetup',
};
export function nativeCreatedOptions(args, interfaces) {
  const filtered = [];
  let separateWatch = false;
  for (let i = 0; i < args.length; i += 2) {
    if (args[i] === '--watch') {
      assert(
        !separateWatch && args[i + 1] === 'separate',
        'Only one separate Watch option is supported',
      );
      separateWatch = true;
    } else {
      assert(
        ['--host', '--source', '--encoder'].includes(args[i]),
        'Unsupported native-created simulator option',
      );
      filtered.push(args[i], args[i + 1]);
    }
  }
  return {
    ...ordinaryNativeOptions(filtered, interfaces),
    ...(separateWatch ? { separateWatch } : {}),
  };
}
export function nativeCreatedEnvironment(lab, role, separateWatch = false) {
  assert(['camera', 'scorer'].includes(role), 'Invalid phone role');
  let environment;
  if (separateWatch) {
    assert.match(lab.setup.endpoint, /^http:\/\/127\.0\.0\.1:[1-9][0-9]*$/);
    assert(lab.setup.installationToken);
    environment = {
      SCOREBUG_DEVICE_API_URL: lab.setup.endpoint,
      SCOREBUG_DEVICE_TOKEN: lab.setup.installationToken,
      ...(role === 'scorer' ? { SCOREBUG_SEPARATE_NATIVE_SCORER: '1' } : {}),
      SCOREBUG_SEPARATE_WATCH_SCORER: '1',
    };
  } else environment = separateScorerEnvironment(lab, role);
  if (role === 'camera') {
    delete environment.SCOREBUG_PHYSICAL_SEPARATE_SCORER;
    environment.SCOREBUG_ORDINARY_SIMULATOR = '1';
  }
  return { ...environment, SCOREBUG_NATIVE_CREATED_SIMULATOR: '1' };
}
export function validateNativeCreation(stored) {
  assert.equal(stored.length, 1, 'Exactly one native-created match required');
  const match = stored[0];
  const creation = JSON.parse(match.creationRequest);
  assert.match(match.id, /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i);
  assert.equal(creation.id, match.id);
  assert.match(creation.deviceId, /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i);
  assert.equal(match.revision, 0, 'No score/media mutation may precede camera startup');
  assert.equal(match.scoring.status, 'active');
  assert.deepEqual(match.scoring.score, { home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0 });
  assert.deepEqual(match.scorer, { deviceId: creation.deviceId, epoch: 1 });
  assert.equal(creation.teams.home.name, 'HOME');
  assert.equal(creation.teams.away.name, 'AWAY');
  assert.deepEqual(match.broadcast, { desired: 'stopped', generation: 0 });
  return { matchId: match.id, creatorDeviceId: creation.deviceId, creationRequest: creation };
}
async function readMatches(path) {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    return db
      .prepare('SELECT data FROM matches')
      .all()
      .map((row) => JSON.parse(row.data));
  } finally {
    db.close();
  }
}
async function hash(path) {
  const bytes = await readFile(path);
  return {
    path: resolve(path),
    bytes: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
}
async function main() {
  assert.equal(process.platform, 'darwin');
  const options = nativeCreatedOptions(process.argv.slice(2));
  const sourceSHA256 = await nativeFileFixtureHash(options.source);
  const artifact = await mkdtemp(join(root, 'artifacts/qa/native-created-simulators-'));
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
  const roles = Object.fromEntries(
    ['camera', 'scorer', ...(options.separateWatch ? ['watch'] : [])].map((name) => [
      name,
      {
        name: `Scorebug Native Created ${name} ${randomUUID()}`,
        device: undefined,
        container: undefined,
        bundleId: name === 'watch' ? 'live.scorebug.app.watchkitapp' : 'live.scorebug.app',
      },
    ]),
  );
  let lab,
    cameraJob,
    scorerJob,
    watchJob,
    watchPairId,
    watchFixture,
    failure,
    sourceHead,
    creation,
    workflowPassed = false;
  let inputs = [];
  console.log(
    JSON.stringify({
      artifact,
      scope: options.separateWatch
        ? 'Two phones and separate scorer Watch; fixture setup, direct scoring'
        : 'Two native simulator phones; native creation, separate scoring and file capture',
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
      'Commit reviewed source before this native run',
    );
    const runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-2';
    const runtimes = JSON.parse(
      await run('xcrun', ['simctl', 'list', 'runtimes', '-j'], 'runtimes'),
    );
    assert(
      runtimes.runtimes.some((r) => r.identifier === runtime && r.isAvailable),
      'Installed iOS26.2 required; no downloads',
    );
    for (const [name, role] of Object.entries(roles)) {
      role.device = await run(
        'xcrun',
        [
          'simctl',
          'create',
          role.name,
          name === 'watch'
            ? 'com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-7-41mm'
            : 'com.apple.CoreSimulator.SimDeviceType.iPhone-14',
          name === 'watch' ? 'com.apple.CoreSimulator.SimRuntime.watchOS-26-2' : runtime,
        ],
        `create-${name}`,
      );
      assert.match(role.device, /^[0-9a-f-]{36}$/i);
      await run('xcrun', ['simctl', 'boot', role.device], `boot-${name}`);
      await run('xcrun', ['simctl', 'bootstatus', role.device, '-b'], `ready-${name}`, 120000);
    }
    if (roles.watch)
      watchPairId = await run(
        'xcrun',
        ['simctl', 'pair', roles.watch.device, roles.scorer.device],
        'pair-watch-to-scorer',
      );
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
        '-destination',
        `platform=iOS Simulator,id=${roles.camera.device}`,
        '-derivedDataPath',
        derived,
        'ARCHS=arm64',
        'ONLY_ACTIVE_ARCH=YES',
        'CODE_SIGNING_ALLOWED=YES',
        'CODE_SIGN_IDENTITY=-',
        'build-for-testing',
        ...[nativeCreatedTests.camera, nativeCreatedTests.scorer].map(
          (test) => `-only-testing:${test}`,
        ),
      ],
      'build',
      900000,
    );
    if (roles.watch)
      await run(
        'xcodebuild',
        [
          '-project',
          'ios/Scorebug.xcodeproj',
          '-scheme',
          'ScorebugWatch',
          '-configuration',
          'Debug',
          '-destination',
          `platform=watchOS Simulator,id=${roles.watch.device}`,
          '-derivedDataPath',
          derived,
          'ARCHS=arm64',
          'ONLY_ACTIVE_ARCH=YES',
          'CODE_SIGNING_ALLOWED=YES',
          'CODE_SIGN_IDENTITY=-',
          'build-for-testing',
          `-only-testing:${nativeCreatedTests.watch}`,
        ],
        'build-watch',
        900000,
      );
    const products = join(derived, 'Build/Products');
    const sourceRun = join(
      products,
      ordinaryTestConfiguration(await readdir(products), 'Scorebug', false),
    );
    for (const [name, role] of Object.entries(roles)) {
      await run(
        'xcrun',
        [
          'simctl',
          'install',
          role.device,
          join(
            products,
            name === 'watch'
              ? 'Debug-watchsimulator/ScorebugWatch.app'
              : 'Debug-iphonesimulator/Scorebug.app',
          ),
        ],
        `install-${name}`,
      );
      role.container = await run(
        'xcrun',
        ['simctl', 'get_app_container', role.device, role.bundleId, 'data'],
        `container-${name}`,
      );
    }
    await stageNativeFileFixture({
      source: options.source,
      destination: join(
        roles.camera.container,
        'Library/Application Support/Scorebug/QA/input.mov',
      ),
      sha256: sourceSHA256,
    });
    inputs = await Promise.all(
      [
        options.source,
        fileURLToPath(import.meta.url),
        sourceRun,
        'ios/AppUITests/PhysicalStreamingTests.swift',
        'ios/Project.yml',
        'scripts/device-lab.mjs',
        'scripts/test-ordinary-native-app.mjs',
        'scripts/test-separate-native-scorer.mjs',
        'scripts/test-physical-recovery.mjs',
        'scripts/native-file-fixture.mjs',
        'scripts/separate-scorer-evidence.mjs',
        ...[
          'Scorebug.app/Scorebug',
          'Scorebug.app/Scorebug.debug.dylib',
          'ScorebugAppUITests-Runner.app/ScorebugAppUITests-Runner',
          'ScorebugAppUITests-Runner.app/PlugIns/ScorebugAppUITests.xctest/ScorebugAppUITests',
        ].map((p) => join(products, 'Debug-iphonesimulator', p)),
      ].map(hash),
    );
    lab = await startDeviceLab(
      {
        host: options.host,
        encoder: options.encoder,
        duration: 600,
        seedMatch: false,
        ...(options.separateWatch ? { apiLoopback: true } : {}),
      },
      { signal: controller.signal },
    );
    assert.equal(lab.setup.matchId, undefined);
    const database = join(lab.artifact, 'scorebug.sqlite');
    assert.deepEqual(await readMatches(database), [], 'Lab must be empty before native creation');
    const configure = join(artifact, 'configure.py');
    await writeFile(configure, configurePhysicalTestRunPython, { flag: 'wx', mode: 0o600 });
    for (const [name, role] of Object.entries(roles)) {
      if (name === 'watch') continue;
      const envPath = join(artifact, `${name}-environment.json`);
      role.privateRun = join(artifact, `${name}.xctestrun`);
      await writeFile(
        envPath,
        JSON.stringify(nativeCreatedEnvironment(lab, name, options.separateWatch)),
        {
          flag: 'wx',
          mode: 0o600,
        },
      );
      await run(
        'python3',
        [configure, sourceRun, role.privateRun, 'ScorebugAppUITests', envPath, products],
        `configure-${name}`,
      );
      inputs.push(await hash(role.privateRun));
    }
    await writeFile(
      join(artifact, 'inputs.json'),
      JSON.stringify({ sourceHead, sourceSHA256, inputs }, null, 2),
      { flag: 'wx', mode: 0o600 },
    );
    async function workflow(name) {
      const role = roles[name],
        result = join(artifact, `${name}.xcresult`);
      try {
        await run(
          'xcodebuild',
          [
            'test-without-building',
            '-xctestrun',
            role.privateRun,
            '-destination',
            `platform=${name === 'watch' ? 'watchOS' : 'iOS'} Simulator,id=${role.device}`,
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
            '-maximum-test-execution-time-allowance',
            '480',
            '-resultBundlePath',
            result,
            `-only-testing:${nativeCreatedTests[name]}`,
          ],
          `${name}-workflow`,
          600000,
        );
        const results = [];
        for (const kind of ['summary', 'tests'])
          results.push(
            JSON.parse(
              await run(
                'xcrun',
                ['xcresulttool', 'get', 'test-results', kind, '--path', result],
                `${name}-${kind}`,
              ),
            ),
          );
        requireOrdinaryTestResult(results[0], results[1], nativeCreatedTests[name]);
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
    const until = performance.now() + 120000;
    while (!scorerDone && performance.now() < until && !controller.signal.aborted) {
      const log = await readFile(join(artifact, 'scorer-workflow.log'), 'utf8').catch(() => '');
      if (log.includes("Added attachment named 'SeparateNativeScorer-ready'")) {
        ready = true;
        break;
      }
      await delay(250);
    }
    assert(ready, 'Native creator did not reach readiness; camera was not started');
    creation = validateNativeCreation(await readMatches(database));
    await writeFile(join(artifact, 'native-creation.json'), JSON.stringify(creation, null, 2), {
      flag: 'wx',
      mode: 0o600,
    });
    cameraJob = workflow('camera');
    if (roles.watch) {
      const end = performance.now() + 360000;
      let ready = false;
      while (performance.now() < end && !controller.signal.aborted) {
        const logs = await Promise.all(
          ['camera', 'scorer'].map((name) =>
            readFile(join(artifact, `${name}-workflow.log`), 'utf8').catch(() => ''),
          ),
        );
        if (logs.every((log) => log.includes("-watch-ready'"))) {
          ready = true;
          break;
        }
        if (outcomes.camera || outcomes.scorer) break;
        await delay(250);
      }
      assert(ready, 'Both native phones must reach Watch readiness before issuing setup');
      watchFixture = await issueOrdinaryDirectWatchFixture({
        ...lab.setup,
        matchId: creation.matchId,
      });
      const envPath = join(artifact, 'watch-environment.json');
      roles.watch.privateRun = join(artifact, 'watch.xctestrun');
      await writeFile(
        envPath,
        JSON.stringify({
          ...ordinaryTestEnvironment({
            paired: false,
            directWatch: true,
            watch: true,
            setup: { ...lab.setup, matchId: creation.matchId },
            watchFixture,
          }),
          SCOREBUG_SEPARATE_WATCH_SCORER: '1',
        }),
        { flag: 'wx', mode: 0o600 },
      );
      const watchRun = join(
        products,
        ordinaryTestConfiguration(await readdir(products), 'ScorebugWatch', true),
      );
      await run(
        'python3',
        [configure, watchRun, roles.watch.privateRun, 'ScorebugWatchUITests', envPath, products],
        'configure-watch',
      );
      watchJob = workflow('watch');
    }
    await Promise.all([cameraJob, scorerJob, watchJob].filter(Boolean));
    await verifyPhysicalRecoveryInputs(inputs);
    assert(
      outcomes.camera?.passed &&
        outcomes.scorer?.passed &&
        (!roles.watch || outcomes.watch?.passed),
      'Native role failure; both terminal outcomes retained',
    );
    const { DatabaseSync } = await import('node:sqlite');
    const db = new DatabaseSync(database, { readOnly: true });
    let recordingId;
    try {
      const recordings = db
        .prepare('SELECT data FROM recordings WHERE game_id=?')
        .all(creation.matchId);
      assert.equal(recordings.length, 1);
      recordingId = JSON.parse(recordings[0].data).recordingId;
    } finally {
      db.close();
    }
    const evidence = await readSeparateScorerEvidence(
      database,
      creation.matchId,
      recordingId,
      watchFixture?.offer.watchDeviceId,
    );
    assert.equal(
      evidence.otherScorerDeviceId,
      creation.creatorDeviceId,
      'Creator must be the later native scorer',
    );
    await writeFile(join(artifact, 'native-evidence.json'), JSON.stringify(evidence, null, 2), {
      flag: 'wx',
      mode: 0o600,
    });
    workflowPassed = true;
  } catch (error) {
    failure = String(error.message);
  } finally {
    await Promise.allSettled([cameraJob, scorerJob, watchJob].filter(Boolean));
    try {
      await lab?.stop();
    } catch (error) {
      cleanupFailures.push(`lab: ${error.message}`);
    }
    // Recover exact per-run names if create succeeded just as cancellation arrived.
    try {
      const devices = JSON.parse(
        await run(
          'xcrun',
          ['simctl', 'list', 'devices', '-j'],
          'recover-owned-devices',
          60000,
          true,
        ),
      );
      for (const role of Object.values(roles))
        role.device ??= Object.values(devices.devices)
          .flat()
          .find((d) => d.name === role.name)?.udid;
    } catch {
      cleanupFailures.push('owned simulator discovery');
    }
    if (watchPairId) {
      try {
        await run('xcrun', ['simctl', 'unpair', watchPairId], 'unpair-watch', 60000, true);
      } catch {
        cleanupFailures.push('Watch unpair');
      }
    }
    for (const [name, role] of Object.entries(roles)) {
      if (!role.device) continue;
      let preserved = !role.container;
      if (role.container) {
        try {
          const container = await run(
            'xcrun',
            ['simctl', 'get_app_container', role.device, role.bundleId, 'data'],
            `final-${name}-container`,
            60000,
            true,
          );
          await run(
            'xcrun',
            ['simctl', 'terminate', role.device, role.bundleId],
            `terminate-${name}`,
            60000,
            true,
          ).catch(() => {});
          if (name === 'scorer' && scorerJob) {
            const inventory = await recordScorerCaptureInventory(
              container,
              join(artifact, 'scorer-camera-free.json'),
            );
            if (!inventory.noLocalRecordings)
              failure ??= 'Scorer unexpectedly created capture data';
          }
          await cp(container, join(artifact, `${name}-app-data`), {
            recursive: true,
            errorOnExist: true,
            force: false,
          });
          preserved = true;
        } catch (error) {
          cleanupFailures.push(`${name} app-data preservation: ${error.message}`);
        }
      }
      if (!preserved) continue; // Never delete an unpreserved recording/container.
      try {
        await run('xcrun', ['simctl', 'shutdown', role.device], `shutdown-${name}`, 60000, true);
      } catch (error) {
        cleanupFailures.push(`${name} shutdown: ${error.message}`);
      }
      try {
        await run('xcrun', ['simctl', 'delete', role.device], `delete-${name}`, 60000, true);
      } catch (error) {
        cleanupFailures.push(`${name} delete: ${error.message}`);
      }
    }
    workflowPassed = workflowPassed && !failure && !cleanupFailures.length;
    await writeFile(
      join(artifact, 'result.json'),
      JSON.stringify(
        {
          formatVersion: 1,
          lane: options.separateWatch
            ? 'native-created-separate-watch'
            : 'native-created-two-phone',
          ...(options.separateWatch
            ? {
                watchPairId,
                setupTransport: 'simulator-fixture',
                scoringTransport: 'direct-http',
                watchConnectivityQualified: false,
              }
            : {}),
          sourceHead,
          sourceSHA256,
          roles,
          labArtifact: lab?.artifact,
          matchId: creation?.matchId,
          outcomes,
          workflowPassed,
          mediaQualified: false,
          failure,
          cleanupFailures,
          commands,
          joined: true,
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
