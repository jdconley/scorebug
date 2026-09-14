import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { cp, mkdir, mkdtemp, readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { mediaTools } from './media-tools.mjs';
import {
  decodeFixtureBarcodes,
  qualifyVideoObservation,
} from './video-observation-qualification.mjs';
import { analyzeMediaSync, assertMediaSync, assertMediaCoverage } from './media-sync.mjs';
import { nativeStreamingFixture } from './native-streaming-fixture.mjs';
import { startScoringTestServer } from './scoring-test-server.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const streaming = process.argv.includes('--streaming');
const runtime = process.env.SCOREBUG_IOS_RUNTIME ?? '17.5';
const deviceType = process.env.SCOREBUG_IOS_DEVICE_TYPE ?? 'iPhone-14';
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/native-app-'));
const { ffmpeg, ffprobe } = mediaTools();
let simulator;
let api;
let proxy;
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
async function analyze(path, index, live = false) {
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
  assert.equal(Number(audio?.sample_rate), live ? 44_100 : 48_000);
  assert.equal(audio?.channels, 1);
  const frames = probe.frames.filter((item) => item.media_type === 'video');
  const pcm = probe.frames.filter((item) => item.media_type === 'audio');
  assert.ok(frames.length >= 60, 'Export must contain at least two seconds of decoded video');
  const times = frames.map((item) => Number(item.best_effort_timestamp_time));
  if (!live) assert.ok(times[0] <= 0.1, 'Source clock origin must not appear as blank lead-in');
  const coverage = assertMediaCoverage({
    videoTimes: times,
    audioStartTime: Number(pcm[0]?.best_effort_timestamp_time),
    audioSampleCount: pcm.reduce((sum, item) => sum + Number(item.nb_samples), 0),
    sampleRate: Number(audio.sample_rate),
    // The worker joins an already-running 2-second GOP. Preserve early audio
    // without inventing video frames while it acquires the first keyframe.
    // Archive coverage and missing-audio/tail budgets remain 100 ms.
    ...(live ? { maxAudioLeadSeconds: 2.1 } : {}),
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
  const codes = [];
  for (let frame = 0; frame < frames.length; frame++) {
    let code = 0;
    for (let bit = 0; bit < 16; bit++) if (bytes[frame * 16 + bit] > 145) code |= 1 << bit;
    codes.push(code);
    if (!live)
      assert.equal(code, frame, `Missing, duplicated, or reordered source frame at ${frame}`);
  }
  let sync, freshFps, sourceLoss, overlayChangedPixels;
  if (streaming) {
    const pcmPath = join(artifact, `audio-${index}.f32`);
    await run(
      ffmpeg,
      [
        '-v',
        'error',
        '-i',
        path,
        '-map',
        '0:a:0',
        '-ac',
        '1',
        '-ar',
        '48000',
        '-f',
        'f32le',
        pcmPath,
      ],
      `audio-${index}`,
    );
    const raw = await readFile(pcmPath);
    const samples = new Float32Array(raw.length / 4);
    for (let i = 0; i < samples.length; i++) samples[i] = raw.readFloatLE(i * 4);
    sync = assertMediaSync(
      analyzeMediaSync({
        codes,
        videoTimes: times,
        audioSamples: samples,
        audioStartTime: Number(pcm[0].best_effort_timestamp_time),
      }),
    );
    freshFps = (codes.length - 1) / (times.at(-1) - times[0]);
    sourceLoss = 1 - codes.length / (codes.at(-1) - codes[0] + 1);
    assert.ok(freshFps >= 24, 'Fresh source cadence fell below 24 fps');
    assert.ok(sourceLoss <= 0.01, 'Source frame loss exceeded one percent');
  }
  if (live) {
    const crops = [];
    for (const [label, position] of [
      ['before', 1],
      ['after', times.at(-1) - times[0] - 2],
    ]) {
      const output = join(artifact, `overlay-${index}-${label}.gray`);
      await run(
        ffmpeg,
        [
          '-v',
          'error',
          '-ss',
          String(position),
          '-i',
          path,
          '-frames:v',
          '1',
          '-vf',
          'crop=750:120:0:930,format=gray',
          '-f',
          'rawvideo',
          output,
        ],
        `overlay-${index}-${label}`,
      );
      crops.push(await readFile(output));
    }
    assert.equal(crops[0].length, 750 * 120);
    assert.equal(crops[0].length, crops[1].length);
    overlayChangedPixels = 0;
    for (let i = 0; i < crops[0].length; i++)
      if (crops[0][i] > 180 !== crops[1][i] > 180) overlayChangedPixels++;
    assert.ok(overlayChangedPixels > 20, 'Native scoring did not change burned-in overlay pixels');
  }
  return {
    file: path,
    sync,
    freshFps,
    sourceLoss,
    overlayChangedPixels,
    frames: frames.length,
    firstSourceFrame: codes[0],
    lastSourceFrame: codes.at(-1),
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
  if (streaming) proxy = await nativeStreamingFixture({ artifact, root, run });
  api = await startScoringTestServer(join(artifact, 'matches.sqlite'), proxy?.environment);
  if (proxy) await proxy.startWorker(api.baseURL);
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
      `-only-testing:ScorebugAppUITests/${streaming ? 'NativeStreamingTests' : 'NativeRecordingTests'}`,
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
  let observationSnapshot;
  if (streaming) {
    const observationPath = join(artifact, 'video-observation.json');
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/video-observation.json'),
      observationPath,
      { errorOnExist: true, force: false },
    );
    observationSnapshot = JSON.parse(await readFile(observationPath, 'utf8'));
  }
  const exports = (await readdir(join(saved, 'Exports'))).filter((name) => name.endsWith('.mp4'));
  assert.ok(exports.length >= (streaming ? 1 : 2), 'Expected completed and recovered MP4 exports');
  const media = [];
  for (const [index, name] of exports.entries())
    media.push(await analyze(join(saved, 'Exports', name), index));
  const live = [];
  if (proxy)
    for (const [index, path] of (await proxy.collect()).entries())
      live.push(await analyze(path, `live-${index}`, true));
  if (streaming) {
    assert.equal(media.length, 1, 'Streaming fixture must export its single clean recording');
    for (const output of live) {
      assert.ok(
        output.firstSourceFrame >= media[0].firstSourceFrame &&
          output.lastSourceFrame <= media[0].lastSourceFrame,
        'Live source frames must belong to the complete local recording',
      );
      assert.ok(
        media[0].lastSourceFrame - output.lastSourceFrame >= 60,
        'Decoded recording must continue for at least two seconds after live video ends',
      );
    }
  }
  const states = [];
  const recordingFolders = [];
  for (const entry of await readdir(saved, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name === 'Exports') continue;
    recordingFolders.push(entry.name);
    states.push(
      JSON.parse(await readFile(join(saved, entry.name, 'recording-status.json'), 'utf8')),
    );
  }
  assert.ok(
    states.some((item) => item.completedAt != null),
    'No finalized recording status',
  );
  if (!streaming)
    assert.ok(
      states.some((item) => item.completedAt == null),
      'No interrupted recording status',
    );
  let videoObservation;
  if (streaming) {
    assert.equal(states.length, 1, 'Observation fixture must own one recording');
    assert.equal(recordingFolders[0], states[0].id, 'Recording folder/status identity mismatch');
    const decodedEvidence = JSON.parse(
      await readFile(join(artifact, 'decoded-video-status.json'), 'utf8'),
    );
    const generations = [...new Set(decodedEvidence.map((item) => item.generation))];
    assert.equal(generations.length, 1, 'Fixture requires one observed publishing generation');
    assert.ok(
      Number.isSafeInteger(generations[0]) && generations[0] > 0,
      'Missing publishing generation evidence',
    );
    // Container is created for this run and its scope must match the owned match,
    // finalized archive and generation actually observed during publishing.
    const archiveIDs = decodeFixtureBarcodes(await readFile(join(artifact, 'frames-0.gray')));
    const liveSegments = await Promise.all(
      live.map(async (_, index) =>
        decodeFixtureBarcodes(await readFile(join(artifact, `frames-live-${index}.gray`))),
      ),
    );
    liveSegments.sort((a, b) => a[0] - b[0]);
    videoObservation = qualifyVideoObservation({
      snapshot: observationSnapshot,
      expectedScope: {
        recordingID: states[0].id,
        matchID: proxy.matchID,
        broadcastGeneration: generations[0],
      },
      archiveIDs,
      liveIDs: liveSegments.flat(),
    });
  }
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
    JSON.stringify(
      { runtime, deviceType, media, live, statuses: states, videoObservation },
      null,
      2,
    ),
  );
  console.log(
    `PASS: native ${streaming ? 'streaming and scoring' : 'offline recording, scoring role, recovery'}, export, and ${media.length + live.length} fully decoded MP4s.`,
  );
} catch (error) {
  if (streaming) {
    await run(
      'xcrun',
      [
        'xcresulttool',
        'export',
        'diagnostics',
        '--path',
        join(artifact, 'workflow.xcresult'),
        '--output-path',
        join(artifact, 'diagnostics'),
      ],
      'diagnostics',
      { cleanup: true },
    ).catch(() => {});
  }
  throw error;
} finally {
  const cleanupErrors = [];
  for (const cleanup of [
    async () => {
      if (proxy) await proxy.stop();
    },
    async () => {
      if (api) await api.stop();
    },
    async () => {
      if (simulator)
        await run('xcrun', ['simctl', 'shutdown', simulator], 'shutdown', { cleanup: true }).catch(
          () => {},
        );
    },
    async () => {
      if (simulator)
        await run('xcrun', ['simctl', 'delete', simulator], 'delete', { cleanup: true });
    },
  ]) {
    try {
      await cleanup();
    } catch (error) {
      cleanupErrors.push(error);
    }
  }
  if (cleanupErrors.length)
    throw new AggregateError(cleanupErrors, 'Owned native validation cleanup failed');
}
