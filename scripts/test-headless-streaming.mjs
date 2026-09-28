// Faster opt-in native media diagnosis, not simulator/UI acceptance.
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { chmod, mkdir, mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deviceLabOptions, startDeviceLab } from './device-lab.mjs';
import { runOrdinaryCommand } from './test-ordinary-native-app.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const values = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index],
    value = process.argv[index + 1];
  assert(
    [
      '--host',
      '--source',
      '--duration',
      '--quality',
      '--timing-audit',
      '--disconnect-after',
      '--relay-outage-seconds',
    ].includes(key) &&
      value &&
      !values.has(key),
  );
  values.set(key, value);
}
const source = values.get('--source');
assert(source && isAbsolute(source), 'Provide an absolute prepared media path');
const quality = values.get('--quality') ?? '2160';
assert(['1080', '2160'].includes(quality));
const timingAudit = values.get('--timing-audit') ?? 'on';
assert(['on', 'off'].includes(timingAudit));
const duration = Number(values.get('--duration') ?? '120');
const disconnectAfter = Number(values.get('--disconnect-after') ?? '0');
const outageSeconds = Number(values.get('--relay-outage-seconds') ?? '0');
assert(
  outageSeconds === 0 ||
    (Number.isInteger(outageSeconds) &&
      outageSeconds >= 10 &&
      outageSeconds <= 60 &&
      disconnectAfter > 0 &&
      disconnectAfter + outageSeconds + 30 < duration),
);
assert(
  Number.isInteger(disconnectAfter) &&
    disconnectAfter >= 0 &&
    (disconnectAfter === 0 || disconnectAfter + 20 < duration),
);
assert(Number.isInteger(duration) && duration >= 10 && duration <= 600);
const options = deviceLabOptions(['--host', values.get('--host'), '--encoder', 'videotoolbox']);
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/headless-native-'));
await chmod(artifact, 0o700);
console.log(
  JSON.stringify({ artifact, scope: 'headless native diagnostic; no UI/media qualification' }),
);
const controller = new AbortController();
const interrupt = () => controller.abort();
process.once('SIGINT', interrupt);
process.once('SIGTERM', interrupt);
const run = (command, args, label, timeout = 120000) =>
  runOrdinaryCommand(command, args, { artifact, label, timeout, signal: controller.signal });
