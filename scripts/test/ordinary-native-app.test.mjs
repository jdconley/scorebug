import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { deviceLabAPIBind } from '../device-lab.mjs';
import {
  ordinaryNativeOptions,
  ordinaryLaneConfiguration,
  ordinaryEnvironment,
  runOrdinaryCommand,
  ordinaryTestEnvironment,
  ordinaryTestConfiguration,
  joinOrdinaryWorkflows,
  runOrdinaryWatchDirect,
  issueOrdinaryDirectWatchFixture,
  requireOrdinaryTestResult,
  recoverOrdinaryOwnership,
} from '../test-ordinary-native-app.mjs';
const interfaces = { en0: [{ address: '192.168.1.130', family: 'IPv4', internal: false }] };
test('ordinary upload budget comparison is explicit and restricted to recovery720', () => {
  const base = ['--host', '192.168.1.130', '--source', '/p.mov'];
  assert.deepEqual(
    ordinaryNativeOptions(
      [...base, '--lane', 'recovery720', '--publish-peer-latency-ms', '700'],
      interfaces,
    ),
    {
      host: '192.168.1.130',
      source: '/p.mov',
      encoder: 'software',
      lane: 'recovery720',
      publishPeerLatencyMs: 700,
    },
  );
  for (const lane of [undefined, 'phone', 'paired', 'recovery']) {
    assert.throws(() =>
      ordinaryNativeOptions(
        [...base, ...(lane ? ['--lane', lane] : []), '--publish-peer-latency-ms', '700'],
        interfaces,
      ),
    );
  }
  for (const value of ['119', '2001', '7e2', '0700', '700.1']) {
    assert.throws(() =>
      ordinaryNativeOptions(
        [...base, '--lane', 'recovery720', '--publish-peer-latency-ms', value],
        interfaces,
      ),
    );
  }
});
test('selects the concrete destination config when generic Watch build left a phone-named sibling', () => {
  const files = [
    'Scorebug_iphonesimulator26.2-arm64.xctestrun',
    'ScorebugWatch_watchsimulator26.2-arm64.xctestrun',
    'ScorebugWatch_iphonesimulator26.2-arm64.xctestrun',
  ];
  assert.equal(ordinaryTestConfiguration(files, 'ScorebugWatch', true), files[1]);
  assert.equal(ordinaryTestConfiguration(files, 'Scorebug', false), files[0]);
  assert.throws(() => ordinaryTestConfiguration([files[2]], 'ScorebugWatch', true));
  assert.throws(() =>
    ordinaryTestConfiguration(
      ['ScorebugWatch_watchsimulator26.2-x86_64.xctestrun'],
      'ScorebugWatch',
      true,
    ),
  );
});
for (const interrupted of ['create-phone', 'create-watch', 'pair']) {
  test(`recovers only owned identities after interrupted ${interrupted} returned no UUID`, async () => {
    const calls = [];
    const owner = {
      paired: true,
      phoneName: 'unique-phone',
      watchName: 'unique-watch',
      simulator: interrupted === 'create-phone' ? undefined : 'owned-phone',
      watch: interrupted === 'pair' ? 'owned-watch' : undefined,
    };
    const recovered = await recoverOrdinaryOwnership(owner, async (command, args, label) => {
      calls.push(label);
      assert.equal(command, 'xcrun');
      assert.deepEqual(args.slice(0, 2), ['simctl', 'list']);
      if (args[2] === 'devices')
        return JSON.stringify({
          devices: {
            runtime: [
              { name: 'unrelated', udid: 'other-phone' },
              { name: owner.phoneName, udid: 'owned-phone' },
              ...(interrupted === 'create-phone'
                ? []
                : [{ name: owner.watchName, udid: 'owned-watch' }]),
            ],
          },
        });
      return JSON.stringify({
        pairs: {
          unrelated: { phone: { udid: 'other-phone' }, watch: { udid: 'owned-watch' } },
          owned: { phone: { udid: 'owned-phone' }, watch: { udid: 'owned-watch' } },
        },
      });
    });
    assert.equal(recovered.simulator, 'owned-phone');
    assert.equal(recovered.watch, interrupted === 'create-phone' ? undefined : 'owned-watch');
    assert.equal(recovered.pairId, interrupted === 'create-phone' ? undefined : 'owned');
    assert(calls.length <= 2, 'Recovery must remain bounded');
  });
}
test('failed pair discovery retains recovered device IDs and reports cleanup failure', async () => {
  const recovered = await recoverOrdinaryOwnership(
    { paired: true, phoneName: 'ours-phone', watchName: 'ours-watch' },
    async (_command, args) => {
      if (args[2] === 'pairs') throw new Error('bounded inventory failure');
      return JSON.stringify({
        devices: {
          runtime: [
            { name: 'ours-phone', udid: 'p' },
            { name: 'ours-watch', udid: 'w' },
          ],
        },
      });
    },
  );
  assert.equal(recovered.simulator, 'p');
  assert.equal(recovered.watch, 'w');
  assert.deepEqual(recovered.failures, ['owned pair discovery']);
});
test('paired lane is explicit and cannot alter runtime or timing policy', () => {
  assert.deepEqual(
    ordinaryNativeOptions(
      ['--host', '192.168.1.130', '--source', '/p.mov', '--lane', 'paired'],
      interfaces,
    ),
    { host: '192.168.1.130', source: '/p.mov', encoder: 'software', lane: 'paired' },
  );
  for (const lane of ['physical', 'laboratory', '']) {
    assert.throws(() =>
      ordinaryNativeOptions(
        ['--host', '192.168.1.130', '--source', '/p.mov', '--lane', lane],
        interfaces,
      ),
    );
  }
});
test('Watch private test environment never receives phone credentials or source selectors', () => {
  const setup = {
    endpoint: 'http://192.168.1.130:8080',
    installationToken: 'private-sentinel',
    matchId: '10000000-0000-4000-8000-000000000001',
  };
  assert.deepEqual(ordinaryTestEnvironment({ paired: true, watch: true, setup }), {
    SCOREBUG_PAIRED_ORDINARY_SIMULATOR: '1',
    SCOREBUG_EXPECTED_WATCH_MATCH_ID: setup.matchId,
  });
  for (const matchId of [undefined, '', 'invalid', setup.matchId + ' ']) {
    assert.throws(() =>
      ordinaryTestEnvironment({ paired: true, watch: true, setup: { ...setup, matchId } }),
    );
  }
  const phone = ordinaryTestEnvironment({ paired: true, setup });
  assert.equal(phone.SCOREBUG_DEVICE_TOKEN, setup.installationToken);
  assert.equal(phone.SCOREBUG_ORDINARY_SIMULATOR, '1');
  assert.equal(phone.SCOREBUG_PAIRED_ORDINARY_SIMULATOR, '1');
  assert.throws(() => ordinaryTestEnvironment({ paired: false, watch: true, setup }));
});
test('a failed peer still joins the bounded export workflow before returning', async () => {
  let joined = false;
  await assert.rejects(
    joinOrdinaryWorkflows([
      () => {
        throw new Error('Watch failed');
      },
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 20));
        joined = true;
      },
    ]),
    AggregateError,
  );
  assert.equal(joined, true);
});
test('result qualification rejects skips and a different passing method', () => {
  const summary = {
    result: 'Passed',
    totalTestCount: 1,
    passedTests: 1,
    failedTests: 0,
    skippedTests: 0,
  };
  const expected = 'UITests/Case/testOrdinary';
  const tests = {
    testNodes: [
      {
        children: [
          {
            nodeType: 'Test Case',
            result: 'Passed',
            nodeIdentifierURL: `test://project/${expected}`,
          },
        ],
      },
    ],
  };
  requireOrdinaryTestResult(summary, tests, expected);
  assert.throws(() => requireOrdinaryTestResult({ ...summary, skippedTests: 1 }, tests, expected));
  assert.throws(() => requireOrdinaryTestResult(summary, tests, 'UITests/Case/testOther'));
});
test('cancellation joins both active workflow process groups', async () => {
  const artifact = await mkdtemp(join(tmpdir(), 'scorebug-paired-cancel-'));
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 300);
  try {
    await assert.rejects(
      joinOrdinaryWorkflows(
        ['phone', 'watch'].map(
          (label) => () =>
            runOrdinaryCommand(
              process.execPath,
              ['-e', 'console.log(process.pid);setInterval(()=>{},1000)'],
              { artifact, label, timeout: 2000, grace: 100, signal: controller.signal },
            ),
        ),
      ),
      AggregateError,
    );
    for (const label of ['phone', 'watch']) {
      const pid = Number((await readFile(join(artifact, `${label}.log`), 'utf8')).trim());
      assert(pid > 0);
      assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    }
  } finally {
    clearTimeout(timer);
    await rm(artifact, { recursive: true, force: true });
  }
});
test('requires an explicit assigned private host and absolute prepared source', () => {
  assert.deepEqual(
    ordinaryNativeOptions(['--host', '192.168.1.130', '--source', '/prepared.mov'], interfaces),
    { host: '192.168.1.130', source: '/prepared.mov', encoder: 'software' },
  );
  for (const args of [
    [],
    ['--host', '127.0.0.1', '--source', '/p.mov'],
    ['--host', '192.168.1.131', '--source', '/p.mov'],
    ['--host', '192.168.1.130', '--source', 'p.mov'],
    ['--host', '192.168.1.130', '--source', '/p.mov', '--duration', '900'],
    ['--host', '192.168.1.130', '--source', '/p.mov', '--source', '/q.mov'],
  ]) {
    assert.throws(() => ordinaryNativeOptions(args, interfaces));
  }
});
test('strips all inherited laboratory switches, including Xcode test-child injection', () => {
  const environment = ordinaryEnvironment({
    PATH: '/bin',
    SCOREBUG_TEST_NATIVE_QUALITY: '1',
    SIMCTL_CHILD_SCOREBUG_TEST_VIDEO_OBSERVATIONS: '1',
    TEST_RUNNER_SCOREBUG_TEST_MEASURED_TRIAL: '1',
  });
  assert.equal(environment.PATH, '/bin');
  assert.equal(Object.keys(environment).filter((key) => key.includes('SCOREBUG')).length, 0);
  assert.equal(environment.DEVELOPER_DIR, '/Applications/Xcode-26.2.0.app/Contents/Developer');
});
test('a timed-out command joins its child process group before returning', async () => {
  const artifact = await mkdtemp(join(tmpdir(), 'scorebug-command-'));
  try {
    await assert.rejects(
      runOrdinaryCommand(
        process.execPath,
        [
          '-e',
          `const {spawn}=require('child_process'); const c=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'}); console.log(c.pid); setInterval(()=>{},1000)`,
        ],
        { artifact, label: 'timeout', timeout: 500, grace: 100 },
      ),
      /timed out/,
    );
    const pid = Number((await readFile(join(artifact, 'timeout.log'), 'utf8')).trim());
    assert(pid > 0);
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  } finally {
    await rm(artifact, { recursive: true, force: true });
  }
});

