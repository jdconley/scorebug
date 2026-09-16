import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { ownedCommand } from './owned-command.mjs';
import { createOwnedSimulator } from './owned-simulator.mjs';
import { qualifyEncoderPayload } from './encoder-payload-qualification.mjs';

assert.equal(process.platform, 'darwin');
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
const artifact = await mkdtemp(join(root, 'artifacts/qa/encoder-payload-'));
console.log('Encoder payload diagnostic evidence: ' + artifact);
await writeFile(
  join(artifact, 'configuration.json'),
  JSON.stringify(
    {
      runtime,
      device: 'iPhone-14',
      scheme: 'ScorebugEncoderQualificationTests',
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
  const runtimes = JSON.parse(
    await run('xcrun', ['simctl', 'list', 'runtimes', '--json'], 'runtimes'),
  );
  const runtimeID = 'com.apple.CoreSimulator.SimRuntime.iOS-' + runtime.replaceAll('.', '-');
  assert.ok(
    runtimes.runtimes.some((r) => r.identifier === runtimeID && r.isAvailable),
    'Requested simulator runtime unavailable',
  );
  await run('xcodegen', ['generate', '--spec', join(root, 'ios/Project.yml')], 'generate');
  cancellation.signal.throwIfAborted();
  simulator = await createOwnedSimulator(run, 'Scorebug Encoder ' + randomUUID(), runtimeID);
  let workflowError;
  try {
    await run(
      'xcodebuild',
      [
        '-project',
        join(root, 'ios/Scorebug.xcodeproj'),
        '-scheme',
        'ScorebugEncoderQualificationTests',
        '-destination',
        'platform=iOS Simulator,id=' + simulator,
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
    .filter(
      (r) => r.testIdentifier === 'EncoderPayloadTests/testControlledRatesAndFreshLowEncoder()',
    )
    .flatMap((r) => r.attachments)
    .filter((a) => a.suggestedHumanReadableName.startsWith('EncoderPayload'));
  assert.equal(rows.length, 1, 'Missing or duplicate encoder payload attachment');
  assert.equal(rows[0].deviceId, simulator);
  const name = rows[0].exportedFileName;
  assert.equal(basename(name), name);
  const path = join(artifact, 'attachments', name);
  assert.ok((await stat(path)).size <= 4 * 1024 * 1024, 'Oversized scalar report');
  const raw = await readFile(path, 'utf8');
  await writeFile(join(artifact, 'encoder-payload.json'), raw);
  const result = qualifyEncoderPayload(JSON.parse(raw));
  await writeFile(join(artifact, 'results.json'), JSON.stringify(result, null, 2));
  if (workflowError) throw workflowError;
  console.log(
    'DIAGNOSTIC PASS: ' +
      JSON.stringify({
        frames: result.frames,
        phaseMbps: result.phases.map((p) => p.meanMbps),
        dynamicLowToFreshLow: result.dynamicLowToFreshLow,
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