let lab, failure;
const cleanupFailures = [];
try {
  const derived = join(root, 'ios/DerivedData/FilmModel');
  const test = 'ScorebugFilmModelTests/FilmModelTests/testHeadlessLocalStreamingDiagnostic';
  await run(
    'xcodebuild',
    [
      '-project',
      'ios/Scorebug.xcodeproj',
      '-scheme',
      'ScorebugFilmModelTests',
      '-destination',
      'platform=macOS',
      '-derivedDataPath',
      derived,
      'build-for-testing',
      `-only-testing:${test}`,
      'CODE_SIGNING_ALLOWED=YES',
      'CODE_SIGN_IDENTITY=-',
    ],
    'build',
    600000,
  );
  lab = await startDeviceLab(
    { ...options, ...(quality === '2160' ? { uhd: true } : {}), decodedGeometry: true },
    { signal: controller.signal },
  );
  const config = join(artifact, 'config.json');
  await writeFile(
    config,
    JSON.stringify({
      setup: lab.setup,
      source,
      artifact,
      duration,
      uhd: quality === '2160',
      timingAudit: timingAudit === 'on',
      expectReconnect: disconnectAfter > 0,
    }),
    { mode: 0o600 },
  );
  const products = join(derived, 'Build/Products');
  const configurations = (await readdir(products)).filter(
    (name) => name.endsWith('.xctestrun') && name.startsWith('ScorebugFilmModelTests'),
  );
  assert.equal(configurations.length, 1, 'Expected exactly one Mac test configuration');
  const configure = join(artifact, 'configure.py'),
    destination = join(artifact, 'headless.xctestrun');
  await writeFile(
    configure,
    `import plistlib,sys\nsource,destination,config,products=sys.argv[1:]\nwith open(source,'rb') as f: value=plistlib.load(f)\ndef patch(x):\n if isinstance(x,dict):\n  if 'TestBundlePath' in x: x.setdefault('EnvironmentVariables',{})['SCOREBUG_HEADLESS_CONFIG']=config\n  for k,v in list(x.items()): x[k]=patch(v)\n elif isinstance(x,list): x=[patch(v) for v in x]\n elif isinstance(x,str): x=x.replace('__TESTROOT__',products)\n return x\nwith open(destination,'wb') as f: plistlib.dump(patch(value),f)\n`,
    { mode: 0o600 },
  );
  await run(
    'python3',
    [configure, join(products, configurations[0]), destination, config, products],
    'configure',
  );
  const workflow = run(
    'xcodebuild',
    [
      'test-without-building',
      '-xctestrun',
      destination,
      '-destination',
      'platform=macOS',
      `-only-testing:${test}`,
      '-resultBundlePath',
      join(artifact, 'workflow.xcresult'),
    ],
    'workflow',
    (duration + 90) * 1000,
  );
  if (disconnectAfter > 0) {
    const inject = (async () => {
      const deadline = Date.now() + 30000;
      while (true) {
        controller.signal.throwIfAborted();
        try {
          await readFile(join(artifact, 'native-ready.json'));
          break;
        } catch (error) {
          if (error.code !== 'ENOENT') throw error;
        }
        assert(Date.now() < deadline, 'Native capture did not become ready');
        await delay(100, undefined, { signal: controller.signal });
      }
      await delay(disconnectAfter * 1000, undefined, { signal: controller.signal });
      controller.signal.throwIfAborted();
      if (outageSeconds > 0) await lab.pauseRelay(outageSeconds);
      else await lab.disconnectPublisher();
    })();
    try {
      await Promise.all([workflow, inject]);
    } catch (error) {
      controller.abort();
      await Promise.allSettled([workflow, inject]);
      throw error;
    }
  } else await workflow;
  const result = JSON.parse(await readFile(join(artifact, 'diagnostic.json'), 'utf8'));
  assert.equal(result.scope, 'headless-native-diagnostic-v1');
  assert.equal(result.recordingAtEnd, true);
  assert.equal(result.publishingAtEnd, true);
  assert(result.samples.length > 0, 'Test must execute, not skip');
  if (disconnectAfter > 0) {
    assert(
      result.lifecycle.some((entry) => entry.state === 'failed'),
      'Native connection loss must be observed',
    );
    const attempts = new Set(
      result.lifecycle
        .filter((entry) => entry.state === 'publishing')
        .map((entry) => entry.attempt),
    );
    assert.equal(
      attempts.size,
      2,
      'Native app must establish one successfully publishing replacement',
    );
    assert.equal(
      new Set(result.lifecycle.map((entry) => entry.recording)).size,
      1,
      'Archive must remain the same recording',
    );
    assert.equal(
      new Set(
        result.lifecycle
          .filter((entry) => entry.state === 'publishing')
          .map((entry) => entry.generation),
      ).size,
      1,
      'Reconnect must preserve broadcast generation',
    );
  }
  assert.equal(result.timingAuditEnabled, timingAudit === 'on');
  if (timingAudit === 'on') {
    const cadence = JSON.parse(await readFile(join(artifact, 'cadence.json'), 'utf8'));
    assert.equal(cadence.closed, true, 'Native audit must join before completing');
    assert.equal(cadence.overflow, false, 'Choose a shorter diagnostic duration');
    assert.equal(cadence.invalid, false);
  }
} catch (error) {
  failure = String(error);
} finally {
  try {
    await lab?.stop();
  } catch (error) {
    cleanupFailures.push(String(error));
  }
  process.removeListener('SIGINT', interrupt);
  process.removeListener('SIGTERM', interrupt);
  await writeFile(
    join(artifact, 'result.json'),
    JSON.stringify(
      { artifact, lab: lab?.artifact, failure, cleanupFailures, mediaQualified: false },
      null,
      2,
    ),
    { mode: 0o600 },
  );
}
if (failure || cleanupFailures.length) throw new Error(failure ?? 'Lab cleanup failed');
console.log(JSON.stringify({ artifact, diagnosticComplete: true, mediaQualified: false }));
