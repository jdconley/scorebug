import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { deviceLabOptions, startDeviceLab } from './device-lab.mjs';
import { runOrdinaryCommand, requireOrdinaryTestResult } from './test-ordinary-native-app.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
export const physicalRecoveryTest =
  'ScorebugAppUITests/PhysicalStreamingTests/testPhysicalIPhoneRecover720ScoreStopAndExport';
export function physicalRecoveryOptions(args, interfaces) {
  const values = new Map();
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i],
      value = args[i + 1];
    assert(
      ['--host', '--device', '--team', '--encoder', '--publish-peer-latency-ms'].includes(key) &&
        value &&
        !values.has(key),
      'Invalid or duplicate physical option',
    );
    values.set(key, value);
  }
  const device = values.get('--device'),
    team = values.get('--team') ?? 'B222J9J7B8';
  assert(
    /^[0-9A-F]{8}-[0-9A-F]{16}$/i.test(device ?? ''),
    'Explicit physical device UDID required',
  );
  assert(/^[A-Z0-9]{10}$/.test(team), 'Invalid signing team');
  const options = deviceLabOptions(
    [
      '--host',
      values.get('--host'),
      '--duration',
      '900',
      '--encoder',
      values.get('--encoder') ?? 'software',
      '--publish-peer-latency-ms',
      values.get('--publish-peer-latency-ms') ?? '700',
    ],
    interfaces,
  );
  return { ...options, device, team };
}
export function physicalRecoveryEnvironment(lab) {
  const api = new URL(lab.setup.endpoint),
    control = new URL(lab.recoveryControl.endpoint);
  // WHATWG URL parsing normalizes decimal/hex and percent-encoded hostnames.
  // Require literal canonical IPv4 authority before relying on parsed equality.
  for (const value of [lab.setup.endpoint, lab.recoveryControl.endpoint]) {
    const match = /^https?:\/\/([0-9]+(?:\.[0-9]+){3})(?::([1-9][0-9]*))?\/?$/.exec(value);
    assert(
      match && match[1] === new URL(value).hostname,
      'Canonical literal private host required',
    );
  }
  const octets = api.hostname.split('.').map(Number);
  assert(
    octets.length === 4 &&
      octets.every((n) => Number.isInteger(n) && n >= 0 && n <= 255) &&
      octets.join('.') === api.hostname,
  );
  assert(
    octets[0] === 10 ||
      (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] === 192 && octets[1] === 168),
  );
  assert(
    ['http:', 'https:'].includes(api.protocol) &&
      !api.username &&
      !api.password &&
      !api.search &&
      !api.hash,
  );
  assert(
    control.protocol === 'http:' &&
      control.hostname === api.hostname &&
      control.port &&
      !control.username &&
      !control.password &&
      !control.search &&
      !control.hash &&
      control.pathname === '/',
    'Physical controller must use the exact private API host',
  );
  assert.match(lab.recoveryControl.token, /^[a-f0-9]{64}$/);
  assert.match(lab.recoveryControl.runID, /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i);
  assert(typeof lab.setup.installationToken === 'string' && lab.setup.installationToken.length > 0);
  return {
    SCOREBUG_PHYSICAL_RECOVERY_720: '1',
    SCOREBUG_DEVICE_API_URL: lab.setup.endpoint,
    SCOREBUG_DEVICE_TOKEN: lab.setup.installationToken,
    SCOREBUG_RECOVERY_CONTROL_URL: lab.recoveryControl.endpoint,
    SCOREBUG_RECOVERY_CONTROL_TOKEN: lab.recoveryControl.token,
    SCOREBUG_RECOVERY_RUN_ID: lab.recoveryControl.runID,
  };
}
/** A cancellation is handled by the finite workflow owner. Never tear down its
 * server before that owner has returned from native stop/export or joined failure. */
