import assert from 'node:assert/strict';
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  writeFile,
  readdir,
  stat,
  statfs,
} from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import {
  physicalRecordingIdentity,
  requireNativeExportReport,
  qualifyCombinedNativeEvidence,
  qualifyCombinedGeometry,
  qualifyCombinedResources,
  requirePhysicalQualificationResult,
} from './physical-qualification-evidence.mjs';
import { mediaTools } from './media-tools.mjs';
import { deviceLabOptions, startDeviceLab } from './device-lab.mjs';
import { runOrdinaryCommand, requireOrdinaryTestResult } from './test-ordinary-native-app.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
export const physicalRecoveryTest =
  'ScorebugAppUITests/PhysicalStreamingTests/testPhysicalIPhoneRecover720ScoreStopAndExport';
export const physicalNetworkProbeTest =
  'ScorebugAppUITests/PhysicalStreamingTests/testPhysicalRecoveryNetworkProbe';
export const physicalSavedExportTest =
  'ScorebugAppUITests/PhysicalStreamingTests/testPhysicalSavedArchiveRecoveryExportAndRelaunch';
export const physicalArchiveStopTest =
  'ScorebugAppUITests/PhysicalStreamingTests/testPhysicalShort4KArchiveStopExportAndRelaunch';
export function physicalRecoveryOptions(args, interfaces) {
  const values = new Map();
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i],
      value = args[i + 1];
    assert(
      [
        '--host',
        '--device',
        '--team',
        '--encoder',
        '--publish-peer-latency-ms',
        '--lane',
        '--runner-transport',
        '--bridge-port',
        '--hold-seconds',
        '--recording-id',
      ].includes(key) &&
        value &&
        !values.has(key),
      'Invalid or duplicate physical option',
    );
    values.set(key, value);
  }
  const lane = values.get('--lane') ?? 'recovery720';
  assert(
    [
      'recovery720',
      'quality1080',
      'network-probe',
      'combined1080',
      'saved-export',
      'archive-stop',
    ].includes(lane),
    'Invalid physical lane',
  );
  const holdText = values.get('--hold-seconds'),
    holdSeconds = holdText === undefined ? undefined : Number(holdText);
  if (lane === 'combined1080')
    assert(
      [600, 1800, 3600].includes(holdSeconds) && String(holdSeconds) === holdText,
      'Combined hold must be canonical 600, 1800 or 3600 seconds',
    );
  else assert(holdText === undefined, 'Hold seconds require combined1080');
  const recordingID = values.get('--recording-id');
  if (lane === 'saved-export')
    assert(
      /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(recordingID ?? ''),
      'Exact canonical uppercase recording ID required',
    );
  else assert(recordingID === undefined, 'Recording ID requires saved-export');
  const runnerTransport = values.get('--runner-transport') ?? 'direct';
  assert(['direct', 'app-loopback'].includes(runnerTransport), 'Invalid runner transport');
  const bridgePort = values.has('--bridge-port') ? Number(values.get('--bridge-port')) : undefined;
  if (runnerTransport === 'app-loopback') {
    assert(
      Number.isInteger(bridgePort) &&
        bridgePort >= 49152 &&
        bridgePort <= 65535 &&
        String(bridgePort) === values.get('--bridge-port'),
      'Explicit canonical high bridge port required',
    );
  } else assert(bridgePort === undefined, 'Bridge port requires app-loopback transport');
  if (['saved-export', 'archive-stop'].includes(lane))
    assert(runnerTransport === 'direct', 'Archive-only lanes have no control bridge');
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
      lane === 'network-probe'
        ? '240'
        : lane === 'combined1080'
          ? String(holdSeconds + 3000)
          : '900',
      '--encoder',
      values.get('--encoder') ?? 'software',
      '--publish-peer-latency-ms',
      values.get('--publish-peer-latency-ms') ?? '700',
    ],
    interfaces,
  );
  return { ...options, device, team, lane, runnerTransport, bridgePort, holdSeconds, recordingID };
}
export function physicalRecoveryEnvironment(
  lab,
  lane = 'recovery720',
  { runnerTransport = 'direct', bridgePort, holdSeconds, recordingID } = {},
) {
  if (lane === 'saved-export') {
    assert(
      runnerTransport === 'direct' &&
        bridgePort === undefined &&
        /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(recordingID ?? ''),
      'Invalid saved export selection',
    );
    return { SCOREBUG_PHYSICAL_SAVED_ARCHIVE_ID: recordingID };
  }
  if (lane === 'archive-stop') {
    assert(
      runnerTransport === 'direct' && bridgePort === undefined && recordingID === undefined,
      'Archive stop does not select retained media or a bridge',
    );
    return { SCOREBUG_PHYSICAL_SHORT_ARCHIVE: '1' };
  }
  assert(
    ['recovery720', 'quality1080', 'network-probe', 'combined1080'].includes(lane),
    'Invalid physical lane',
  );
  if (lane === 'combined1080')
    assert([600, 1800, 3600].includes(holdSeconds), 'Invalid combined hold');
  assert(['direct', 'app-loopback'].includes(runnerTransport), 'Invalid runner transport');
  if (runnerTransport === 'app-loopback')
    assert(
      Number.isInteger(bridgePort) && bridgePort >= 49152 && bridgePort <= 65535,
      'Invalid bridge port',
    );
  else assert(bridgePort === undefined, 'Bridge port requires app-loopback');
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
    if (runnerTransport === 'app-loopback')
      assert(match[2], 'Explicit API and controller ports required for bridge');
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
    ...(runnerTransport === 'app-loopback'
      ? {
          SCOREBUG_RECOVERY_RUNNER_TRANSPORT: runnerTransport,
          SCOREBUG_RECOVERY_BRIDGE_PORT: String(bridgePort),
        }
      : {}),
    ...(lane === 'network-probe'
      ? { SCOREBUG_PHYSICAL_NETWORK_PROBE: '1' }
      : { SCOREBUG_PHYSICAL_RECOVERY_720: '1' }),
    ...(['quality1080', 'combined1080'].includes(lane)
      ? { SCOREBUG_PHYSICAL_QUALITY_1080: '1' }
      : {}),
    ...(lane === 'combined1080'
      ? {
          SCOREBUG_PHYSICAL_HOUR_4K1080: '1',
          SCOREBUG_PHYSICAL_COMBINED_HOLD_SECONDS: String(holdSeconds),
        }
      : {}),
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
export const configurePhysicalTestRunPython = `import json,plistlib,sys,os
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
   # Camera, archive, live encoder and candidate are the workloads under test.
   # Avoid adding XCTest's continuous screen-video encoder to physical captures.
   v['PreferredScreenCaptureFormat']='screenshots'
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
  const probe = options.lane === 'network-probe';
  const archiveOnly = ['saved-export', 'archive-stop'].includes(options.lane);
  const selectedTest = probe
    ? physicalNetworkProbeTest
    : options.lane === 'saved-export'
      ? physicalSavedExportTest
      : options.lane === 'archive-stop'
        ? physicalArchiveStopTest
        : physicalRecoveryTest;
  const workflowAllowance =
    options.lane === 'saved-export'
      ? 1800
      : options.lane === 'archive-stop'
        ? 420
        : options.lane === 'combined1080'
          ? options.holdSeconds + 2400
          : probe
            ? 120
            : 780;
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
      developerDirectory:
        process.env.DEVELOPER_DIR ?? '/Applications/Xcode-26.2.0.app/Contents/Developer',
    });
  let labArtifact,
    sourceHead,
    failure,
    workflowPassed = false,
    qualification,
    qualificationAttempted = false;
  console.log(
    JSON.stringify({
      artifact,
      scope: archiveOnly
        ? `Physical ${options.lane}; no streaming or match changes`
        : probe
          ? 'Runner network diagnostic; no camera or phase mutations'
          : 'Physical camera recovery; no fixture media qualification',
    }),
  );
  try {
    sourceHead = await run('git', ['rev-parse', 'HEAD'], 'source-head');
    const sdkVersion = (
      await run('xcrun', ['--sdk', 'iphoneos', '--show-sdk-version'], 'sdk-version')
    ).trim();
    const testRunName = physicalTestRunName(sdkVersion);
    await run('xcodegen', ['generate', '--spec', join(root, 'ios/Project.yml')], 'generate');
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
        `id=${options.device}`,
        '-destination-timeout',
        '60',
        '-configuration',
        'Debug',
        '-derivedDataPath',
        derived,
        `DEVELOPMENT_TEAM=${options.team}`,
        '-allowProvisioningUpdates',
        '-allowProvisioningDeviceRegistration',
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
    const inputs = await readPhysicalRecoveryInputs(
      products,
      [
        fileURLToPath(import.meta.url),
        ...[
          'ios/Project.yml',
          'ios/Scorebug.xcodeproj/project.pbxproj',
          'ios/Sources/Scorebug/App.swift',
          'ios/Sources/Scorebug/Debug/RecoveryLoopbackConfiguration.swift',
          'ios/Sources/Scorebug/Debug/RecoveryLoopbackBridge.swift',
          'ios/AppUITests/PhysicalStreamingTests.swift',
          'ios/AppUITests/RecoveryControlConfiguration.swift',
        ].map((name) => join(root, name)),
        ...[
          'device-lab.mjs',
          'ordinary-recovery-control.mjs',
          'udp-impairment.mjs',
          'private-lab-network.mjs',
          'test-ordinary-native-app.mjs',
        ].map((name) => join(root, 'scripts', name)),
      ],
      sdkVersion,
    );
    await writeFile(
      join(artifact, 'inputs.json'),
      JSON.stringify({ sourceHead, device: options.device, inputs }, null, 2),
      { flag: 'wx', mode: 0o600 },
    );
    const startLab = async () => {
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
    };
    const workflow = async (lab) => {
      const environmentPath = join(artifact, 'phone-environment.json'),
        configure = join(artifact, 'configure.py'),
        testRun = join(artifact, 'phone.xctestrun');
      await writeFile(
        environmentPath,
        JSON.stringify(physicalRecoveryEnvironment(lab, options.lane, options)),
        {
          flag: 'wx',
          mode: 0o600,
        },
      );
      await writeFile(configure, configurePhysicalTestRunPython, { flag: 'wx', mode: 0o600 });
      await run(
        'python3',
        [
          configure,
          join(products, testRunName),
          testRun,
          'ScorebugAppUITests',
          environmentPath,
          products,
        ],
        'configure',
      );
      const configuredInputs = await readPhysicalRecoveryInputs(
        products,
        [testRun, environmentPath],
        sdkVersion,
      );
      await writeFile(
        join(artifact, 'configured-inputs.json'),
        JSON.stringify(configuredInputs, null, 2),
        { flag: 'wx', mode: 0o600 },
      );
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
          String(workflowAllowance),
          `-only-testing:${selectedTest}`,
        ],
        'workflow',
        (workflowAllowance + 120) * 1000,
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
      requireOrdinaryTestResult(summary, tests, selectedTest);
      await verifyPhysicalRecoveryInputs(inputs);
      await verifyPhysicalRecoveryInputs(configuredInputs);
    };
    if (archiveOnly) await workflow(null);
    else await withPhysicalRecoveryLab(startLab, workflow);
    workflowPassed = true;
    if (options.lane === 'combined1080' || options.lane === 'archive-stop') {
      qualificationAttempted = true;
      qualification = await collectPhysicalQualification({ artifact, labArtifact, options, run });
    }
  } catch (error) {
    failure = String(error.message);
    qualification = error.qualification ?? qualification;
  } finally {
    if (!qualificationAttempted && options.lane === 'combined1080') {
      qualificationAttempted = true;
      try {
        qualification = await collectPhysicalQualification({ artifact, labArtifact, options, run });
      } catch (error) {
        qualification = error.qualification ?? {
          failure: String(error.message),
          gates: { savedMedia: false },
          sustained1080Qualified: false,
        };
      }
    }
    await writeFile(
      join(artifact, 'result.json'),
      JSON.stringify(
        {
          formatVersion: 1,
          lane: `physical-${options.lane}`,
          holdSeconds: options.holdSeconds,
          recordingID: options.recordingID,
          sourceHead,
          runnerTransport: options.runnerTransport,
          device: options.device,
          host: options.host,
          workflowPassed,
          mediaQualified: qualification?.gates.savedMedia === true,
          qualification,
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
    JSON.stringify({
      artifact,
      workflowPassed,
      mediaQualified: qualification?.gates.savedMedia === true,
      qualification,
      failure,
      cleanupFailures,
    }),
  );
  if (failure || cleanupFailures.length) process.exitCode = 1;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href)
  await main();

async function hashInput(path) {
  const data = await readFile(path);
  return { path, sha256: createHash('sha256').update(data).digest('hex'), bytes: data.length };
}
function physicalTestRunName(sdkVersion) {
  assert(
    typeof sdkVersion === 'string' &&
      /^[1-9][0-9]*\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?$/.test(sdkVersion),
    'Require the selected iPhoneOS SDK version',
  );
  return `Scorebug_iphoneos${sdkVersion}-arm64.xctestrun`;
}
// Preserve callers of the original26.2 helper; this runner always supplies its selected SDK.
export async function readPhysicalRecoveryInputs(products, extraPaths = [], sdkVersion = '26.2') {
  const names = [
    'Debug-iphoneos/Scorebug.app/Scorebug',
    'Debug-iphoneos/Scorebug.app/Scorebug.debug.dylib',
    'Debug-iphoneos/ScorebugAppUITests-Runner.app/ScorebugAppUITests-Runner',
    'Debug-iphoneos/ScorebugAppUITests-Runner.app/PlugIns/ScorebugAppUITests.xctest/ScorebugAppUITests',
    physicalTestRunName(sdkVersion),
  ];
  return Promise.all([...names.map((name) => join(products, name)), ...extraPaths].map(hashInput));
}
export async function verifyPhysicalRecoveryInputs(inputs) {
  for (const input of inputs)
    assert.deepEqual(await hashInput(input.path), input, `Execution input changed: ${input.path}`);
}

async function readJSONAttachments(directory) {
  const reports = [];
  for (const name of await readdir(directory)) {
    if (!name.endsWith('.json') || name === 'manifest.json') continue;
    const path = join(directory, name),
      info = await stat(path);
    assert(info.isFile() && info.size <= 2 * 1024 * 1024, 'Oversized native evidence attachment');
    reports.push(JSON.parse(await readFile(path, 'utf8')));
  }
  return reports;
}
async function collectPhysicalQualification({ artifact, labArtifact, options, run }) {
  const report = {
    gates: {
      nativeHold: false,
      actualInput1080: false,
      resources: false,
      nativeExport: false,
      savedMedia: false,
    },
    sustained1080Qualified: false,
  };
  const attachments = join(artifact, 'attachments');
  await run(
    'xcrun',
    [
      'xcresulttool',
      'export',
      'attachments',
      '--path',
      join(artifact, 'workflow.xcresult'),
      '--output-path',
      attachments,
    ],
    'export-attachments',
    60000,
  );
  const reports = await readJSONAttachments(attachments);
  // Scalar diagnostics are copied before selecting media, including on a failed hold.
  const qa = join(artifact, 'phone-qa'),
    inventoryPath = join(artifact, 'phone-qa-inventory.json');
  await run(
    'xcrun',
    [
      'devicectl',
      'device',
      'info',
      'files',
      '--device',
      options.device,
      '--domain-type',
      'appDataContainer',
      '--domain-identifier',
      'live.scorebug.app',
      '--subdirectory',
      'Library/Application Support/Scorebug/QA',
      '--recurse',
      '--json-output',
      inventoryPath,
      '--timeout',
      '30',
    ],
    'inventory-phone-qa',
    40000,
  );
  const inventory = JSON.parse(await readFile(inventoryPath, 'utf8')).result.files;
  const scalarFiles = inventory.filter(
    (file) =>
      !file.resources.isDirectory &&
      !file.resources.isSymbolicLink &&
      /^[A-Za-z0-9-]+\.json$/.test(file.relativePath),
  );
  assert(
    scalarFiles.length <= 512 &&
      scalarFiles.every(
        (file) => Number.isSafeInteger(file.metadata.size) && file.metadata.size <= 2 * 1024 ** 2,
      ) &&
      scalarFiles.reduce((sum, file) => sum + file.metadata.size, 0) <= 32 * 1024 ** 2,
    'Unbounded phone scalar diagnostics; originals preserved',
  );
  if (scalarFiles.length === inventory.length) {
    await run(
      'xcrun',
      [
        'devicectl',
        'device',
        'copy',
        'from',
        '--device',
        options.device,
        '--domain-type',
        'appDataContainer',
        '--domain-identifier',
        'live.scorebug.app',
        '--source',
        'Library/Application Support/Scorebug/QA',
        '--destination',
        qa,
        '--timeout',
        '60',
      ],
      'collect-phone-qa',
      70000,
    );
  } else {
    await mkdir(qa, { mode: 0o700 });
    for (const [index, file] of scalarFiles.entries())
      await run(
        'xcrun',
        [
          'devicectl',
          'device',
          'copy',
          'from',
          '--device',
          options.device,
          '--domain-type',
          'appDataContainer',
          '--domain-identifier',
          'live.scorebug.app',
          '--source',
          `Library/Application Support/Scorebug/QA/${file.relativePath}`,
          '--destination',
          join(qa, file.relativePath),
          '--timeout',
          '20',
        ],
        `collect-phone-scalar-${index}`,
        30000,
      );
  }
  try {
    const recordingID = physicalRecordingIdentity(reports);
    report.recordingID = recordingID;
    const validationPath = join(qa, `export-validation-${recordingID}.json`);
    const native = requireNativeExportReport(
      JSON.parse(await readFile(validationPath, 'utf8')),
      recordingID,
    );
    report.gates.nativeExport = true;
    if (options.lane === 'combined1080') {
      const shutdown = JSON.parse(await readFile(join(labArtifact, 'shutdown.json'), 'utf8'));
      assert(
        shutdown.workerExit?.code === 0 &&
          shutdown.workerExit.forced === false &&
          shutdown.receiver?.closed === true &&
          shutdown.receiver.finishTimedOut === false &&
          shutdown.failures.length === 0,
        'Backend did not join cleanly',
      );
      const nativeHold = qualifyCombinedNativeEvidence(
        reports.find((r) => r.contract === 'physical-combined4k1080-v1'),
        options.holdSeconds,
      );
      report.nativeHold = nativeHold;
      report.gates.nativeHold = true;
      const workerRows = (await readFile(join(labArtifact, 'worker.log'), 'utf8'))
        .split('\n')
        .filter((line) => line.startsWith('{'))
        .map((line) => JSON.parse(line));
      report.geometry = qualifyCombinedGeometry(workerRows, nativeHold);
      report.gates.actualInput1080 = true;
      const journal = JSON.parse(
        await readFile(join(qa, `quality-transitions-${nativeHold.attemptID}.json`), 'utf8'),
      );
      assert(
        journal.closed === true &&
          journal.overflow === false &&
          journal.attemptID === nativeHold.attemptID,
        'Incomplete transition history',
      );
      report.transitionJournal = journal;
      report.resources = qualifyCombinedResources(
        JSON.parse(await readFile(join(qa, `capture-resources-${recordingID}.json`), 'utf8')),
        recordingID,
        nativeHold,
      );
      report.gates.resources = true;
    }
    const disk = await statfs(artifact);
    assert(
      disk.bavail * disk.bsize >= native.bytes + 2 * 1024 ** 3,
      'Insufficient Mac space for the final MP4 and validation; originals preserved',
    );
    const archive = join(artifact, native.fileName);
    await run(
      'xcrun',
      [
        'devicectl',
        'device',
        'copy',
        'from',
        '--device',
        options.device,
        '--domain-type',
        'appDataContainer',
        '--domain-identifier',
        'live.scorebug.app',
        '--source',
        `Library/Application Support/Scorebug/Recordings/Exports/${native.fileName}`,
        '--destination',
        archive,
        '--timeout',
        '900',
      ],
      'collect-native-export',
      920000,
    );
    assert.equal(
      (await stat(archive)).size,
      native.bytes,
      'Transferred MP4 size differs from native validation',
    );
    report.archive = archive;
    if (options.lane === 'combined1080') {
      const proxyRoot = join(labArtifact, 'proxy-recordings'),
        mockRoot = join(labArtifact, 'reconnecting-recorder');
      const proxies = (await readdir(proxyRoot)).filter((name) => name.startsWith('attempt-'));
      const mocks = (await readdir(mockRoot)).filter((name) => name.startsWith('session-'));
      assert(
        proxies.length === 1 && mocks.length === 1,
        'Qualification requires one finalized proxy and mock session',
      );
      const mediaArtifact = join(artifact, 'saved-media');
      await run(
        'python3',
        [
          join(root, 'scripts/qualify-physical-media.py'),
          '--artifact',
          mediaArtifact,
          '--archive',
          archive,
          '--proxy',
          join(proxyRoot, proxies[0], 'overlay.mp4'),
          '--mock',
          join(mockRoot, mocks[0], 'sink-recordings/direct.mp4'),
          '--native-validation',
          validationPath,
          '--minimum-duration',
          String(options.holdSeconds),
          '--ffprobe',
          mediaTools().ffprobe,
        ],
        'qualify-saved-media',
        5000000,
      );
      report.gates.savedMedia =
        JSON.parse(await readFile(join(mediaArtifact, 'result.json'), 'utf8')).passed === true;
      report.encoded1080HoldQualified = Object.values(report.gates).every(Boolean);
      report.remainingReview = [
        'representative motion and fresh content',
        'visible score phases',
        'perceptual A/V synchronization',
        'clear case, USB charging and intended LAN route',
      ];
    }
  } catch (error) {
    report.failure = String(error.message);
  }
  await writeFile(join(artifact, 'qualification.json'), JSON.stringify(report, null, 2) + '\n', {
    flag: 'wx',
    mode: 0o600,
  });
  return requirePhysicalQualificationResult(report, options.lane);
}
