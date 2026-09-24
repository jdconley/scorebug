import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { cp, mkdir, mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { mediaTools } from './media-tools.mjs';
import { assertMediaCoverage } from './media-sync.mjs';
import { startScoringTestServer, scoringTestToken } from './scoring-test-server.mjs';

// Explicit qualification only: creates its own paired simulators and loopback API.
// Both builds finish before either app starts recording. No setup-injection fallback.
const root = fileURLToPath(new URL('..', import.meta.url));
const developer = process.env.DEVELOPER_DIR ?? '/Applications/Xcode-26.2.0.app/Contents/Developer';
const owner = randomUUID();
const phoneName = `Scorebug Paired Phone ${owner}`;
const watchName = `Scorebug Paired Watch ${owner}`;
const phoneVersion = process.env.SCOREBUG_IOS_RUNTIME ?? '17.5';
const watchVersion = process.env.SCOREBUG_WATCH_RUNTIME ?? '10.5';
const phoneDeviceType = process.env.SCOREBUG_IOS_DEVICE_TYPE ?? 'iPhone-14';
const watchDeviceType = process.env.SCOREBUG_WATCH_DEVICE_TYPE ?? 'Apple-Watch-Series-7-41mm';
for (const version of [phoneVersion, watchVersion])
  assert.match(
    version,
    /^\d{1,3}\.\d{1,3}(?:\.\d{1,3})?$/,
    'Expected a numeric simulator runtime version',
  );
for (const deviceType of [phoneDeviceType, watchDeviceType])
  assert.match(
    deviceType,
    /^[A-Za-z0-9][A-Za-z0-9-]{0,127}$/,
    'Expected a simulator device type identifier suffix',
  );
const phoneRuntime = `com.apple.CoreSimulator.SimRuntime.iOS-${phoneVersion.replaceAll('.', '-')}`;
const watchRuntime = `com.apple.CoreSimulator.SimRuntime.watchOS-${watchVersion.replaceAll('.', '-')}`;
const configuration = {
  developerDir: developer,
  phone: { runtime: phoneVersion, deviceType: phoneDeviceType },
  watch: { runtime: watchVersion, deviceType: watchDeviceType },
};
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/paired-watch-'));
const derived = join(artifact, 'DerivedData');
const databasePath = join(artifact, 'matches.sqlite');
const { ffmpeg, ffprobe } = mediaTools();
const active = new Set();
const secrets = new Set([scoringTestToken]);
const environment = { ...process.env, DEVELOPER_DIR: developer };
for (const key of [
  'SCOREBUG_TEST_WATCH_SETUP',
  'SIMCTL_CHILD_SCOREBUG_TEST_WATCH_SETUP',
  'SCOREBUG_FIXTURE_FAIL_AFTER',
])
  delete environment[key];
let phone,
  watch,
  pairId,
  api,
  interrupted = false;
let successMessage;
const resultPaths = {
  phone: join(artifact, 'Phone.xcresult'),
  watch: join(artifact, 'Watch.xcresult'),
};
function killOwnedChildren() {
  for (const child of active) {
    try {
      process.kill(-child.pid, 'SIGKILL');
    } catch {}
  }
}
const interrupt = () => {
  interrupted = true;
  killOwnedChildren();
};
process.on('SIGINT', interrupt);
process.on('SIGTERM', interrupt);
function redact(text) {
  for (const secret of secrets) text = text.replaceAll(secret, '[redacted]');
  return text;
}
async function run(
  binary,
  args,
  name,
  {
    timeout = 120_000,
    cleanup = false,
    maximumBytes = 32 * 1024 * 1024,
    redactOutput = redact,
  } = {},
) {
  if (interrupted && !cleanup) throw new Error('Paired Watch qualification interrupted');
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      cwd: root,
      env: environment,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    active.add(child);
    let output = '',
      errors = '',
      size = 0,
      failure;
    const kill = () => {
      try {
        process.kill(-child.pid, 'SIGKILL');
      } catch {}
    };
    const append = (chunk, stderr) => {
      size += chunk.length;
      if (size > maximumBytes) {
        failure = 'output limit exceeded';
        kill();
        return;
      }
      if (stderr) errors += chunk;
      else output += chunk;
    };
    child.stdout.on('data', (chunk) => append(chunk, false));
    child.stderr.on('data', (chunk) => append(chunk, true));
    const timer = setTimeout(() => {
      failure = 'timed out';
      kill();
    }, timeout);
    child.once('error', () => {
      failure = 'could not launch';
    });
    child.once('close', async (code) => {
      clearTimeout(timer);
      active.delete(child);
      try {
        await writeFile(join(artifact, `${name}.log`), redactOutput(output + errors));
        if (failure || code !== 0)
          throw new Error(`${name} ${failure ?? `failed (${code})`}; see ${artifact}/${name}.log`);
        resolve(output.trim());
      } catch (error) {
        reject(error);
      }
    });
  });
}
function redactConnectivity(text) {
  return redact(text)
    .replace(/\b(Bearer|Basic)\s+[^\s,;]+/gi, '$1 [redacted]')
    .replace(
      /((?:pairingToken|recoveryKey|installationToken|applicationContext|messageData)\s*[:=]\s*)[^\n]*/gi,
      '$1[redacted]',
    )
    .replace(/(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43,}(?![A-Za-z0-9_-])/g, '[redacted-data]')
    .replace(/<(?:[0-9a-f]{2}\s*){16,}>/gi, '[redacted-data]');
}
async function collectConnectivityFailure() {
  // Registration/activation state only: exclude general application-context
  // payload logging, and additionally strip bearer/high-entropy data before disk.
  const predicate =
    'subsystem == "live.scorebug.connectivity" OR (subsystem == "com.apple.wcd" AND (eventMessage CONTAINS[c] "SessionState" OR eventMessage CONTAINS[c] "activation" OR eventMessage CONTAINS[c] "install" OR eventMessage CONTAINS "7018"))';
  let devices = [];
  try {
    const listed = JSON.parse(
      await run('xcrun', ['simctl', 'list', 'devices', '--json'], 'failure-device-state', {
        cleanup: true,
        timeout: 15_000,
        maximumBytes: 1024 * 1024,
      }),
    );
    devices = Object.values(listed.devices).flat();
  } catch {
    /* Each device log attempt still records its own failure. */
  }
  await Promise.allSettled(
    [
      ['phone', phone],
      ['watch', watch],
    ]
      .filter(([, id]) => id)
      .map(async ([name, id]) => {
        // XCTest can shut down its destination before reporting failure. Boot only
        // the same owned device to read its retained unified log, never a replacement.
        if (devices.find((device) => device.udid === id)?.state === 'Shutdown') {
          await run('xcrun', ['simctl', 'boot', id], `failure-boot-${name}`, {
            cleanup: true,
            timeout: 30_000,
          });
          await run('xcrun', ['simctl', 'bootstatus', id, '-b'], `failure-ready-${name}`, {
            cleanup: true,
            timeout: 45_000,
          });
        }
        await run(
          'xcrun',
          [
            'simctl',
            'spawn',
            id,
            'log',
            'show',
            '--style',
            'compact',
            '--last',
            '15m',
            '--info',
            '--debug',
            '--predicate',
            predicate,
          ],
          `${name}-wcd-failure`,
          {
            cleanup: true,
            timeout: 45_000,
            maximumBytes: 4 * 1024 * 1024,
            redactOutput: redactConnectivity,
          },
        );
      }),
  );
}