export async function withPhysicalRecoveryLab(start, workflow) {
  const lab = await start();
  try {
    return await workflow(lab);
  } finally {
    await lab.stop();
  }
}
const configurePython = `import json,plistlib,sys,os
source,destination,target,environment_path,products=sys.argv[1:]
with open(source,'rb') as f:config=plistlib.load(f)
with open(environment_path) as f:environment=json.load(f)
def clean(v):
 if isinstance(v,dict):return {k:clean(x) for k,x in v.items() if 'SCOREBUG' not in k}
 if isinstance(v,list):return [clean(x) for x in v]
 if isinstance(v,str):return v.replace('__TESTROOT__',products)
 return v
config=clean(config);found=[]
def configure(v):
 if isinstance(v,dict):
  if v.get('BlueprintName')==target:
   found.append(target);v.setdefault('EnvironmentVariables',{}).update(environment)
  for x in v.values():configure(x)
 elif isinstance(v,list):
  for x in v:configure(x)
configure(config);assert len(found)==1
with open(destination,'xb') as f:plistlib.dump(config,f)
os.chmod(destination,0o600)
`;
async function main() {
  assert.equal(process.platform, 'darwin', 'Physical Apple workflow requires macOS');
  const options = physicalRecoveryOptions(process.argv.slice(2));
  await mkdir(join(root, 'artifacts/qa'), { recursive: true });
  const artifact = await mkdtemp(join(root, 'artifacts/qa/physical-recovery-'));
  await chmod(artifact, 0o700);
  const controller = new AbortController(),
    commands = [],
    cleanupFailures = [];
  const interrupt = () => controller.abort();
  process.once('SIGINT', interrupt);
  process.once('SIGTERM', interrupt);
  const run = (command, args, label, timeout = 60000) =>
    runOrdinaryCommand(command, args, {
      artifact,
      label,
      timeout,
      signal: controller.signal,
      commands,
    });
  let labArtifact,
    sourceHead,
    failure,
    workflowPassed = false;
  console.log(
    JSON.stringify({ artifact, scope: 'Physical camera recovery; no fixture media qualification' }),
  );
  try {
    sourceHead = await run('git', ['rev-parse', 'HEAD'], 'source-head');
    const derived = join(root, 'ios/DerivedData/PhysicalPhone'),
      products = join(derived, 'Build/Products');
    await run(
      'xcodebuild',
      [
        '-project',
        join(root, 'ios/Scorebug.xcodeproj'),
        '-scheme',
        'Scorebug',
        '-destination',
        'generic/platform=iOS',
        '-configuration',
        'Debug',
        '-derivedDataPath',
        derived,
        `DEVELOPMENT_TEAM=${options.team}`,
        '-allowProvisioningUpdates',
        'build-for-testing',
      ],
      'build',
      900000,
    );
    const lockPath = join(artifact, 'device-lock-state.json');
    await run(
      'xcrun',
      [
        'devicectl',
        'device',
        'info',
        'lockState',
        '--device',
        options.device,
        '--timeout',
        '20',
        '--json-output',
        lockPath,
      ],
      'readiness',
      30000,
    );
    const lock = JSON.parse(await readFile(lockPath, 'utf8'));
    assert.equal(
      lock.result?.passcodeRequired,
      false,
      'Unlock the phone before starting the camera recovery test',
    );
    const inputs = await readPhysicalRecoveryInputs(products, [
      fileURLToPath(import.meta.url),
      ...['device-lab.mjs', 'ordinary-recovery-control.mjs', 'udp-impairment.mjs',
        'private-lab-network.mjs', 'test-ordinary-native-app.mjs'].map(name => join(root, 'scripts', name)),
    ]);
    await writeFile(
      join(artifact, 'inputs.json'),
      JSON.stringify({ sourceHead, device: options.device, inputs }, null, 2),
      { flag: 'wx', mode: 0o600 },
    );
    await withPhysicalRecoveryLab(
      async () => {
        const lab = await startDeviceLab(
          { ...options, publisherRecovery: true, physicalRecovery: true, decodedGeometry: true },
          { signal: controller.signal },
        );
        labArtifact = lab.artifact;
        return {
          ...lab,
          stop: async () => {
            try {
              await lab.stop();
            } catch (error) {
              cleanupFailures.push('lab shutdown');
              throw error;
            }
          },
        };
      },
      async (lab) => {
        const environmentPath = join(artifact, 'phone-environment.json'),
          configure = join(artifact, 'configure.py'),
          testRun = join(artifact, 'phone.xctestrun');
        await writeFile(environmentPath, JSON.stringify(physicalRecoveryEnvironment(lab)), {
          flag: 'wx',
          mode: 0o600,
        });
        await writeFile(configure, configurePython, { flag: 'wx', mode: 0o600 });
        await run(
          'python3',
          [
            configure,
            join(products, 'Scorebug_iphoneos26.2-arm64.xctestrun'),
            testRun,
            'ScorebugAppUITests',
            environmentPath,
            products,
          ],
          'configure',
        );
        const configuredInputs = await readPhysicalRecoveryInputs(products, [testRun]);
        await writeFile(join(artifact, 'configured-inputs.json'), JSON.stringify(configuredInputs, null, 2), {flag: 'wx', mode: 0o600});
        await run(
          'xcodebuild',
          [
            'test-without-building',
            '-xctestrun',
            testRun,
            '-destination',
            `id=${options.device}`,
            '-destination-timeout',
            '120',
            '-resultBundlePath',
            join(artifact, 'workflow.xcresult'),
            '-parallel-testing-enabled',
            'NO',
            '-maximum-test-execution-time-allowance',
            '780',
            `-only-testing:${physicalRecoveryTest}`,
          ],
          'workflow',
          900000,
        );
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
            'test-summary',
          ),
        );
        const tests = JSON.parse(
          await run(
            'xcrun',
            [
              'xcresulttool',
              'get',
              'test-results',
              'tests',
              '--path',
              join(artifact, 'workflow.xcresult'),
            ],
            'test-leaves',
          ),
        );
        requireOrdinaryTestResult(summary, tests, physicalRecoveryTest);
        await verifyPhysicalRecoveryInputs(inputs);
        await verifyPhysicalRecoveryInputs(configuredInputs);
      },
    );
    workflowPassed = true;
  } catch (error) {
    failure = String(error.message);
  } finally {
    await writeFile(
      join(artifact, 'result.json'),
      JSON.stringify(
        {
          formatVersion: 1,
          lane: 'physical-recovery720',
          sourceHead,
          device: options.device,
          host: options.host,
          workflowPassed,
          mediaQualified: false,
          labArtifact,
          failure,
          cleanupFailures,
          commands,
          joined: failure === undefined && cleanupFailures.length === 0,
        },
        null,
        2,
      ) + '\n',
      { flag: 'wx', mode: 0o600 },
    );
    process.removeListener('SIGINT', interrupt);
    process.removeListener('SIGTERM', interrupt);
  }
  console.log(
    JSON.stringify({ artifact, workflowPassed, mediaQualified: false, failure, cleanupFailures }),
  );
  if (failure || cleanupFailures.length) process.exitCode = 1;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href)
  await main();

async function hashInput(path) {
  const data = await readFile(path);
  return {path, sha256: createHash('sha256').update(data).digest('hex'), bytes: data.length};
}
export async function readPhysicalRecoveryInputs(products, extraPaths = []) {
  const names = [
    'Debug-iphoneos/Scorebug.app/Scorebug',
    'Debug-iphoneos/Scorebug.app/Scorebug.debug.dylib',
    'Debug-iphoneos/ScorebugAppUITests-Runner.app/ScorebugAppUITests-Runner',
    'Debug-iphoneos/ScorebugAppUITests-Runner.app/PlugIns/ScorebugAppUITests.xctest/ScorebugAppUITests',
    'Scorebug_iphoneos26.2-arm64.xctestrun',
  ];
  return Promise.all([...names.map(name => join(products, name)), ...extraPaths].map(hashInput));
}
export async function verifyPhysicalRecoveryInputs(inputs) {
  for (const input of inputs) assert.deepEqual(await hashInput(input.path), input, `Execution input changed: ${input.path}`);
}
