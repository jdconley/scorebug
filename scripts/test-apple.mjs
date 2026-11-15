import { mkdtemp, rm, mkdir, writeFile, cp } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { takeOverPendingScore } from './scoring-takeover-fault.mjs';
import { startScoringLostReplyProxy } from './scoring-lost-reply-proxy.mjs';
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
const workerStatus = process.argv.includes('--worker-status');
const pendingTakeover = process.argv.includes('--pending-takeover');
const lostReply = process.argv.includes('--lost-reply') || pendingTakeover;
const uiOnly = process.argv.includes('--ui-only');
assert(
  [twoPhones, workerStatus, lostReply].filter(Boolean).length <= 1,
  'Choose one native scenario',
);
let proxy, artifact;
let restored = false;
let scoringDataCollected = false;

if (twoPhones && workerStatus)
  throw new Error('Run worker status separately from the two-phone scenario');
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
      stdio: capture || lostReply ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    });
    activeProcess = child;
    let output = '';
    let timedOut = false;
    let callbackFailure;
    child.stdout?.on('data', (chunk) => {
      output = (output + chunk).slice(-8_000_000);
      if (!capture) process.stdout.write(chunk);
      if (proxy && !restored && output.includes('SCOREBUG_SCORING_RESTORE_CONNECTION')) {
        restored = true;
        try {
          proxy.resume();
        } catch (error) {
          callbackFailure = error;
          stopChild();
        }
      }
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
      if (callbackFailure) reject(callbackFailure);
      else if (code === 0) resolve(output.trim());
      else reject(new Error(`${command} ${timedOut ? 'timed out' : `failed (${code ?? signal})`}`));
    });
  });
}

try {
  if (process.platform !== 'darwin')
    throw new Error('Apple validation requires macOS and full Xcode');
  await run('xcodebuild', ['-version']);
  await run('xcodegen', ['generate', '--spec', 'ios/Scoring.yml']);
  if (!uiOnly) {
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
  }
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
  if (!uiOnly)
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
  if (lostReply) {
    await mkdir(join(root, 'artifacts/qa'), { recursive: true });
    artifact = await mkdtemp(join(root, 'artifacts/qa/native-scoring-recovery-'));
    console.log(JSON.stringify({ artifact }));
  }
  databaseDirectory = artifact ?? (await mkdtemp(join(tmpdir(), 'scorebug-apple-')));
  api = await startScoringTestServer(join(databaseDirectory, 'matches.sqlite'));
  if (lostReply)
    proxy = await startScoringLostReplyProxy(
      api.baseURL,
      pendingTakeover
        ? { afterApplied: (context) => takeOverPendingScore(api.baseURL, context) }
        : {},
    );
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
        artifact
          ? join(artifact, 'workflow.xcresult')
          : `ios/build/scoring-${scenario}-${randomUUID()}.xcresult`,
        'test',
        `SCOREBUG_TEST_API_URL=${proxy?.baseURL ?? api.baseURL}`,
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
    await testSimulator(
      first,
      pendingTakeover
        ? 'pending-takeover'
        : lostReply
          ? 'lost-reply'
          : workerStatus
            ? 'worker-status'
            : 'lifecycle',
    );
  }
  if (lostReply) {
    const audit = proxy.audit();
    assert(restored && audit.phase === 'restored' && audit.lostCommand.score.home === 1);
    assert(
      audit.requests.some(
        (r) =>
          r.method === 'GET' &&
          r.status === 200 &&
          r.path.endsWith('/commands/' + audit.lostCommand.commandId),
      ),
    );
    const db = new DatabaseSync(join(databaseDirectory, 'matches.sqlite'), { readOnly: true });
    try {
      const commands = db
        .prepare('SELECT command_id, request, outcome FROM commands ORDER BY rowid')
        .all();
      const awards = commands.filter(
        (c) =>
          JSON.parse(c.request).operation.type === 'award_point' && JSON.parse(c.outcome).accepted,
      );
      assert.equal(awards.length, 1);
      assert.equal(awards[0].command_id, audit.lostCommand.commandId);
      assert.equal(commands.length, pendingTakeover ? 7 : 3, 'Only the specified scoring commands');
      if (pendingTakeover) {
        assert.deepEqual(
          commands
            .filter((c) => !JSON.parse(c.outcome).accepted)
            .map((c) => JSON.parse(c.outcome).error)
            .sort(),
          ['revision_conflict', 'scorer_changed'],
        );
        assert.equal(
          commands.filter((c) => JSON.parse(c.request).operation.type === 'take_over').length,
          2,
        );
        assert.equal(audit.lostCommand.concurrent.takeover.snapshot.scorer.epoch, 2);
      }
      await writeFile(
        join(artifact, 'recovery-evidence.json'),
        JSON.stringify({ audit, commands }, null, 2),
        { mode: 0o600 },
      );
    } finally {
      db.close();
    }
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
        { capture: true },
      ),
    );
    assert.equal(summary.result, 'Passed');
    assert.equal(summary.passedTests, 1);
    assert.equal(summary.skippedTests, 0);
    const devices = JSON.parse(
      await run('xcrun', ['simctl', 'list', 'devices', '--json'], { capture: true }),
    );
    const state = Object.values(devices.devices)
      .flat()
      .find((device) => device.udid === first)?.state;
    assert(state, 'Owned simulator is missing before data collection');
    if (state === 'Shutdown') await run('xcrun', ['simctl', 'boot', first]);
    await run('xcrun', ['simctl', 'bootstatus', first, '-b']);
    const container = await run(
      'xcrun',
      ['simctl', 'get_app_container', first, 'live.scorebug.scoring', 'data'],
      { capture: true },
    );
    await cp(
      join(container, 'Library/Application Support/Scorebug'),
      join(artifact, 'scoring-data'),
      { recursive: true },
    );
    scoringDataCollected = true;
  }
  console.log(
    `PASS: native scoring ${lostReply ? 'lost-reply restoration' : twoPhones ? 'two-phone' : workerStatus ? 'worker-status' : 'lifecycle'}${uiOnly ? ' (UI-only; unrelated suites/builds skipped)' : ''}.`,
  );
} catch (error) {
  console.error(error.message);
  console.error(
    'For an incomplete default Xcode installation, set DEVELOPER_DIR to a fully installed Xcode.',
  );
  process.exitCode = 1;
} finally {
  if (proxy) {
    await proxy.stop();
    if (artifact)
      await writeFile(join(artifact, 'fault-audit.json'), JSON.stringify(proxy.audit(), null, 2), {
        mode: 0o600,
      });
  }
  if (api) await api.stop();
  if (databaseDirectory && !artifact) await rm(databaseDirectory, { recursive: true, force: true });
  for (const simulator of simulators) {
    if (lostReply && !scoringDataCollected) {
      console.error(
        `Preserving owned simulator ${simulator}: scoring data collection did not complete.`,
      );
      process.exitCode = 1;
      continue;
    }
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
