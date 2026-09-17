import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { ownedCommand } from './owned-command.mjs';
import { createOwnedSimulator } from './owned-simulator.mjs';
import { qualifyEncoderPayload } from './encoder-payload-qualification.mjs';

assert.equal(process.platform, 'darwin');
const nativeMacAverageOnly = process.argv.slice(2).includes('--native-mac-average-only');
const nativeMacLowLatency = process.argv.slice(2).includes('--native-mac-low-latency');
const nativeMac =
  nativeMacAverageOnly || nativeMacLowLatency || process.argv.slice(2).includes('--native-mac');
const scheme = nativeMac
  ? 'ScorebugEncoderMacQualificationTests'
  : 'ScorebugEncoderQualificationTests';
const drainedTransition = process.argv.slice(2).includes('--drained-transition');
const transition = process.argv.slice(2).includes('--transition');
const halfResolution = process.argv.slice(2).includes('--half-resolution');
const lowLatency =
  nativeMacAverageOnly || nativeMacLowLatency || process.argv.slice(2).includes('--low-latency');
const preparation = process.argv.slice(2).includes('--preparation');
const resolution = process.argv.slice(2).includes('--resolution');
assert.deepEqual(
  process.argv.slice(2),
  nativeMac
    ? [
        nativeMacAverageOnly
          ? '--native-mac-average-only'
          : nativeMacLowLatency
            ? '--native-mac-low-latency'
            : '--native-mac',
      ]
    : drainedTransition
      ? ['--drained-transition']
      : transition
        ? ['--transition']
        : halfResolution
          ? ['--half-resolution']
          : lowLatency
            ? ['--low-latency']
            : resolution
              ? ['--resolution']
              : preparation
                ? ['--preparation']
                : [],
);
const testClass =
  transition || drainedTransition ? 'EncoderResolutionTransitionTests' : 'EncoderPayloadTests';
const method = nativeMacAverageOnly
  ? 'testFreshLowLatencyAverageOnly'
  : drainedTransition
    ? 'testDrainedResolutionTransitions'
    : transition
      ? 'testPacedResolutionTransitions'
      : halfResolution
        ? 'testFreshHalfResolutionProfiles'
        : lowLatency
          ? 'testFreshLowLatencyRateControl'
          : resolution
            ? 'testFreshResolutionProfiles'
            : preparation
              ? 'testFreshFrameRatePreparation'
              : 'testControlledRatesAndFreshLowEncoder';
const attachmentName = nativeMacAverageOnly
  ? 'EncoderLowLatencyAverageOnly'
  : drainedTransition
    ? 'EncoderDrainedTransition'
    : transition
      ? 'EncoderResolutionTransition'
      : halfResolution
        ? 'EncoderHalfResolution'
        : lowLatency
          ? 'EncoderLowLatency'
          : resolution
            ? 'EncoderResolution'
            : preparation
              ? 'EncoderPreparation'
              : 'EncoderPayload';
