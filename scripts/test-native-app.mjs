import { qualifyNativeVideoCost } from './native-video-cost.mjs';
import { qualifyNativeReceiverIntervals } from './native-receiver-intervals.mjs';
import { qualifyReceiverProbeEvidence } from './receiver-probe-evidence.mjs';
import { nativeBandwidthProbe, qualifyNativeBandwidthProbe } from './native-bandwidth-probe.mjs';
import {
  nativeProfileTransitions,
  nativeAdaptiveProfiles,
  qualifyNativeProfileTransitions,
} from './native-profile-transitions.mjs';
import { nativeLiveProfile, nativeMediaGeometry } from './native-live-profile.mjs';
import { qualifyNativeFormat } from './native-format-qualification.mjs';
import { validateArchiveDiagnostics } from './archive-diagnostics-validation.mjs';
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
import { qualifyIngressObservation } from './ingress-observation-qualification.mjs';
import { qualifyPublishingClockObservation } from './publishing-clock-qualification.mjs';
import { qualifyWorkerPublicationEvidence } from './worker-publication-evidence.mjs';
import {
  qualifyNativeUplinkProxy,
  qualifyNativeUplinkSchedule,
} from './native-uplink-qualification.mjs';
import { qualifyNativeQuality } from './native-quality-qualification.mjs';
import { qualifyWorkerProcessingReports } from './worker-processing-qualification.mjs';
import { qualifySourceIntervals } from './source-interval-qualification.mjs';
import { qualifyPublishingAttemptEvidence } from './publishing-attempt-evidence.mjs';
import { qualifyWorkerReportAge } from './worker-report-age-qualification.mjs';
import { analyzeMediaSync, assertMediaSync, assertMediaCoverage } from './media-sync.mjs';
import { nativeStreamingFixture } from './native-streaming-fixture.mjs';
import { startScoringTestServer } from './scoring-test-server.mjs';
import { preserveNativeFailureArtifacts } from './native-failure-artifacts.mjs';
import {
  nativeStreamingOptions,
  fixtureDecoderThreading,
  fixturePublishPeerLatency,
  fixturePublishPacing,
  nativeSourceCadencePacing,
  nativeQualityOptions,
  nativeUplinkOptions,
  nativeFixtureWorkload,
  nativeStreamingTestBudget,
  qualifyNativeStreamingHold,
} from './native-streaming-options.mjs';
import { qualifyDirectRecorderDelivery } from './direct-recorder-qualification.mjs';
import { measureVideoPayloadRate, qualifyStructuredMotionPayload } from './video-payload-rate.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const streaming = process.argv.includes('--streaming');
const decoderThreading = fixtureDecoderThreading(process.env);
const publishPeerLatencyMs = fixturePublishPeerLatency(process.env);
const publishPacing = fixturePublishPacing(process.env);
assert.ok(streaming || publishPacing === undefined, 'Publish pacing experiment requires streaming');
assert.ok(
  streaming || publishPeerLatencyMs === undefined,
  'Publish latency experiment requires streaming',
);
assert.ok(streaming || decoderThreading === 'automatic', 'Decoder experiment requires streaming');
const publicationFlag = process.env.SCOREBUG_TEST_RELAY_PUBLICATION;
assert.ok(
  publicationFlag === undefined || (publicationFlag === '1' && streaming),
  'Publication qualification requires streaming and exact opt-in 1',
);
const requirePublication = publicationFlag === '1';
const processingFlag = process.env.SCOREBUG_TEST_WORKER_PROCESSING;
assert.ok(
  processingFlag === undefined || (processingFlag === '1' && streaming && requirePublication),
  'Processing qualification requires streaming, publication evidence and exact opt-in 1',
);
const requireProcessing = processingFlag === '1';
const streamingOptions = nativeStreamingOptions({ streaming, environment: process.env });
const qualityFlag = process.env.SCOREBUG_TEST_NATIVE_QUALITY;
const { requireQuality, requireConfirmation } = nativeQualityOptions({
  environment: process.env,
  requireProcessing,
  holdSeconds: streamingOptions.holdSeconds,
});
const fixtureWorkload = nativeFixtureWorkload({ streaming, environment: process.env });
const liveProfile = nativeLiveProfile({
  environment: process.env,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds: streamingOptions.holdSeconds,
});
const profileTransitions = nativeProfileTransitions({
  environment: process.env,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds: streamingOptions.holdSeconds,
});
const adaptiveProfiles = nativeAdaptiveProfiles({
  environment: process.env,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds: streamingOptions.holdSeconds,
});
const bandwidthProbe = nativeBandwidthProbe({
  environment: process.env,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds: streamingOptions.holdSeconds,
  liveProfile,
});
const sourceCadencePacing = nativeSourceCadencePacing({
  environment: process.env,
  adaptiveProfiles,
});
const uplinkProfile = nativeUplinkOptions({
  liveProfile,
  environment: process.env,
  streaming,
  requireQuality,
  requireConfirmation,
  requireProcessing,
  requirePublication,
  fixtureWorkload,
  holdSeconds: streamingOptions.holdSeconds,
});
// Keep the exact validated mode through the Xcode/UITest/app boundary.
const fixtureMotionFlag = process.env.SCOREBUG_TEST_MOTION_FIXTURE ?? '';
const streamingBudget = nativeStreamingTestBudget(streamingOptions.holdSeconds);
const decodedWindowLimit = streamingOptions.completedWindowLimit === 128 ? 128 : 64;
const runtime = process.env.SCOREBUG_IOS_RUNTIME ?? '17.5';
const deviceType = process.env.SCOREBUG_IOS_DEVICE_TYPE ?? 'iPhone-14';
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/native-app-'));
await writeFile(
  join(artifact, 'configuration.json'),
  JSON.stringify(
    {
      runtime,
      deviceType,
      decoderThreading,
      publishPeerLatencyMs: publishPeerLatencyMs ?? null,
      publishPacing: publishPacing ?? null,
      sourceCadencePacing,
      streaming,
      requirePublication,
      requireProcessing,
      requireQuality,
      requireConfirmation,
      streamingOptions,
      fixtureWorkload,
      uplinkProfile,
      liveProfile,
      profileTransitions,
      adaptiveProfiles,
      streamingBudget,
      directRTMPRecorder: process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1',
    },
    null,
    2,
  ),
);
const { ffmpeg, ffprobe } = mediaTools();
let simulator;
let api;
let proxy;
let active;
let interrupted = false;
let nativeFailed = false;
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
async function run(
  binary,
  args,
  name,
  { timeout = 120_000, cleanup = false, logOutput = true } = {},
) {
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
        await writeFile(
          join(artifact, `${name}.log`),
          logOutput ? output + errors : `exit=${code}; timedOut=${timedOut}\n`,
        );
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
  const geometry = nativeMediaGeometry(liveProfile, live);
  assert.equal(video?.width, geometry.width);
  assert.equal(video?.height, geometry.height);
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
      `crop=iw:2:0:${geometry.barcodeY},scale=16:1:flags=neighbor,format=gray`,
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
  let sync, freshFps, sourceLoss, overlayChangedPixels, videoPayload, workloadQualification;
  if (streaming) {
    const packetProbe = JSON.parse(
      await run(
        ffprobe,
        [
          '-v',
          'error',
          '-show_streams',
          '-show_packets',
          '-show_entries',
          'stream=index,codec_type,time_base:packet=stream_index,pts,duration,size',
          '-of',
          'json',
          path,
        ],
        `probe-payload-${index}`,
      ),
    );
    videoPayload = measureVideoPayloadRate(packetProbe);
    if (
      fixtureWorkload === 'motion-blocks16' &&
      (!live || (liveProfile === '1080p30' && !profileTransitions && !adaptiveProfiles))
    ) {
      workloadQualification = qualifyStructuredMotionPayload(
        videoPayload,
        live ? 'live' : 'archive',
      );
    }
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
          `format=gray,crop=${geometry.overlay.width}:${geometry.overlay.height}:0:${geometry.overlay.y}`,
          '-f',
          'rawvideo',
          output,
        ],
        `overlay-${index}-${label}`,
      );
      crops.push(await readFile(output));
    }
    assert.equal(crops[0].length, geometry.overlay.width * geometry.overlay.height);
    assert.equal(crops[0].length, crops[1].length);
    overlayChangedPixels = 0;
    for (let i = 0; i < crops[0].length; i++)
      if (crops[0][i] > 180 !== crops[1][i] > 180) overlayChangedPixels++;
    assert.ok(overlayChangedPixels > 20, 'Native scoring did not change burned-in overlay pixels');
  }
  return {
    file: path,
    width: geometry.width,
    height: geometry.height,
    sync,
    freshFps,
    sourceLoss,
    overlayChangedPixels,
    videoPayload,
    workloadQualification,
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
  if (streaming)
    proxy = await nativeStreamingFixture({
      requirePublication,
      requireReceiverProbe: bandwidthProbe !== null,
      uplinkProfile,
      liveProfile,
      decoderThreading,
      publishPeerLatencyMs,
      publishPacing,
      artifact,
      root,
      run,
      decodedWindowLimit,
    });
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
      ...(streamingBudget.testExecutionAllowanceSeconds === null
        ? []
        : [
            '-test-timeouts-enabled',
            'YES',
            '-default-test-execution-time-allowance',
            String(streamingBudget.testExecutionAllowanceSeconds),
            '-maximum-test-execution-time-allowance',
            String(streamingBudget.testExecutionAllowanceSeconds),
          ]),
      'test',
      `-only-testing:ScorebugAppUITests/${streaming ? 'NativeStreamingTests' : 'NativeRecordingTests'}`,
      'CODE_SIGNING_ALLOWED=YES',
      'CODE_SIGN_IDENTITY=-',
      `SCOREBUG_TEST_API_URL=${api.baseURL}`,
      `SCOREBUG_TEST_STREAM_HOLD_SECONDS=${streamingOptions.extended ? streamingOptions.holdSeconds : ''}`,
      `SCOREBUG_TEST_MOTION_FIXTURE=${fixtureMotionFlag}`,
      `SCOREBUG_TEST_NATIVE_QUALITY=${qualityFlag ?? ''}`,
      `SCOREBUG_TEST_PROFILE_TRANSITIONS=${profileTransitions ? '1' : ''}`,
      `SCOREBUG_TEST_ADAPTIVE_PROFILES=${adaptiveProfiles ? '1' : ''}`,
      `SCOREBUG_TEST_SOURCE_CADENCE_PACING=${sourceCadencePacing ? '1' : ''}`,
      `SCOREBUG_TEST_BANDWIDTH_PROBE=${bandwidthProbe ?? ''}`,
      `SCOREBUG_TEST_LIVE_PROFILE=${['540p30', '360p30', '240p30'].includes(liveProfile) ? liveProfile : ''}`,
      `SCOREBUG_TEST_UPLINK_PROXY_PORT=${proxy?.publishingProxyPort ?? ''}`,
    ],
    'workflow',
    { timeout: streamingBudget.workflowTimeoutMs },
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
  let observationSnapshot, archiveDiagnosticsSnapshot, qualitySnapshot;
  if (requireQuality) {
    const file = join(artifact, 'quality-control.json');
    await cp(join(container, 'Library/Application Support/Scorebug/QA/quality-control.json'), file);
    qualitySnapshot = JSON.parse(await readFile(file, 'utf8'));
  }
  if (streaming) {
    const observationPath = join(artifact, 'video-observation.json');
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/video-observation.json'),
      observationPath,
      { errorOnExist: true, force: false },
    );
    observationSnapshot = JSON.parse(await readFile(observationPath, 'utf8'));
    const archiveDiagnosticsPath = join(artifact, 'archive-diagnostics.json');
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/archive-diagnostics.json'),
      archiveDiagnosticsPath,
      { errorOnExist: true, force: false },
    );
    archiveDiagnosticsSnapshot = JSON.parse(await readFile(archiveDiagnosticsPath, 'utf8'));
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
  const uplinkQualification = uplinkProfile
    ? (uplinkProfile === 'passthrough' ? qualifyNativeUplinkProxy : qualifyNativeUplinkSchedule)(
        JSON.parse(await readFile(join(artifact, 'uplink-proxy.json'), 'utf8')),
        uplinkProfile,
      )
    : undefined;
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
  let nativeVideoCostQualification,
    nativeFormatQualification,
    profileTransitionQualification,
    bandwidthProbeQualification,
    receiverProbeQualification,
    nativeReceiverIntervalQualification;
  if (['540p30', '360p30', '240p30'].includes(liveProfile)) {
    const formatPath = join(artifact, 'native-publishing-format.json');
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/native-publishing-format.json'),
      formatPath,
      { errorOnExist: true, force: false },
    );
    const formatBytes = await readFile(formatPath);
    assert.ok(formatBytes.length <= 4096, 'Oversized native format evidence');
    nativeFormatQualification = qualifyNativeFormat(
      JSON.parse(formatBytes.toString('utf8')),
      observationSnapshot,
      liveProfile,
    );
    const costPath = join(artifact, 'native-video-cost.json');
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/native-video-cost.json'),
      costPath,
      { errorOnExist: true, force: false },
    );
    const costBytes = await readFile(costPath);
    assert.ok(costBytes.length <= 2 * 1024 * 1024, 'Oversized native cost evidence');
    nativeVideoCostQualification = qualifyNativeVideoCost(
      JSON.parse(costBytes.toString('utf8')),
      nativeFormatQualification,
    );
  }
  let videoObservation,
    publishingAttemptEvidence,
    workerPublicationEvidence,
    sourceIntervalQualification,
    workerProcessingQualification,
    nativeQualityQualification,
    publishingClockObservation,
    ingressObservation,
    workerReportAge,
    archiveDiagnostics,
    directRecorderDelivery;
  if (streaming) {
    assert.equal(states.length, 1, 'Observation fixture must own one recording');
    assert.equal(recordingFolders[0], states[0].id, 'Recording folder/status identity mismatch');
    archiveDiagnostics = validateArchiveDiagnostics({
      snapshot: archiveDiagnosticsSnapshot,
      recordingID: states[0].id,
    });
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
    if (profileTransitions || adaptiveProfiles) {
      const path = join(artifact, 'native-profile-transitions.json');
      await cp(
        join(container, 'Library/Application Support/Scorebug/QA/native-profile-transitions.json'),
        path,
        { errorOnExist: true, force: false },
      );
      const bytes = await readFile(path);
      assert.ok(bytes.length <= 8 * 1024 * 1024, 'Oversized native transition evidence');
      profileTransitionQualification = qualifyNativeProfileTransitions(
        JSON.parse(bytes.toString('utf8')),
        observationSnapshot,
        liveSegments.flat(),
        {
          adaptive: adaptiveProfiles,
          requireFrameEvidence: true,
          requirePacingEvidence: sourceCadencePacing,
        },
      );
    }
    videoObservation = qualifyVideoObservation({
      snapshot: observationSnapshot,
      expectedScope: {
        recordingID: states[0].id,
        matchID: proxy.matchID,
        broadcastGeneration: generations[0],
      },
      archiveIDs,
      liveIDs: liveSegments.flat(),
      completedWindowLimit: streamingOptions.completedWindowLimit,
    });
    publishingClockObservation = qualifyPublishingClockObservation({
      snapshot: observationSnapshot,
      expectedScope: videoObservation.scope,
    });
    if (bandwidthProbe) {
      const path = join(artifact, 'native-bandwidth-probe.json');
      await cp(
        join(container, 'Library/Application Support/Scorebug/QA/native-bandwidth-probe.json'),
        path,
        { errorOnExist: true, force: false },
      );
      const bytes = await readFile(path);
      assert.ok(bytes.length <= 512 * 1024, 'Oversized native probe evidence');
      bandwidthProbeQualification = qualifyNativeBandwidthProbe(
        JSON.parse(bytes.toString('utf8')),
        {
          mode: bandwidthProbe,
          scope: videoObservation.scope,
          publishingGeneration: publishingClockObservation.publishingGeneration,
        },
      );
      const receiverBytes = await readFile(join(artifact, 'receiver-probe-status.json'));
      assert.ok(receiverBytes.length <= 4 * 1024 * 1024, 'Oversized receiver probe evidence');
      receiverProbeQualification = qualifyReceiverProbeEvidence(
        JSON.parse(receiverBytes.toString('utf8')),
        videoObservation.scope,
        bandwidthProbeQualification,
      );
      const intervalPath = join(artifact, 'native-receiver-intervals.json');
      await cp(
        join(container, 'Library/Application Support/Scorebug/QA/native-receiver-intervals.json'),
        intervalPath,
        { errorOnExist: true, force: false },
      );
      const intervalBytes = await readFile(intervalPath);
      assert.ok(intervalBytes.length <= 1024 * 1024, 'Oversized native receiver interval evidence');
      nativeReceiverIntervalQualification = qualifyNativeReceiverIntervals(
        JSON.parse(intervalBytes.toString('utf8')),
        JSON.parse(receiverBytes.toString('utf8')),
        videoObservation.scope,
        bandwidthProbeQualification,
        JSON.parse(await readFile(join(artifact, 'worker-publication-status.json'), 'utf8')),
        JSON.parse(bytes.toString('utf8')),
      );
    }
    publishingAttemptEvidence = qualifyPublishingAttemptEvidence(
      JSON.parse(await readFile(join(artifact, 'publishing-attempt-status.json'), 'utf8')),
      videoObservation.scope,
    );
    if (requirePublication) {
      workerPublicationEvidence = qualifyWorkerPublicationEvidence(
        JSON.parse(await readFile(join(artifact, 'worker-publication-status.json'), 'utf8')),
        videoObservation.scope,
      );
      sourceIntervalQualification = qualifySourceIntervals({
        snapshot: observationSnapshot,
        videoObservation,
        publishingClockObservation,
        workerPublicationEvidence,
        decodedEvidence,
        archiveIDs,
        liveIDs: liveSegments.flat(),
      });
    }
    if (requireProcessing)
      workerProcessingQualification = qualifyWorkerProcessingReports({
        snapshot: observationSnapshot,
        sourceIntervalQualification,
        processingEvidence: JSON.parse(
          await readFile(join(artifact, 'worker-processing-status.json'), 'utf8'),
        ),
      });
    if (requireQuality)
      nativeQualityQualification = qualifyNativeQuality({
        quality: qualitySnapshot,
        requireConfirmation,
        adaptiveProfiles,
        profileQualification: profileTransitionQualification,
        snapshot: observationSnapshot,
        sourceIntervalQualification,
      });
    ingressObservation = qualifyIngressObservation({
      snapshot: observationSnapshot,
      archive: media[0],
      completedWindowLimit: streamingOptions.completedWindowLimit,
    });
    if (process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1') {
      directRecorderDelivery = qualifyDirectRecorderDelivery({
        recorder: JSON.parse(await readFile(join(artifact, 'direct-rtmp-recorder.json'), 'utf8')),
        workerEvidence: JSON.parse(
          await readFile(join(artifact, 'worker-terminal-evidence.json'), 'utf8'),
        ),
        videoObservation,
        live,
      });
      directRecorderDelivery.sourceDurationSeconds = qualifyNativeStreamingHold({
        holdSeconds: streamingOptions.holdSeconds,
        savedFrames: directRecorderDelivery.savedFrames,
      });
    }
    workerReportAge = qualifyWorkerReportAge({
      snapshot: observationSnapshot,
      decodedEvidence,
      decodedWindowLimit,
    });
    await writeFile(
      join(artifact, 'worker-report-age-qualification.json'),
      JSON.stringify(workerReportAge, null, 2),
    );
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
      {
        runtime,
        deviceType,
        streamingOptions,
        fixtureWorkload,
        liveProfile,
        nativeFormatQualification,
        nativeVideoCostQualification,
        profileTransitions,
        adaptiveProfiles,
        profileTransitionQualification,
        bandwidthProbeQualification,
        receiverProbeQualification,
        nativeReceiverIntervalQualification,
        streamingBudget,
        media,
        live,
        statuses: states,
        videoObservation,
        publishingClockObservation,
        publishingAttemptEvidence,
        workerPublicationEvidence,
        sourceIntervalQualification,
        workerProcessingQualification,
        nativeQualityQualification,
        uplinkQualification,
        ingressObservation,
        workerReportAge,
        archiveDiagnostics,
        directRecorderDelivery,
      },
      null,
      2,
    ),
  );
  console.log(
    `${['rate4m', 'rate3m'].includes(uplinkProfile) || ['540p30', '360p30', '240p30'].includes(liveProfile) || profileTransitions ? 'DIAGNOSTIC MEDIA PASS (native adaptation/recovery not yet qualified)' : 'PASS'}: native ${streaming ? 'streaming and scoring' : 'offline recording, scoring role, recovery'}, export, and ${media.length + live.length} fully decoded MP4s.`,
  );
} catch (error) {
  nativeFailed = true;
  if (simulator) {
    await preserveNativeFailureArtifacts({ simulator, artifact, run }).catch(() => {
      console.warn('Secondary failure: native app evidence preservation could not finish.');
    });
  }
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
  if (cleanupErrors.length) {
    if (nativeFailed)
      console.warn(
        `Secondary failure: ${cleanupErrors.length} owned native validation cleanup steps failed.`,
      );
    else throw new AggregateError(cleanupErrors, 'Owned native validation cleanup failed');
  }
}