async function request(path, { body, token = scoringTestToken } = {}) {
  const response = await fetch(`${api.baseURL}${path}`, {
    method: body ? 'POST' : 'GET',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(10_000),
  });
  assert.ok(response.ok, `Isolated API ${path}: HTTP ${response.status}`);
  return response.json();
}
function uuid(value) {
  assert.match(value, /^[0-9a-f-]{36}$/i, 'Simulator command did not return one UUID');
  return value;
}
async function testRunPath(scheme) {
  const products = join(derived, 'Build/Products');
  const matches = (await readdir(products)).filter(
    (name) => name.startsWith(`${scheme}_`) && name.endsWith('.xctestrun'),
  );
  assert.equal(matches.length, 1, `Expected one built ${scheme} test configuration`);
  return join(products, matches[0]);
}
async function inspectArchive(path, outcomes, status) {
  await run(
    ffmpeg,
    ['-v', 'error', '-xerror', '-i', path, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'],
    'archive-decode',
    { timeout: 240_000 },
  );
  const probe = JSON.parse(
    await run(
      ffprobe,
      [
        '-v',
        'error',
        '-show_streams',
        '-show_frames',
        '-show_entries',
        'stream=codec_type,width,height,sample_rate,channels:frame=media_type,best_effort_timestamp_time,nb_samples',
        '-of',
        'json',
        path,
      ],
      'archive-probe',
    ),
  );
  const video = probe.streams.find((stream) => stream.codec_type === 'video');
  const audio = probe.streams.find((stream) => stream.codec_type === 'audio');
  assert.equal(video?.width, 1920);
  assert.equal(video?.height, 1080);
  assert.equal(Number(audio?.sample_rate), 48_000);
  assert.equal(audio?.channels, 1);
  const frames = probe.frames.filter((frame) => frame.media_type === 'video');
  const pcm = probe.frames.filter((frame) => frame.media_type === 'audio');
  assert.ok(frames.length >= 150, 'Archive must contain at least five seconds of video');
  const times = frames.map((frame) => Number(frame.best_effort_timestamp_time));
  const coverage = assertMediaCoverage({
    videoTimes: times,
    audioStartTime: Number(pcm[0]?.best_effort_timestamp_time),
    audioSampleCount: pcm.reduce((sum, frame) => sum + Number(frame.nb_samples), 0),
    sampleRate: Number(audio.sample_rate),
  });
  assert.ok(times[0] >= 0 && times[0] <= 0.1, 'Archive must begin at its source origin');
  const fps = (frames.length - 1) / (times.at(-1) - times[0]);
  assert.ok(fps >= 24, `Fresh archive cadence ${fps} fell below 24 fps`);
  const barcodePath = join(artifact, 'archive-frames.gray');
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-xerror',
      '-i',
      path,
      '-map',
      '0:v:0',
      '-vf',
      'crop=iw:2:0:20,scale=16:1:flags=neighbor,format=gray',
      '-fps_mode',
      'passthrough',
      '-f',
      'rawvideo',
      barcodePath,
    ],
    'archive-barcodes',
    { timeout: 240_000 },
  );
  const bytes = await readFile(barcodePath);
  assert.equal(bytes.length, frames.length * 16);
  assert.ok(frames.length < 65_536, 'Fixture exceeds unambiguous 16-bit source identity window');
  for (let frame = 0; frame < frames.length; frame++) {
    let code = 0;
    for (let bit = 0; bit < 16; bit++) if (bytes[frame * 16 + bit] > 145) code |= 1 << bit;
    assert.equal(code, frame, `Missing, duplicated or reordered archive source frame ${frame}`);
  }
  // RecordingLibrary uses Foundation Date's default seconds-since-2001 encoding.
  const reference = Date.parse('2001-01-01T00:00:00Z');
  assert.ok(Number.isFinite(status.createdAt) && Number.isFinite(status.completedAt));
  const started = reference + status.createdAt * 1000,
    stopped = reference + status.completedAt * 1000;
  const commandTimes = outcomes.map((row) => Date.parse(row.request.issuedAt));
  assert.ok(commandTimes.every(Number.isFinite));
  const first = Math.min(...commandTimes),
    last = Math.max(...commandTimes);
  assert.ok(
    started < first && stopped > last,
    'Recording metadata must enclose every Watch command',
  );
  const duration = coverage.videoEndTime - coverage.videoStartTime;
  // Phone waits two recorded seconds before sending the first offer, then at
  // least three more recorded seconds after observing the final Watch command.
  assert.ok(
    duration >= (last - first) / 1000 + 5,
    'Decoded archive must cover the complete Watch command interval plus recording margins',
  );
  return {
    frames: frames.length,
    firstSourceFrame: 0,
    lastSourceFrame: frames.length - 1,
    fps,
    duration,
    coverage,
    recordingStartedAt: new Date(started).toISOString(),
    recordingStoppedAt: new Date(stopped).toISOString(),
    firstCommandAt: new Date(first).toISOString(),
    lastCommandAt: new Date(last).toISOString(),
  };
}