const root = fileURLToPath(new URL('..', import.meta.url));
const runtime = process.env.SCOREBUG_IOS_RUNTIME ?? '17.5';
assert.match(runtime, /^\d+\.\d+(?:\.\d+)?$/);
const cancellation = new AbortController();
const interrupt = () => {
  process.exitCode = 1;
  cancellation.abort();
};
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, interrupt);
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(
  join(
    root,
    'artifacts/qa/' +
      (nativeMac
        ? nativeMacAverageOnly
          ? 'encoder-native-mac-average-only-'
          : nativeMacLowLatency
            ? 'encoder-native-mac-low-latency-'
            : 'encoder-native-mac-'
        : drainedTransition
          ? 'encoder-drained-transition-'
          : transition
            ? 'encoder-resolution-transition-'
            : halfResolution
              ? 'encoder-half-resolution-'
              : lowLatency
                ? 'encoder-low-latency-'
                : resolution
                  ? 'encoder-resolution-'
                  : preparation
                    ? 'encoder-preparation-'
                    : 'encoder-payload-'),
  ),
);
console.log('Encoder payload diagnostic evidence: ' + artifact);
await writeFile(
  join(artifact, 'configuration.json'),
  JSON.stringify(
    {
      runtime: nativeMac ? 'native-macOS' : runtime,
      device: nativeMac ? 'Mac' : 'iPhone-14',
      scheme,
      method,
      scope: 'isolated native encoder; no network',
    },
    null,
    2,
  ),
);
let simulator;
async function run(binary, args, label, { timeout = 60000, cleanup = false } = {}) {
  const r = await ownedCommand(binary, args, {
    cwd: root,
    timeout,
    signal: cleanup ? undefined : cancellation.signal,
  });
  await writeFile(join(artifact, label + '.log'), r.stdout + r.stderr);
  assert.ok(
    r.ok,
    label +
      ' failed (' +
      (r.reason ?? r.error ?? r.code) +
      '); see ' +
      join(artifact, label + '.log'),
  );
  return r.stdout.trim();
}
try {
  const runtimeID = 'com.apple.CoreSimulator.SimRuntime.iOS-' + runtime.replaceAll('.', '-');
  if (!nativeMac) {
    const runtimes = JSON.parse(
      await run('xcrun', ['simctl', 'list', 'runtimes', '--json'], 'runtimes'),
    );
    assert.ok(
      runtimes.runtimes.some((r) => r.identifier === runtimeID && r.isAvailable),
      'Requested simulator runtime unavailable',
    );
  }
  await run('xcodegen', ['generate', '--spec', join(root, 'ios/Project.yml')], 'generate');
  cancellation.signal.throwIfAborted();
  if (!nativeMac)
    simulator = await createOwnedSimulator(run, 'Scorebug Encoder ' + randomUUID(), runtimeID);
  let workflowError;
  try {
    await run(
      'xcodebuild',
      [
        '-project',
        join(root, 'ios/Scorebug.xcodeproj'),
        '-scheme',
        scheme,
        '-only-testing:' + scheme + '/' + testClass + '/' + method,
        '-destination',
        nativeMac ? 'platform=macOS' : 'platform=iOS Simulator,id=' + simulator,
        '-destination-timeout',
        '60',
        '-parallel-testing-enabled',
        'NO',
        '-maximum-concurrent-test-simulator-destinations',
        '1',
        '-resultBundlePath',
        join(artifact, 'workflow.xcresult'),
        'test',
        'ARCHS=arm64',
        'ONLY_ACTIVE_ARCH=YES',
      ],
      'workflow',
      { timeout: 360000 },
    );
  } catch (error) {
    workflowError = error;
  }
  await run(
    'xcrun',
    [
      'xcresulttool',
      'export',
      'attachments',
      '--path',
      join(artifact, 'workflow.xcresult'),
      '--output-path',
      join(artifact, 'attachments'),
    ],
    'attachments',
    { cleanup: true },
  );
  const manifest = JSON.parse(await readFile(join(artifact, 'attachments/manifest.json'), 'utf8'));
  const rows = manifest
    .filter((r) => r.testIdentifier === testClass + '/' + method + '()')
    .flatMap((r) => r.attachments)
    .filter((a) => a.suggestedHumanReadableName.startsWith(attachmentName));
  assert.equal(rows.length, 1, 'Missing or duplicate encoder payload attachment');
  if (nativeMac) assert.ok(typeof rows[0].deviceId === 'string' && rows[0].deviceId.length > 0);
  else assert.equal(rows[0].deviceId, simulator);
  const name = rows[0].exportedFileName;
  assert.equal(basename(name), name);
  const path = join(artifact, 'attachments', name);
  assert.ok((await stat(path)).size <= 4 * 1024 * 1024, 'Oversized scalar report');
  const raw = await readFile(path, 'utf8');
  await writeFile(join(artifact, 'encoder-payload.json'), raw);
  const report = JSON.parse(raw);
  assert.equal(
    report.formatVersion,
    nativeMac
      ? nativeMacAverageOnly
        ? 11
        : nativeMacLowLatency
          ? 10
          : 9
      : drainedTransition
        ? 8
        : transition
          ? 7
          : halfResolution
            ? 6
            : lowLatency
              ? 5
              : resolution
                ? 4
                : preparation
                  ? 3
                  : 2,
    'Current probe must supply native property snapshots',
  );
  const result = qualifyEncoderPayload(report);
  await writeFile(join(artifact, 'results.json'), JSON.stringify(result, null, 2));
  if (workflowError) throw workflowError;
  console.log(
    'DIAGNOSTIC PASS: ' +
      JSON.stringify({
        frames: result.frames,
        phaseMbps: result.phases.map((p) => p.meanMbps),
        dynamicLowToFreshLow: result.dynamicLowToFreshLow,
        earlyToLate: result.earlyToLate,
        reducedToFull: result.reducedToFull,
        lowLatencyToDefault: result.lowLatencyToDefault,
        scope: result.scope,
      }),
  );
} finally {
  try {
    if (simulator) {
      await run('xcrun', ['simctl', 'shutdown', simulator], 'shutdown', { cleanup: true }).catch(
        () => {},
      );
      await run('xcrun', ['simctl', 'delete', simulator], 'delete', { cleanup: true });
    }
  } finally {
    for (const signal of ['SIGINT', 'SIGTERM']) process.removeListener(signal, interrupt);
  }
}
