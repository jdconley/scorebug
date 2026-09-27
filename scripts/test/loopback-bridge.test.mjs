import test from 'node:test';
import {mkdtemp, mkdir, copyFile, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
test('Debug loopback bridge Swift configuration, HTTP parser and real listener lifecycle', {skip: process.platform !== 'darwin'}, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'scorebug-loopback-tests-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  await mkdir(join(dir, 'Sources/RecoveryBridge'), {recursive:true});
  await mkdir(join(dir, 'Tests/RecoveryBridgeTests'), {recursive:true});
  for (const name of ['RecoveryLoopbackConfiguration.swift', 'RecoveryLoopbackBridge.swift'])
    await copyFile(new URL(`../../ios/Sources/Scorebug/Debug/${name}`, import.meta.url), join(dir, 'Sources/RecoveryBridge', name));
  await copyFile(new URL('../../ios/AppUITests/RecoveryControlConfiguration.swift', import.meta.url), join(dir, 'Sources/RecoveryBridge/RecoveryControlConfiguration.swift'));
  await writeFile(join(dir, 'Tests/RecoveryBridgeTests/ConfigurationTests.swift'), '@testable import RecoveryBridge\n' + await readFile(new URL('../../ios/FilmModelTests/RecoveryControlConfigurationTests.swift', import.meta.url), 'utf8'));
  await copyFile(new URL('../../ios/LoopbackBridgeTests/RecoveryLoopbackBridgeTests.swift', import.meta.url), join(dir, 'Tests/RecoveryBridgeTests/Tests.swift'));
  await writeFile(join(dir, 'Package.swift'), `// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "RecoveryBridge", platforms: [.macOS(.v14)], targets: [.target(name: "RecoveryBridge"), .testTarget(name: "RecoveryBridgeTests", dependencies: ["RecoveryBridge"])])
`);
  try { console.log(execFileSync('swift', ['test', '--package-path', dir], {encoding:'utf8', timeout:120000})); }
  catch (error) { throw new Error(`${error.stdout}\n${error.stderr}`); }
});
