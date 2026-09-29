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
      '--worker-encoder',
      '--source',
      '--duration',
      '--quality',
      '--timing-audit',
      '--disconnect-after',
      '--relay-outage-seconds',
      '--publisher-blackhole-seconds',
      '--client-outage-seconds',
      '--fixed-uhd',
      '--fixed-uhd-transition',
      '--owned-uhd-transition',
      '--warm-uhd-candidate',
      '--warm-uhd-probe',
      '--direct-uhd',
      '--freeze-uhd-polling',
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
const relayOutageSeconds = Number(values.get('--relay-outage-seconds') ?? '0');
const blackholeSeconds = Number(values.get('--publisher-blackhole-seconds') ?? '0');
const clientOutageSeconds = Number(values.get('--client-outage-seconds') ?? '0');
assert(Number.isInteger(relayOutageSeconds) && relayOutageSeconds >= 0);
assert(Number.isInteger(blackholeSeconds) && blackholeSeconds >= 0);
assert(Number.isInteger(clientOutageSeconds) && clientOutageSeconds >= 0);
assert(
  [relayOutageSeconds, blackholeSeconds, clientOutageSeconds].filter(Boolean).length <= 1,
  'Select one outage',
);
const outageSeconds = relayOutageSeconds || blackholeSeconds || clientOutageSeconds;
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
const fixedUHD = values.get('--fixed-uhd') === 'on';
const fixedUHDTransition = values.get('--fixed-uhd-transition') === 'on';
assert(!values.has('--fixed-uhd-transition') || (fixedUHDTransition && fixedUHD));
const ownedUHDTransition = values.get('--owned-uhd-transition') === 'on';
assert(!values.has('--owned-uhd-transition') || (ownedUHDTransition && fixedUHDTransition));
const warmUHDCandidate = values.get('--warm-uhd-candidate') === 'on';
assert(!values.has('--warm-uhd-candidate') || (warmUHDCandidate && ownedUHDTransition));
const warmUHDProbe = values.get('--warm-uhd-probe') === 'on';
assert(!values.has('--warm-uhd-probe') || (warmUHDProbe && ownedUHDTransition));
const directUHD = values.get('--direct-uhd') === 'on';
assert(!values.has('--direct-uhd') || directUHD);
const freezeUHDPolling = values.get('--freeze-uhd-polling') === 'on';
assert(!values.has('--freeze-uhd-polling') || (freezeUHDPolling && directUHD && duration <= 60));
assert(
  !directUHD ||
    (quality === '2160' &&
      !fixedUHD &&
      duration <= 120 &&
      timingAudit === 'off' &&
      disconnectAfter === 0),
);
assert(!values.has('--fixed-uhd') || values.get('--fixed-uhd') === 'on');
assert(
  !fixedUHD ||
    (quality === '2160' && timingAudit === 'off' && duration <= 60 && disconnectAfter === 0),
);
const workerEncoder = values.get('--worker-encoder') ?? 'videotoolbox';
assert(['software', 'videotoolbox'].includes(workerEncoder));
const options = deviceLabOptions(['--host', values.get('--host'), '--encoder', workerEncoder]);
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
    {
      ...options,
      ...(quality === '2160' ? { uhd: true } : {}),
      decodedGeometry: true,
      publisherBlackhole: blackholeSeconds > 0 || clientOutageSeconds > 0,
      clientNetworkOutage: clientOutageSeconds > 0,
    },
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
      fixedUHD,
      fixedUHDTransition,
      ownedUHDTransition,
      warmUHDCandidate,
      warmUHDProbe,
      directUHD,
      freezeUHDPolling,
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
      if (blackholeSeconds > 0 || clientOutageSeconds > 0)
        await lab.blackholePublisher(blackholeSeconds || clientOutageSeconds);
      else if (relayOutageSeconds > 0) await lab.pauseRelay(relayOutageSeconds);
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
  assert.equal(result.fixedUHD, fixedUHD);
  assert.equal(result.fixedUHDTransition, fixedUHDTransition);
  assert.equal(result.ownedUHDTransition, ownedUHDTransition);
  assert.equal(result.warmUHDCandidate, warmUHDCandidate);
  if (warmUHDCandidate) assert(result.warmedCandidateInputCount >= 97);
  assert.equal(result.warmUHDProbe, warmUHDProbe);
  if (warmUHDProbe) assert(result.warmedProbeBytes > 0);
  assert.equal(result.directUHD, directUHD);
  assert.equal(result.freezeUHDPolling, freezeUHDPolling);
  if (fixedUHDTransition) assert.equal(result.transitionAcknowledged, true);
  assert(
    (fixedUHD ? result.boundarySampleCount : result.samples.length) > 0,
    'Test must execute, not skip',
  );
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
