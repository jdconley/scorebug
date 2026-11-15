import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { ownedCommand } from './owned-command.mjs';
import { createOwnedSimulator } from './owned-simulator.mjs';
import { qualifyEncoderBufferDepth } from './encoder-buffer-depth-qualification.mjs';
assert.equal(process.platform, 'darwin');
assert.deepEqual(process.argv.slice(2), []);
const root = fileURLToPath(new URL('..', import.meta.url));
const runtime = process.env.SCOREBUG_IOS_RUNTIME ?? '17.5';
assert.match(runtime, /^\d+\.\d+(?:\.\d+)?$/);
const scheme = 'ScorebugEncoderQualificationTests',
  testClass = 'EncoderBufferDepthTests',
  method = 'testDefaultCandidateBufferDepth';
const cancellation = new AbortController();
const interrupt = () => {
  process.exitCode = 1;
  cancellation.abort();
};
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, interrupt);
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/encoder-buffer-depth-'));
console.log('Encoder buffer-depth evidence: ' + artifact);
await writeFile(
  join(artifact, 'configuration.json'),
  JSON.stringify(
    {
      runtime,
      device: 'iPhone-14',
      scheme,
      testClass,
      method,
      scope: 'isolated native encoder; no network or recording',
    },
    null,
    2,
  ),
);
async function run(binary, args, label, { timeout = 60000, cleanup = false } = {}) {
  const result = await ownedCommand(binary, args, {
    cwd: root,
    timeout,
    signal: cleanup ? undefined : cancellation.signal,
  });
  await writeFile(join(artifact, label + '.log'), result.stdout + result.stderr);
  assert.ok(
    result.ok,
    label +
      ' failed (' +
      (result.reason ?? result.error ?? result.code) +
      '); see ' +
      join(artifact, label + '.log'),
  );
  return result.stdout.trim();
}
let simulator;
try {
  const runtimeID = 'com.apple.CoreSimulator.SimRuntime.iOS-' + runtime.replaceAll('.', '-');
  const runtimes = JSON.parse(
    await run('xcrun', ['simctl', 'list', 'runtimes', '--json'], 'runtimes'),
  );
  assert.ok(runtimes.runtimes.some((r) => r.identifier === runtimeID && r.isAvailable));
  await run('xcodegen', ['generate', '--spec', join(root, 'ios/Project.yml')], 'generate');
  cancellation.signal.throwIfAborted();
  simulator = await createOwnedSimulator(run, 'Scorebug Buffer Depth ' + randomUUID(), runtimeID);
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
        'CODE_SIGNING_ALLOWED=NO',
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
    .filter((a) => a.suggestedHumanReadableName.startsWith('EncoderBufferDepth'));
  assert.equal(rows.length, 1, 'Missing or duplicate exact diagnostic attachment');
  assert.equal(rows[0].deviceId, simulator);
  const name = rows[0].exportedFileName;
  assert.equal(basename(name), name);
  const path = join(artifact, 'attachments', name);
  assert.ok((await stat(path)).size <= 512 * 1024);
  const raw = await readFile(path, 'utf8');
  await writeFile(join(artifact, 'encoder-buffer-depth.json'), raw);
  const qualified = qualifyEncoderBufferDepth(JSON.parse(raw));
  await writeFile(join(artifact, 'results.json'), JSON.stringify(qualified, null, 2));
  if (workflowError) throw workflowError;
  console.log('DIAGNOSTIC PASS: ' + JSON.stringify(qualified));
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