try {
  assert.equal(process.platform, 'darwin');
  console.log(
    `Paired ${phoneDeviceType} iOS ${phoneVersion} + ${watchDeviceType} watchOS ${watchVersion}; evidence: ${artifact}`,
  );
  await writeFile(join(artifact, 'configuration.json'), JSON.stringify(configuration, null, 2));
  await run('xcodebuild', ['-version'], 'toolchain-version');
  const runtimes = JSON.parse(
    await run('xcrun', ['simctl', 'list', 'runtimes', '--json'], 'runtimes'),
  );
  for (const id of [phoneRuntime, watchRuntime])
    assert.ok(
      runtimes.runtimes.some((item) => item.identifier === id && item.isAvailable),
      `${id} unavailable`,
    );
  phone = uuid(
    await run(
      'xcrun',
      [
        'simctl',
        'create',
        phoneName,
        `com.apple.CoreSimulator.SimDeviceType.${phoneDeviceType}`,
        phoneRuntime,
      ],
      'create-phone',
    ),
  );
  watch = uuid(
    await run(
      'xcrun',
      [
        'simctl',
        'create',
        watchName,
        `com.apple.CoreSimulator.SimDeviceType.${watchDeviceType}`,
        watchRuntime,
      ],
      'create-watch',
    ),
  );
  pairId = uuid(await run('xcrun', ['simctl', 'pair', watch, phone], 'pair'));
  await run('xcrun', ['simctl', 'boot', phone], 'boot-phone');
  await run('xcrun', ['simctl', 'boot', watch], 'boot-watch');
  await run('xcrun', ['simctl', 'bootstatus', phone, '-b'], 'ready-phone');
  await run('xcrun', ['simctl', 'bootstatus', watch, '-b'], 'ready-watch');
  await run('pnpm', ['--filter', '@scorebug/protocol', 'build'], 'protocol');
  api = await startScoringTestServer(databasePath);
  const gameId = randomUUID(),
    fixturePhoneId = randomUUID();
  const team = (name) => ({ name, shortName: name.toUpperCase(), color: '#123456' });
  const created = await request('/v1/matches', {
    body: {
      id: gameId,
      deviceId: fixturePhoneId,
      teams: { home: team('Home'), away: team('Away') },
      rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
    },
  });
  secrets.add(created.credential.token);
  await run('xcodegen', ['generate', '--spec', 'ios/Project.yml'], 'generate');
  const phoneCase =
    'ScorebugAppUITests/PhoneWatchIntegrationTests/testLocalRecordingWhilePairedWatchScores';
  const watchCase =
    'ScorebugWatchUITests/CompanionWatchScoringTests/testScoreUsingRealCompanionSetup';
  for (const [scheme, destination, testCase, name] of [
    ['Scorebug', `platform=iOS Simulator,id=${phone}`, phoneCase, 'phone'],
    ['ScorebugWatch', `platform=watchOS Simulator,id=${watch}`, watchCase, 'watch'],
  ]) {
    await run(
      'xcodebuild',
      [
        '-project',
        'ios/Scorebug.xcodeproj',
        '-scheme',
        scheme,
        '-configuration',
        'Debug',
        '-derivedDataPath',
        derived,
        '-destination',
        destination,
        '-parallel-testing-enabled',
        'NO',
        `-only-testing:${testCase}`,
        'build-for-testing',
        'CODE_SIGNING_ALLOWED=YES',
        'CODE_SIGN_IDENTITY=-',
        `SCOREBUG_TEST_API_URL=${api.baseURL}`,
        'SCOREBUG_TEST_WATCH_SETUP=',
      ],
      `build-${name}`,
      { timeout: 600_000 },
    );
  }
  const phoneRun = await testRunPath('Scorebug'),
    watchRun = await testRunPath('ScorebugWatch');
  // Install in a known order before either XCTest runner can activate WCSession.
  // Container lookup confirms local installation, not companion registration or
  // WatchConnectivity delivery; those still require the actual UI handshake.
  const installations = [
    [
      'phone',
      phone,
      join(derived, 'Build/Products/Debug-iphonesimulator/Scorebug.app'),
      'live.scorebug.app',
    ],
    [
      'watch',
      watch,
      join(derived, 'Build/Products/Debug-watchsimulator/ScorebugWatch.app'),
      'live.scorebug.app.watchkitapp',
    ],
  ];
  for (const [name, device, app, bundle] of installations) {
    await run('xcrun', ['simctl', 'install', device, app], `preinstall-${name}`, {
      timeout: 120_000,
    });
    const installed = await run(
      'xcrun',
      ['simctl', 'get_app_container', device, bundle, 'app'],
      `preinstalled-container-${name}`,
      { timeout: 30_000 },
    );
    assert.ok(
      installed.startsWith('/') && basename(installed) === basename(app),
      'Unexpected installed app container',
    );
  }
  // Everything above is setup/build work. No build or analysis runs while filming.
  const tests = [
    run(
      'xcodebuild',
      [
        '-xctestrun',
        phoneRun,
        '-destination',
        `platform=iOS Simulator,id=${phone}`,
        '-parallel-testing-enabled',
        'NO',
        '-resultBundlePath',
        resultPaths.phone,
        `-only-testing:${phoneCase}`,
        'test-without-building',
      ],
      'test-phone',
      { timeout: 600_000 },
    ),
    run(
      'xcodebuild',
      [
        '-xctestrun',
        watchRun,
        '-destination',
        `platform=watchOS Simulator,id=${watch}`,
        '-parallel-testing-enabled',
        'NO',
        '-resultBundlePath',
        resultPaths.watch,
        `-only-testing:${watchCase}`,
        'test-without-building',
      ],
      'test-watch',
      { timeout: 600_000 },
    ),
  ];
  try {
    await Promise.all(tests);
  } catch (error) {
    killOwnedChildren();
    await Promise.allSettled(tests);
    throw error;
  }
  const final = await request(`/v1/matches/${gameId}`, { token: created.credential.token });
  assert.equal(final.snapshot.status, 'ended');
  assert.equal(final.snapshot.score.home, 0);
  assert.equal(final.snapshot.score.away, 1);
  assert.equal(final.snapshot.broadcast.desired, 'stopped');
  // Ending a match invalidates stale broadcast controls even without a start.
  assert.equal(final.snapshot.broadcast.generation, 1);
  const database = new DatabaseSync(databasePath, { readOnly: true });
  let outcomes, pairing;
  try {
    const pairings = database
      .prepare(
        'SELECT pairing_id,watch_device_id,redemption_request FROM watch_pairings WHERE game_id=?',
      )
      .all(gameId);
    assert.equal(pairings.length, 1, 'Exactly one real companion pairing should be issued');
    pairing = pairings[0];
    assert.ok(pairing.redemption_request, 'Companion pairing was not redeemed');
    outcomes = database
      .prepare('SELECT request,outcome FROM commands WHERE game_id=? ORDER BY rowid')
      .all(gameId)
      .map((row) => ({ request: JSON.parse(row.request), outcome: JSON.parse(row.outcome) }));
    assert.equal(
      database.prepare('SELECT COUNT(*) AS count FROM media_commands WHERE game_id=?').get(gameId)
        .count,
      0,
      'Paired recording test must never start a broadcast',
    );
  } finally {
    database.close();
  }
  assert.notEqual(pairing.watch_device_id, fixturePhoneId);
  assert.equal(final.snapshot.scorer.deviceId, pairing.watch_device_id);
  assert.deepEqual(
    outcomes.map((row) => row.request.operation.type),
    ['take_over', 'award_point', 'undo', 'award_point', 'end_match'],
  );
  assert.ok(
    outcomes.every(
      (row) => row.outcome.accepted && row.request.deviceId === pairing.watch_device_id,
    ),
  );
  assert.equal(outcomes[1].request.operation.side, 'home');
  assert.equal(outcomes[3].request.operation.side, 'away');
  const devices = JSON.parse(
    await run('xcrun', ['simctl', 'list', 'devices', '--json'], 'devices-after-tests'),
  );
  const ownedPhone = Object.values(devices.devices)
    .flat()
    .find((device) => device.udid === phone);
  assert.ok(ownedPhone, 'Owned recording phone disappeared');
  if (ownedPhone.state === 'Shutdown')
    await run('xcrun', ['simctl', 'boot', phone], 'boot-for-export');
  await run('xcrun', ['simctl', 'bootstatus', phone, '-b'], 'ready-for-export');
  const container = await run(
    'xcrun',
    ['simctl', 'get_app_container', phone, 'live.scorebug.app', 'data'],
    'container',
  );
  const saved = join(artifact, 'recordings');
  await cp(join(container, 'Library/Application Support/Scorebug/Recordings'), saved, {
    recursive: true,
    force: false,
    errorOnExist: true,
  });
  const exports = (await readdir(join(saved, 'Exports'))).filter((name) => name.endsWith('.mp4'));
  assert.equal(exports.length, 1, 'Expected exactly one completed recording export');
  const entries = (await readdir(saved, { withFileTypes: true })).filter(
    (entry) => entry.isDirectory() && entry.name !== 'Exports',
  );
  assert.equal(entries.length, 1, 'Expected exactly one local archive');
  const status = JSON.parse(
    await readFile(join(saved, entries[0].name, 'recording-status.json'), 'utf8'),
  );
  assert.ok(
    status.completedAt != null && status.failure == null,
    'Local recording did not finish cleanly',
  );
  const media = await inspectArchive(join(saved, 'Exports', exports[0]), outcomes, status);
  await writeFile(
    join(artifact, 'result.json'),
    JSON.stringify(
      {
        qualification:
          'Real paired simulator WatchConnectivity, independent Watch scoring and uninterrupted local iPhone archive; no setup injection or external broadcast',
        configuration,
        phone,
        watch,
        pairId,
        snapshot: final.snapshot,
        pairingId: pairing.pairing_id,
        watchDeviceId: pairing.watch_device_id,
        outcomes,
        status,
        media,
      },
      null,
      2,
    ),
  );
  successMessage = `PASS: real companion pairing, five Watch commands and ${media.frames} contiguous archived frames. ${artifact}`;
} finally {
  killOwnedChildren();
  if (!successMessage) await collectConnectivityFailure();
  const errors = [];
  for (const [name, path] of Object.entries(resultPaths)) {
    await run(
      'xcrun',
      [
        'xcresulttool',
        'export',
        'attachments',
        '--path',
        path,
        '--output-path',
        join(artifact, `${name}-attachments`),
      ],
      `${name}-attachments`,
      { cleanup: true },
    ).catch(() => {});
  }
  if (api) {
    try {
      await api.stop();
    } catch (error) {
      errors.push(error);
    }
  }
  // Recover an owned UUID if creation completed just as a command was interrupted.
  if (!phone || !watch) {
    try {
      const devices = JSON.parse(
        await run('xcrun', ['simctl', 'list', 'devices', '--json'], 'cleanup-device-list', {
          cleanup: true,
        }),
      );
      const all = Object.values(devices.devices).flat();
      phone ??= all.find((device) => device.name === phoneName)?.udid;
      watch ??= all.find((device) => device.name === watchName)?.udid;
    } catch (error) {
      errors.push(error);
    }
  }
  for (const [name, id] of [
    ['watch', watch],
    ['phone', phone],
  ]) {
    if (id)
      await run('xcrun', ['simctl', 'shutdown', id], `shutdown-${name}`, { cleanup: true }).catch(
        () => {},
      );
  }
  if (pairId)
    await run('xcrun', ['simctl', 'unpair', pairId], 'unpair', { cleanup: true }).catch(() => {});
  for (const [name, id] of [
    ['watch', watch],
    ['phone', phone],
  ]) {
    if (!id) continue;
    try {
      await run('xcrun', ['simctl', 'delete', id], `delete-${name}`, { cleanup: true });
    } catch (error) {
      errors.push(error);
    }
  }
  process.off('SIGINT', interrupt);
  process.off('SIGTERM', interrupt);
  if (errors.length) throw new AggregateError(errors, 'Owned paired-device cleanup failed');
}

console.log(successMessage);
