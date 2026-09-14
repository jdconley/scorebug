import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { cp, mkdir, mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { mediaTools } from './media-tools.mjs';
import { assertMediaCoverage } from './media-sync.mjs';
import { startScoringTestServer } from './scoring-test-server.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const runtime = process.env.SCOREBUG_IOS_RUNTIME ?? '17.5';
const deviceType = process.env.SCOREBUG_IOS_DEVICE_TYPE ?? 'iPhone-14';
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/native-app-'));
const { ffmpeg, ffprobe } = mediaTools();
let simulator;
let api;
let active;
let interrupted = false;
function killActive() {
  if (active?.pid) {
    try {
      process.kill(-active.pid, 'SIGKILL');
    } catch {}
  }
}
for (const signal of ['SIGINT', 'SIGTERM'])
  process.on(signal, () => {
    interrupted = true;
    killActive();
  });
async function run(binary, args, name, { timeout = 120_000, cleanup = false } = {}) {
  if (interrupted && !cleanup) throw new Error('Native app validation interrupted');
  return await new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      cwd: root,
      env: process.env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    active = child;
    let output = '',
      errors = '',
      timedOut = false;
    child.stdout.on('data', (data) => {
      output += data;
    });
    child.stderr.on('data', (data) => {
      errors += data;
    });
    const timer = setTimeout(() => {
      timedOut = true;
      killActive();
    }, timeout);
    child.once('error', (error) => {
      clearTimeout(timer);
      active = undefined;
      reject(error);
    });
    child.once('close', async (code) => {
      clearTimeout(timer);
      active = undefined;
      try {
        await writeFile(join(artifact, `${name}.log`), output + errors);
        if (code !== 0)
          throw new Error(
            `${name} ${timedOut ? 'timed out' : `failed (${code})`}; see ${artifact}/${name}.log`,
          );
        resolve(output.trim());
      } catch (error) {
        reject(error);
      }
    });
  });
}
async function analyze(path, index) {
  await run(
    ffmpeg,
    ['-v', 'error', '-xerror', '-i', path, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'],
    `decode-${index}`,
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
      `probe-${index}`,
    ),
  );
  const video = probe.streams.find((item) => item.codec_type === 'video');
  const audio = probe.streams.find((item) => item.codec_type === 'audio');
  assert.equal(video?.width, 1920);
  assert.equal(video?.height, 1080);
  assert.equal(Number(audio?.sample_rate), 48_000);
  assert.equal(audio?.channels, 1);
  const frames = probe.frames.filter((item) => item.media_type === 'video');
  const pcm = probe.frames.filter((item) => item.media_type === 'audio');
  assert.ok(frames.length >= 60, 'Export must contain at least two seconds of decoded video');
  const times = frames.map((item) => Number(item.best_effort_timestamp_time));
  assert.ok(times[0] <= 0.1, 'Source clock origin must not appear as blank lead-in');
  const coverage = assertMediaCoverage({
    videoTimes: times,
    audioStartTime: Number(pcm[0]?.best_effort_timestamp_time),
    audioSampleCount: pcm.reduce((sum, item) => sum + Number(item.nb_samples), 0),
    sampleRate: 48_000,
  });
  const barcodes = join(artifact, `frames-${index}.gray`);
  await run(
    ffmpeg,
    [
      '-v',
      'error',
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
      barcodes,
    ],
    `barcodes-${index}`,
  );
  const bytes = await readFile(barcodes);
  assert.equal(bytes.length, frames.length * 16);
  for (let frame = 0; frame < frames.length; frame++) {
    let code = 0;
    for (let bit = 0; bit < 16; bit++) if (bytes[frame * 16 + bit] > 145) code |= 1 << bit;
    assert.equal(code, frame, `Missing, duplicated, or reordered source frame at ${frame}`);
  }
  return {
    file: path,
    frames: frames.length,
    firstSourceFrame: 0,
    lastSourceFrame: frames.length - 1,
    coverage,
  };
}
try {
  assert.equal(process.platform, 'darwin');
  console.log(`Native app validation on iOS ${runtime}; evidence: ${artifact}`);
  const runtimes = JSON.parse(
    await run('xcrun', ['simctl', 'list', 'runtimes', '--json'], 'runtimes'),
  );
  const runtimeID = `com.apple.CoreSimulator.SimRuntime.iOS-${runtime.replaceAll('.', '-')}`;
  assert.ok(
    runtimes.runtimes.some((item) => item.identifier === runtimeID && item.isAvailable),
    `iOS ${runtime} runtime unavailable`,
  );
  await run('pnpm', ['--filter', '@scorebug/protocol', 'build'], 'protocol');
  api = await startScoringTestServer(join(artifact, 'matches.sqlite'));
  await run('xcodegen', ['generate', '--spec', 'ios/Project.yml'], 'generate');
  simulator = await run(
    'xcrun',
    [
      'simctl',
      'create',
      `Scorebug Native ${randomUUID()}`,
      `com.apple.CoreSimulator.SimDeviceType.${deviceType}`,
      runtimeID,
    ],
    'create',
  );
  const resultBundle = join(artifact, 'workflow.xcresult');
  await run(
    'xcodebuild',
    [
      '-project',
      'ios/Scorebug.xcodeproj',
      '-scheme',
      'Scorebug',
      '-configuration',
      'Debug',
      '-derivedDataPath',
      'ios/DerivedData/App',
      '-destination',
      `platform=iOS Simulator,id=${simulator}`,
      '-destination-timeout',
      '60',
      '-parallel-testing-enabled',
      'NO',
      '-maximum-concurrent-test-simulator-destinations',
      '1',
      '-resultBundlePath',
      resultBundle,
      'test',
      'CODE_SIGNING_ALLOWED=YES',
      'CODE_SIGN_IDENTITY=-',
      `SCOREBUG_TEST_API_URL=${api.baseURL}`,
    ],
    'workflow',
    { timeout: 600_000 },
  );
  // Xcode may shut its destination down after tests; boot the same owned device
  // to inspect the app container rather than rerunning or losing its recordings.
  const devices = JSON.parse(
    await run('xcrun', ['simctl', 'list', 'devices', '--json'], 'device-state'),
  );
  const destination = Object.values(devices.devices)
    .flat()
    .find((item) => item.udid === simulator);
  assert.ok(destination, 'Owned simulator disappeared after tests');
  if (destination.state === 'Shutdown')
    await run('xcrun', ['simctl', 'boot', simulator], 'boot-for-export');
  await run('xcrun', ['simctl', 'bootstatus', simulator, '-b'], 'ready-for-export');
  const container = await run(
    'xcrun',
    ['simctl', 'get_app_container', simulator, 'live.scorebug.app', 'data'],
    'container',
  );
  const source = join(container, 'Library/Application Support/Scorebug/Recordings');
  const saved = join(artifact, 'recordings');
  await cp(source, saved, { recursive: true, errorOnExist: true, force: false });
  const exports = (await readdir(join(saved, 'Exports'))).filter((name) => name.endsWith('.mp4'));
  assert.ok(exports.length >= 2, 'Expected completed and recovered MP4 exports');
  const media = [];
  for (const [index, name] of exports.entries())
    media.push(await analyze(join(saved, 'Exports', name), index));
  const states = [];
  for (const entry of await readdir(saved, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name === 'Exports') continue;
    states.push(
      JSON.parse(await readFile(join(saved, entry.name, 'recording-status.json'), 'utf8')),
    );
  }
  assert.ok(
    states.some((item) => item.completedAt != null),
    'No finalized recording status',
  );
  assert.ok(
    states.some((item) => item.completedAt == null),
    'No interrupted recording status',
  );
  await mkdir(join(artifact, 'attachments'));
  await run(
    'xcrun',
    [
      'xcresulttool',
      'export',
      'attachments',
      '--path',
      resultBundle,
      '--output-path',
      join(artifact, 'attachments'),
    ],
    'attachments',
  );
  await writeFile(
    join(artifact, 'results.json'),
    JSON.stringify({ runtime, deviceType, media, statuses: states }, null, 2),
  );
  console.log(
    `PASS: native offline recording, scoring role, recovery, export, and ${media.length} fully decoded MP4s.`,
  );
} finally {
  if (api) await api.stop();
  if (simulator) {
    await run('xcrun', ['simctl', 'shutdown', simulator], 'shutdown', { cleanup: true }).catch(
      () => {},
    );
    await run('xcrun', ['simctl', 'delete', simulator], 'delete', { cleanup: true });
  }
}