test('recovery is explicit, preserves existing lanes and uses finite outer allowances', () => {
  assert.equal(
    ordinaryNativeOptions(
      ['--host', '192.168.1.130', '--source', '/p.mov', '--lane', 'recovery'],
      interfaces,
    ).lane,
    'recovery',
  );
  assert.deepEqual(ordinaryLaneConfiguration(), {
    paired: false,
    recovery: false,
    phoneTest:
      'ScorebugAppUITests/PhysicalStreamingTests/testOrdinarySimulatorPublishScoreAdaptStopAndExport',
    allowance: 480,
    timeout: 600000,
  });
  assert.equal(ordinaryLaneConfiguration('paired').allowance, 600);
  const recovery = ordinaryLaneConfiguration('recovery');
  assert.equal(
    recovery.phoneTest,
    'ScorebugAppUITests/PhysicalStreamingTests/testOrdinarySimulatorRecoverScoreStopAndExport',
  );
  assert.equal(recovery.allowance, 780);
  assert.equal(recovery.timeout, 900000);
  assert.equal(recovery.paired, false);
});
test('recovery credentials are explicit and restricted to the recovery phone runner', () => {
  const setup = { endpoint: 'http://192.168.1.130:8080', installationToken: 'private' };
  const recoveryControl = {
    endpoint: 'http://127.0.0.1:1234',
    token: 'a'.repeat(64),
    runID: '00000000-0000-4000-8000-000000000001',
  };
  const env = ordinaryTestEnvironment({ paired: false, recovery: true, setup, recoveryControl });
  assert.equal(env.SCOREBUG_RECOVERY_CONTROL_URL, recoveryControl.endpoint);
  assert.equal(env.SCOREBUG_RECOVERY_CONTROL_TOKEN, recoveryControl.token);
  assert.equal(env.SCOREBUG_RECOVERY_RUN_ID, recoveryControl.runID);
  assert.equal(env.SCOREBUG_ORDINARY_RECOVERY, '1');
  assert.equal(env.SCOREBUG_ORDINARY_RECOVERY_720, undefined);
  const higher = ordinaryTestEnvironment({
    paired: false,
    recovery: true,
    recovery720: true,
    setup,
    recoveryControl,
  });
  assert.equal(higher.SCOREBUG_ORDINARY_RECOVERY_720, '1');
  assert.throws(() =>
    ordinaryTestEnvironment({ paired: false, recovery720: true, setup, recoveryControl }),
  );
  assert.equal(
    Object.keys(env).some((k) => k.includes('FILE_CAPTURE')),
    false,
  );
  assert.throws(() => ordinaryTestEnvironment({ paired: false, recovery: true, setup }));
  assert.throws(() =>
    ordinaryTestEnvironment({ paired: true, recovery: true, setup, recoveryControl }),
  );
  assert.throws(() =>
    ordinaryTestEnvironment({
      paired: false,
      recovery: true,
      setup,
      recoveryControl: { ...recoveryControl, endpoint: 'http://example.com' },
    }),
  );
  assert.equal(
    Object.keys(ordinaryTestEnvironment({ paired: false, setup, recoveryControl })).some((k) =>
      k.includes('RECOVERY'),
    ),
    false,
  );
});

test(
  'native guards reject stale samples, pre-mutation acknowledgments, changed ownership and false confirmation',
  { skip: process.platform !== 'darwin' },
  async () => {
    const source = await readFile(
      new URL('../../ios/AppUITests/PhysicalStreamingTests.swift', import.meta.url),
      'utf8',
    );
    const guardSource = source
      .split('// BEGIN RECOVERY GUARDS\n')[1]
      ?.split('// END RECOVERY GUARDS')[0];
    assert(guardSource, 'Native recovery guards must be directly testable');
    const directory = await mkdtemp(join(tmpdir(), 'scorebug-native-guards-'));
    try {
      const path = join(directory, 'main.swift');
      await writeFile(
        path,
        'import Foundation\n' +
          guardSource +
          `
var d: [String:String] = ["sessionObservedAtUptimeSeconds":"100", "observedAtUptimeSeconds":"100", "driverClosed":"false", "sessionClosed":"false", "sessionBusy":"false", "policyAttemptID":"attempt", "policySourceScopeKey":String(repeating:"b",count:64), "policyOwnerKey":String(repeating:"a",count:64), "policyAppliedProfile":"360p30", "policyAppliedBitrate":"600000", "policyAppliedRevision":"1", "policyAcknowledgedAtUptimeSeconds":"95", "policyAcceptedSourceSequence":"4", "policyAcceptedSourceWindowEnd":"99", "policyTrialActive":"true", "policyTrialRollbackRequired":"false", "policyTrialHealthyCoverageSeconds":"5", "policyRecommendationPending":"false", "policyApplicationPending":"false", "policyMinimumResetRequired":"false"]
func sample(_ value: [String:String]) throws -> OrdinaryRecoverySample { try OrdinaryRecoverySample(value, started:100, ended:100.2, previousReadEnd:99) }
let probation = try sample(d)
assert(probation.isProbation)
assert(probation.acknowledges(profile:"360p30", bitrate:600000, after:94, newerThan:0))
assert(!probation.acknowledges(profile:"360p30", bitrate:600000, after:95, newerThan:0))
assert(!probation.acknowledges(profile:"360p30", bitrate:600000, after:94, newerThan:1))
var settled = d; settled["policyTrialActive"]="false"; settled.removeValue(forKey:"policyTrialRollbackRequired"); settled["policyAcceptedSourceSequence"]="5"; settled["policyAcceptedSourceWindowEnd"]="100"
let confirmed = try sample(settled); assert(confirmed.confirms(probation))
assert(probation.acknowledgesNext(profile:"360p30", bitrate:600000, after:94, revision:0))
assert(!probation.acknowledgesNext(profile:"360p30", bitrate:600000, after:94, revision:UInt64.max))
var skipped = d; skipped["policyAppliedRevision"]="3"
let skippedSample = try sample(skipped); assert(!skippedSample.acknowledgesNext(profile:"360p30", bitrate:600000, after:94, revision:0))
for (key,value) in [("policyOwnerKey",String(repeating:"c",count:64)),("policyAppliedRevision","2"),("policyAttemptID","replacement"),("policySourceScopeKey",String(repeating:"c",count:64)),("policyAcceptedSourceSequence","4"),("policyAcceptedSourceWindowEnd","99"),("policyRecommendationPending","true"),("policyApplicationPending","true"),("policyMinimumResetRequired","true"),("policyTrialRollbackRequired","true")] {
 var bad=settled; bad[key]=value; let rejected = try sample(bad); assert(!rejected.confirms(probation),key)
}
let lone = try sample(settled); assert(!lone.confirms(lone))
for (key,value) in [("sessionObservedAtUptimeSeconds","90"),("sessionObservedAtUptimeSeconds","nan"),("sessionObservedAtUptimeSeconds","101"),("policyAcknowledgedAtUptimeSeconds","101"),("policyAcceptedSourceWindowEnd","101"),("sessionClosed","true"),("driverClosed","true"),("observedAtUptimeSeconds","90")] {
 var bad=d; bad[key]=value; do { _=try sample(bad); fatalError(key) } catch {}
}
do { _=try OrdinaryRecoverySample(d,started:100,ended:99,previousReadEnd:98); fatalError("backward bracket") } catch {}
do { _=try OrdinaryRecoverySample(d,started:100,ended:106,previousReadEnd:98); fatalError("slow bracket") } catch {}
do { _=try OrdinaryRecoverySample(d,started:100,ended:100.2,previousReadEnd:101); fatalError("overlapping bracket") } catch {}
do { _=try OrdinaryRecoverySample(d,started:100,ended:100.2,previousReadEnd:99, previousObserved:101); fatalError("backward diagnostic clock") } catch {}
var bootstrap = settled
bootstrap["policyAppliedProfile"]="240p30"; bootstrap["policyAppliedBitrate"]="350000"; bootstrap["policyAppliedRevision"]="0"
for key in ["policyOwnerKey","policySourceScopeKey","policyAcceptedSourceSequence","policyAcceptedSourceWindowEnd"] { bootstrap.removeValue(forKey:key) }
let encoderACK = try sample(bootstrap)
assert(encoderACK.isInitialEncoderACK(after:94))
assert(!encoderACK.isInitialEncoderACK(after:95))
assert(!encoderACK.isInitialSourceReady(matching:encoderACK))
var owned = bootstrap
owned["policyOwnerKey"]=String(repeating:"a",count:64); owned["policySourceScopeKey"]=String(repeating:"b",count:64)
owned["policyAcceptedSourceSequence"]="2"; owned["policyAcceptedSourceWindowEnd"]="99"
let ownedSample = try sample(owned); assert(ownedSample.isInitialSourceReady(matching:encoderACK))
for (key,value) in [("policyAppliedRevision","1"),("policyAppliedProfile","360p30"),("policyAppliedBitrate","600000"),("policyTrialActive","true"),("sessionBusy","true"),("policyTrialRollbackRequired","true")] {
 var bad=bootstrap; bad[key]=value; let rejected=try sample(bad); assert(!rejected.isInitialEncoderACK(after:94),key)
}
for (key,value) in [("policyAppliedRevision","2"),("policyAcknowledgedAtUptimeSeconds","96"),("policyAttemptID","replacement"),("policyTrialActive","true"),("sessionBusy","true"),("policyTrialRollbackRequired","true")] {
 var bad=owned; bad[key]=value; let rejected=try sample(bad); assert(!rejected.isInitialSourceReady(matching:encoderACK),key)
}
print("native guards passed")
`,
      );
      const output = execFileSync('/usr/bin/xcrun', ['swift', path], {
        encoding: 'utf8',
        env: { ...process.env, DEVELOPER_DIR: '/Applications/Xcode-26.2.0.app/Contents/Developer' },
        timeout: 60000,
      });
      assert.match(output, /native guards passed/);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);

test(
  'native archive failure and expired deadline still stop and export only in recovery mode',
  { skip: process.platform !== 'darwin' },
  async () => {
    const source = await readFile(
      new URL('../../ios/AppUITests/PhysicalStreamingTests.swift', import.meta.url),
      'utf8',
    );
    const helper = source.slice(
      source.indexOf('        func preservingRecoveryFailure('),
      source.indexOf('        func adaptiveGate()'),
    );
    const deadlineWait = source
      .slice(
        source.indexOf('    @MainActor private func wait('),
        source.indexOf('    @MainActor private func selectTab('),
      )
      .replace('@MainActor private ', '')
      .replace('until condition:', '_ condition:')
      .replace(
        'Date().addingTimeInterval(seconds)',
        'Date().addingTimeInterval(min(seconds, 0.005))',
      )
      .replace('Date().addingTimeInterval(0.2)', 'Date().addingTimeInterval(0.001)')
      .replace('throw SmokeFailure.failed(message)', 'throw Failure.gate');
    // This harness exercises the existing ordinary/recovery routes. Match the
    // permission policy's two default-false modes without requiring XCTest's
    // application/alert types in the host Swift interpreter.
    assert.match(source, /private var scorerNetworkPermissionOnly = false/);
    assert.match(source, /private var runnerNetworkSettingReadOnly = false/);
    assert.match(
      source,
      /private func enforceScorerPermissionPolicy\(\) throws \{[\s\S]*?guard scorerNetworkPermissionOnly else \{ return \}/,
    );
    const terminal = source
      .split('// BEGIN RECOVERY TERMINATION')[1]
      .split('// END RECOVERY TERMINATION')[0];
    const block = source.slice(
      source.indexOf('        let stoppedAt = elapsed(app)'),
      source.indexOf('        try wait("Recording did not finish saving.'),
    );
    const directory = await mkdtemp(join(tmpdir(), 'scorebug-native-export-'));
    try {
      const path = join(directory, 'main.swift');
      await writeFile(
        path,
        `import Foundation
struct Button { let exists = true }
struct Buttons { subscript(_ key: String) -> Button { Button() } }
struct App { let buttons = Buttons() }
class Harness {
  enum Failure: Error { case gate }
  var events: [String] = []
  var recoveryFailure: String?
  var recoveryRecordingDeadline: Double = 0
  var deadline = Date.distantPast
  var scorerNetworkPermissionOnly = false
  func enforceScorerPermissionPolicy() throws {
    guard scorerNetworkPermissionOnly else { return }
    fatalError("Scorer permission handling is outside this ordinary/recovery harness")
  }
  func elapsed(_ app: App) -> Double { 0 }
${deadlineWait}
  func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.gate } }
  func evidence(_ app: App, phase: String, screenshot: Bool) {}
  func recoveryMilestone(_ phase: String) { events.append(phase) }
  func tap(_ button: Button, in app: App) throws {
    try wait("tap unavailable", seconds: 8) { button.exists }
    events.append("actual-stop")
  }
  func run(recovery: Bool) throws {
    let app = App()
    var adaptiveFailure: Error?
${helper}
${terminal}
    let terminalDeadline = deadline
${block}
    assert(deadline == terminalDeadline)
    try wait("export unavailable", seconds: 35) { true }
    events.append("actual-export")
    if let adaptiveFailure { throw adaptiveFailure }
  }
}
let recovery = Harness()
do { try recovery.run(recovery: true); fatalError("retained failure lost") } catch {}
assert(recovery.events.filter { $0 == "actual-stop" }.count == 2)
assert(recovery.deadline.timeIntervalSinceNow > 0 && recovery.deadline.timeIntervalSinceNow <= 90)
assert(recovery.events.contains("actual-export"))
assert(!recovery.events.contains("archive-continuation-complete"))
assert(recovery.recoveryFailure != nil)
let ordinary = Harness()
do { try ordinary.run(recovery: false); fatalError("ordinary failure lost") } catch {}
assert(ordinary.events.isEmpty)
print("native export failure preservation passed")
`,
      );
      const output = execFileSync('/usr/bin/xcrun', ['swift', path], {
        encoding: 'utf8',
        env: { ...process.env, DEVELOPER_DIR: '/Applications/Xcode-26.2.0.app/Contents/Developer' },
        timeout: 60000,
      });
      assert.match(output, /native export failure preservation passed/);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);

test('recovery720 is explicit and retains ordinary recovery budgets and private controller', () => {
  const config = ordinaryLaneConfiguration('recovery720');
  assert.equal(
    config.phoneTest,
    'ScorebugAppUITests/PhysicalStreamingTests/testOrdinarySimulatorRecover720ScoreStopAndExport',
  );
  assert.equal(config.recovery, true);
  assert.equal(config.recovery720, true);
  assert.equal(config.allowance, 780);
  assert.equal(config.timeout, 900000);
  assert.equal(
    ordinaryNativeOptions(
      ['--host', '192.168.1.130', '--source', '/p.mov', '--lane', 'recovery720'],
      interfaces,
    ).lane,
    'recovery720',
  );
});

test('ordinary publishing pacing is explicit, recovery720-only, and preserves the upload budget', () => {
  const base = ['--host', '192.168.1.130', '--source', '/p.mov'];
  assert.equal(Object.hasOwn(ordinaryNativeOptions(base, interfaces), 'publishPacing'), false);
  for (const latency of [[], ['--publish-peer-latency-ms', '700']]) {
    assert.deepEqual(
      ordinaryNativeOptions(
        [...base, '--lane', 'recovery720', '--publish-pacing', 'relative', ...latency],
        interfaces,
      ),
      {
        host: '192.168.1.130',
        source: '/p.mov',
        encoder: 'software',
        lane: 'recovery720',
        publishPacing: 'relative',
        ...(latency.length ? { publishPeerLatencyMs: 700 } : {}),
      },
    );
  }
  for (const lane of [undefined, 'phone', 'paired', 'recovery']) {
    assert.throws(
      () =>
        ordinaryNativeOptions(
          [...base, ...(lane ? ['--lane', lane] : []), '--publish-pacing', 'relative'],
          interfaces,
        ),
      /requires recovery720/,
    );
  }
});

test('ordinary publishing pacing rejects malformed values and duplicate options', () => {
  const base = ['--host', '192.168.1.130', '--source', '/p.mov', '--lane', 'recovery720'];
  for (const value of [
    '',
    'RELATIVE',
    'Relative',
    ' relative',
    'relative ',
    'relative\n',
    'absolute',
    '0',
    null,
    true,
    1,
    {},
    [],
    ['relative'],
  ]) {
    assert.throws(() => ordinaryNativeOptions([...base, '--publish-pacing', value], interfaces));
  }
  assert.throws(() => ordinaryNativeOptions([...base, '--publish-pacing'], interfaces));
  assert.throws(() =>
    ordinaryNativeOptions(
      [...base, '--publish-pacing', 'relative', '--publish-pacing', 'relative'],
      interfaces,
    ),
  );
});

test('watch-direct is explicit, unpaired, fixture-only setup with no phone credential in Watch environment', () => {
  assert.equal(
    ordinaryNativeOptions(
      ['--host', '192.168.1.130', '--source', '/p.mov', '--lane', 'watch-direct'],
      interfaces,
    ).lane,
    'watch-direct',
  );
  const config = ordinaryLaneConfiguration('watch-direct');
  assert.equal(config.directWatch, true);
  assert.equal(config.paired, false);
  assert.equal(config.recovery, false);
  assert.match(config.phoneTest, /DirectWatch/);
  const setup = {
    endpoint: 'http://192.168.1.130:8080',
    installationToken: 'phone-secret',
    matchId: '10000000-0000-4000-8000-000000000001',
  };
  assert.equal(
    ordinaryTestEnvironment({ paired: false, directWatch: true, setup })
      .SCOREBUG_DIRECT_WATCH_SIMULATOR,
    '1',
  );
  assert.throws(() =>
    ordinaryTestEnvironment({ paired: false, directWatch: true, watch: true, setup }),
  );
  const watchFixture = {
    version: 1,
    endpoint: 'http://127.0.0.1:8080',
    offer: {
      gameId: setup.matchId,
      pairingId: '20000000-0000-4000-8000-000000000001',
      watchDeviceId: '30000000-0000-4000-8000-000000000001',
      role: 'score',
      pairingToken: 'A'.repeat(43),
      expiresAt: '2026-09-27T04:05:00Z',
      serverTime: '2026-09-27T04:00:00Z',
    },
  };
  const env = ordinaryTestEnvironment({
    paired: false,
    directWatch: true,
    watch: true,
    setup,
    watchFixture,
  });
  assert.equal(env.SCOREBUG_DIRECT_WATCH_SIMULATOR, '1');
  assert.equal(env.SCOREBUG_EXPECTED_WATCH_MATCH_ID, setup.matchId);
  assert.deepEqual(JSON.parse(env.SCOREBUG_TEST_WATCH_SETUP), watchFixture);
  assert(!JSON.stringify(env).includes('phone-secret'));
  assert.equal(env.SCOREBUG_PAIRED_ORDINARY_SIMULATOR, undefined);
  assert.throws(() => ordinaryTestEnvironment({ paired: true, directWatch: true, setup }));
  assert.throws(() =>
    ordinaryTestEnvironment({ paired: false, recovery: true, directWatch: true, setup }),
  );
  for (const change of [
    { endpoint: 'http://192.168.1.130:8080' },
    { offer: { ...watchFixture.offer, gameId: 'other' } },
    { offer: { ...watchFixture.offer, role: 'installation' } },
  ])
    assert.throws(() =>
      ordinaryTestEnvironment({
        paired: false,
        directWatch: true,
        watch: true,
        setup,
        watchFixture: { ...watchFixture, ...change },
      }),
    );
});

test('direct Watch starts only after phone readiness and both finite workflows are joined', async () => {
  const events = [];
  await runOrdinaryWatchDirect({
    phone: async (ready) => {
      events.push('phone');
      await Promise.resolve();
      assert.deepEqual(events, ['phone']);
      ready();
      await new Promise((r) => setTimeout(r, 5));
      events.push('phone-stop');
    },
    watch: async () => {
      events.push('watch');
    },
  });
  assert.deepEqual(events, ['phone', 'watch', 'phone-stop']);
  let watchStarted = false;
  await assert.rejects(
    runOrdinaryWatchDirect({
      phone: async () => {
        throw new Error('gate failed');
      },
      watch: async () => {
        watchStarted = true;
      },
    }),
  );
  assert.equal(watchStarted, false);
  await assert.rejects(
    runOrdinaryWatchDirect({
      phone: async () => {},
      watch: async () => {
        watchStarted = true;
      },
    }),
  );
  assert.equal(watchStarted, false);
});

test('direct Watch fixture is real API-issued and bound to fresh identities/current match', async () => {
  const setup = {
    endpoint: 'http://127.0.0.1:8080',
    installationToken: 'phone-secret',
    matchId: '10000000-0000-4000-8000-000000000001',
  };
  const requests = [];
  const fixture = await issueOrdinaryDirectWatchFixture(setup, async (url, options) => {
    requests.push({ url, options });
    const body = JSON.parse(options.body);
    return new Response(
      JSON.stringify({
        ...body,
        gameId: setup.matchId,
        role: 'score',
        pairingToken: 'A'.repeat(43),
        expiresAt: '2026-09-27T04:05:00Z',
        serverTime: '2026-09-27T04:00:00Z',
      }),
      { status: 201 },
    );
  });
  assert.equal(requests.length, 1);
  assert.match(requests[0].url, /watch-pairings$/);
  assert.equal(requests[0].options.headers.authorization, 'Bearer phone-secret');
  assert.equal(fixture.endpoint, 'http://127.0.0.1:8080');
  assert.equal(fixture.offer.gameId, setup.matchId);
  assert(!JSON.stringify(fixture).includes('phone-secret'));
  assert.notEqual(fixture.offer.watchDeviceId, fixture.offer.pairingId);
});

test('direct simulator API binding is exact loopback and never widens existing LAN default', () => {
  assert.equal(deviceLabAPIBind({ host: '192.168.1.130' }), '192.168.1.130');
  assert.equal(deviceLabAPIBind({ host: '192.168.1.130', apiLoopback: true }), '127.0.0.1');
  for (const apiLoopback of [false, '127.0.0.1', '0.0.0.0'])
    assert.throws(() => deviceLabAPIBind({ host: '192.168.1.130', apiLoopback }));
});
