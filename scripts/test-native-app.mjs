import {
  nativeFileFixtureOptions,
  qualifyNativeFileFixture,
  nativeFileFixtureHash,
  stageNativeFileFixture,
  verifyNativeFileFixtureHash,
} from './native-file-fixture.mjs';
import { qualifyNaturalAudio } from './natural-audio-qualification.mjs';
import { qualifyNativeFileRecording } from './native-file-recording.mjs';
import { qualifyScoreTemplate } from './score-template-qualification.mjs';
import { nativeScoreTemplate } from './native-score-template.mjs';
import {
  nativeCandidateProfile,
  qualifyNativeCandidateMeasurement,
} from './native-candidate-measurement.mjs';
import { nativeCandidateHeadroom } from './native-candidate-headroom.mjs';
import { nativeMeasuredTrial } from './native-measured-trial.mjs';
import { nativeMeasuredRecovery, nativeRepeatedRecovery } from './native-measured-recovery.mjs';
import {
  qualifyRepeatedMeasuredNativeRecovery,
  repeatedMeasuredArtifacts,
} from './repeated-measured-native-recovery.mjs';
import { readRepeatedCheckpoint } from './repeated-quality-polling.mjs';
import { measuredTrialArtifacts, qualifyMeasuredNativeTrial } from './measured-native-trial.mjs';
import { qualifyMeasuredNativeRecovery } from './measured-native-recovery.mjs';
import { qualifyCandidateProbeHeadroom } from './candidate-probe-headroom.mjs';
import {
  qualifyNativeDeadlineDecisions,
  qualifyNativeDeadlineReset,
} from './native-deadline-decisions.mjs';
import { qualifyNativeDeliveryDeadlines } from './native-delivery-deadlines.mjs';
import { qualifyNativeStallReset } from './native-stall-reset.mjs';
import { nativeControlledStall, qualifyNativeControlledStall } from './native-controlled-stall.mjs';
import { nativeCadenceReports, qualifyNativeCadenceReports } from './native-cadence-reports.mjs';
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
import { qualifyNativeFormat, parseNativeFormatEvidence } from './native-format-qualification.mjs';
import { validateArchiveDiagnostics } from './archive-diagnostics-validation.mjs';
import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { cp, mkdir, mkdtemp, readdir, readFile, writeFile, lstat } from 'node:fs/promises';
import { join, isAbsolute } from 'node:path';
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
  fixtureDeliveryDeadline,
  fixtureDeadlineResets,
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

async function readBoundedJSON(path, maximum) {
  const bytes = await readFile(path);
  assert.ok(bytes.length <= maximum, `Oversized evidence: ${path}`);
  return JSON.parse(bytes.toString('utf8'));
}

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
const fileFixture = nativeFileFixtureOptions({
  environment: process.env,
  streaming,
  holdSeconds: streamingOptions.holdSeconds,
});
const cadenceReports = nativeCadenceReports({
  environment: process.env,
  streaming,
  requirePublication,
  requireProcessing,
  holdSeconds: streamingOptions.holdSeconds,
});
const decoderStall = nativeControlledStall({ environment: process.env, cadenceReports });
const deadlineResets = fixtureDeadlineResets({ environment: process.env, decoderStall });
const stallReset = decoderStall && process.env.SCOREBUG_TEST_DECODER_STALL === 'reset540';
const qualityFlag = process.env.SCOREBUG_TEST_NATIVE_QUALITY;
const { requireQuality, requireConfirmation } = nativeQualityOptions({
  environment: process.env,
  requireProcessing,
  holdSeconds: streamingOptions.holdSeconds,
});
const fixtureWorkload = fileFixture
  ? 'real-file'
  : nativeFixtureWorkload({ streaming, environment: process.env });
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
const profileTransitionSequence = profileTransitions
  ? process.env.SCOREBUG_TEST_PROFILE_TRANSITIONS
  : undefined;
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
const candidateHeadroom = nativeCandidateHeadroom(process.env);
const candidateProfile = nativeCandidateProfile({
  environment: process.env,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds: streamingOptions.holdSeconds,
  liveProfile,
});
const measuredTrial = nativeMeasuredTrial({
  environment: process.env,
  streaming,
  requireProcessing,
  requirePublication,
  holdSeconds: streamingOptions.holdSeconds,
  liveProfile,
});
const measuredRecovery = nativeMeasuredRecovery({
  environment: process.env,
  measuredTrial,
  holdSeconds: streamingOptions.holdSeconds,
});
const repeatedRecovery = nativeRepeatedRecovery({
  environment: process.env,
  measuredTrial,
  holdSeconds: streamingOptions.holdSeconds,
});
const workerOutputProfile = measuredTrial ? '360p30' : liveProfile;
const deliveryLatencyBudget = fixtureDeliveryDeadline({
  environment: process.env,
  decoderStall,
  measuredTrial,
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
      cadenceReports,
      decoderStall,
      deliveryLatencyBudget,
      deadlineResets,
      stallReset,
      streaming,
      requirePublication,
      requireProcessing,
      requireQuality,
      requireConfirmation,
      streamingOptions,
      fileFixture,
      fixtureWorkload,
      uplinkProfile,
      liveProfile,
      workerOutputProfile,
      measuredTrial,
      measuredRecovery,
      repeatedRecovery,
      profileTransitions,
      profileTransitionSequence,
      adaptiveProfiles,
      streamingBudget,
      directRTMPRecorder: process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER === '1',
      workerPacketTiming: process.env.SCOREBUG_TEST_WORKER_PACKET_TIMING === '1',
    },
    null,
    2,
  ),
);
const { ffmpeg, ffprobe, font } = mediaTools();
let fileInputEvidence, sourcePCM, fileRecordingQualification;
const scoreTemplates = [];
let simulator;
let liveContainer;
const execute = promisify(execFile);
async function readLiveQualityCheckpoint(signal) {
  assert(simulator, 'Owned simulator is not created');
  signal.throwIfAborted();
  if (!liveContainer) {
    const { stdout } = await execute(
      'xcrun',
      ['simctl', 'get_app_container', simulator, 'live.scorebug.app', 'data'],
      { timeout: 3000, maxBuffer: 8192, signal },
    );
    liveContainer = stdout.trim();
    assert(isAbsolute(liveContainer), 'Invalid owned app container');
  }
  const value = await readRepeatedCheckpoint(
    join(liveContainer, 'Library/Application Support/Scorebug/QA/quality-control-live.json'),
  );
  signal.throwIfAborted();
  return value;
}
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
        'stream=codec_type,width,height,sample_rate,channels:frame=media_type,best_effort_timestamp_time,nb_samples,width,height',
        '-of',
        'json',
        path,
      ],
      `probe-${index}`,
    ),
  );
  const video = probe.streams.find((item) => item.codec_type === 'video');
  const audio = probe.streams.find((item) => item.codec_type === 'audio');
  const geometry = nativeMediaGeometry(workerOutputProfile, live);
  assert.equal(video?.width, geometry.width);
  assert.equal(video?.height, geometry.height);
  assert.equal(Number(audio?.sample_rate), live ? 44_100 : 48_000);
  assert.equal(audio?.channels, 1);
  const frames = probe.frames.filter((item) => item.media_type === 'video');
  for (const frame of frames) {
    assert.equal(frame.width, geometry.width, 'Decoded frame width changed');
    assert.equal(frame.height, geometry.height, 'Decoded frame height changed');
  }
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
  let sync,
    freshFps,
    sourceLoss,
    overlayChangedPixels,
    scoreGlyphs,
    videoPayload,
    workloadQualification;
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
        fileFixture ? '8000' : '48000',
        '-f',
        'f32le',
        pcmPath,
      ],
      `audio-${index}`,
    );
    const raw = await readFile(pcmPath);
    const samples = new Float32Array(raw.length / 4);
    for (let i = 0; i < samples.length; i++) samples[i] = raw.readFloatLE(i * 4);
    sync = fileFixture
      ? qualifyNaturalAudio({
          sourceSamples: sourcePCM,
          targetSamples: samples,
          codes,
          videoTimes: times,
          audioStartTime: Number(pcm[0].best_effort_timestamp_time),
          sourceAudioStartTime: fileInputEvidence.audioStartSeconds,
        })
      : assertMediaSync(
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
    if (fileFixture) {
      scoreGlyphs = crops.map((actual, index) =>
        qualifyScoreTemplate({
          actual,
          expected: scoreTemplates[index],
          alternative: scoreTemplates[1 - index],
        }),
      );
    } else {
      overlayChangedPixels = 0;
      for (let i = 0; i < crops[0].length; i++)
        if (crops[0][i] > 180 !== crops[1][i] > 180) overlayChangedPixels++;
      assert.ok(
        overlayChangedPixels > 20,
        'Native scoring did not change burned-in overlay pixels',
      );
    }
  }
  return {
    file: path,
    width: geometry.width,
    height: geometry.height,
    sync,
    freshFps,
    sourceLoss,
    overlayChangedPixels,
    scoreGlyphs,
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
  if (fileFixture) {
    const sha256 = await nativeFileFixtureHash(fileFixture.path);
    const input = join(artifact, 'input.mov');
    await stageNativeFileFixture({ source: fileFixture.path, destination: input, sha256 });
    await run(
      ffmpeg,
      [
        '-nostdin',
        '-v',
        'error',
        '-xerror',
        '-i',
        input,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0',
        '-f',
        'null',
        '-',
      ],
      'file-input-decode',
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
          'stream=codec_type,codec_name,width,height,pix_fmt,color_space,color_transfer,color_primaries,avg_frame_rate,time_base,sample_rate,channels:stream_side_data:frame=media_type,best_effort_timestamp,best_effort_timestamp_time,nb_samples',
          '-of',
          'json',
          input,
        ],
        'file-input-probe',
      ),
    );
    const gray = join(artifact, 'file-input.gray');
    await run(
      ffmpeg,
      [
        '-nostdin',
        '-n',
        '-v',
        'error',
        '-xerror',
        '-i',
        input,
        '-map',
        '0:v:0',
        '-vf',
        'crop=iw:2:0:16,scale=16:1:flags=neighbor,format=gray',
        '-fps_mode',
        'passthrough',
        '-f',
        'rawvideo',
        gray,
      ],
      'file-input-identities',
    );
    fileInputEvidence = {
      ...qualifyNativeFileFixture({
        probe,
        bytes: await readFile(gray),
        minimumDurationSeconds: fileFixture.minimumDurationSeconds,
      }),
      sha256,
    };
    await writeFile(
      join(artifact, 'file-input-qualification.json'),
      JSON.stringify(fileInputEvidence, null, 2),
      { flag: 'wx' },
    );
    const pcm = join(artifact, 'file-input.f32');
    await run(
      ffmpeg,
      [
        '-nostdin',
        '-n',
        '-v',
        'error',
        '-xerror',
        '-i',
        input,
        '-map',
        '0:a:0',
        '-ac',
        '1',
        '-ar',
        '8000',
        '-f',
        'f32le',
        pcm,
      ],
      'file-input-audio',
    );
    const raw = await readFile(pcm);
    assert.equal(raw.length % 4, 0);
    sourcePCM = Float32Array.from({ length: raw.length / 4 }, (_, i) => raw.readFloatLE(i * 4));
    // Render the known fixture score states with the same declared font/geometry.
    // Classification examines differing digit glyphs, not changing background pixels.
    for (const [index, score] of ['0-0', '1-0'].entries()) {
      const path = join(artifact, `score-template-${index}.gray`);
      const template = nativeScoreTemplate({ profile: workerOutputProfile, font, score });
      await run(
        ffmpeg,
        [
          '-nostdin',
          '-n',
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          template.input,
          '-vf',
          template.filter,
          '-frames:v',
          '1',
          '-f',
          'rawvideo',
          path,
        ],
        `score-template-${index}`,
      );
      const pixels = await readFile(path);
      assert.equal(pixels.length, template.byteLength);
      scoreTemplates.push(pixels);
    }
  }
  await run('pnpm', ['--filter', '@scorebug/protocol', 'build'], 'protocol');
  if (streaming)
    proxy = await nativeStreamingFixture({
      requirePublication,
      requireReceiverProbe: bandwidthProbe !== null,
      stagedReceiverProbe: ['staged', 'repeated'].includes(bandwidthProbe),
      candidateHeadroom,
      uplinkProfile,
      liveProfile,
      workerOutputProfile,
      cadenceReports,
      measuredTrial,
      measuredRecovery,
      repeatedRecovery,
      readQualityCheckpoint: repeatedRecovery ? readLiveQualityCheckpoint : undefined,
      decoderStall,
      deadlineResets,
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
  const workflowArguments = [
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
    // Xcode's automatic simctl diagnose can outlive this workflow in a
    // separate process group. Keep bounded logs, attachments and app-data
    // preservation below; collect any additional system diagnostics explicitly.
    '-collect-test-diagnostics',
    'never',
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
    fileFixture ? 'test-without-building' : 'test',
    `-only-testing:ScorebugAppUITests/${streaming ? 'NativeStreamingTests' : 'NativeRecordingTests'}`,
    'CODE_SIGNING_ALLOWED=YES',
    'CODE_SIGN_IDENTITY=-',
    `SCOREBUG_TEST_API_URL=${api.baseURL}`,
    `SCOREBUG_TEST_FILE_CAPTURE=${fileFixture ? '1' : ''}`,
    `SCOREBUG_TEST_STREAM_HOLD_SECONDS=${streamingOptions.extended ? streamingOptions.holdSeconds : ''}`,
    `SCOREBUG_TEST_MOTION_FIXTURE=${fixtureMotionFlag}`,
    `SCOREBUG_TEST_NATIVE_QUALITY=${qualityFlag ?? ''}`,
    `SCOREBUG_TEST_CADENCE_REPORTS=${cadenceReports ? '1' : ''}`,
    `SCOREBUG_TEST_DECODER_STALL=${decoderStall ? process.env.SCOREBUG_TEST_DECODER_STALL : ''}`,
    `SCOREBUG_TEST_DELIVERY_DEADLINE_MS=${process.env.SCOREBUG_TEST_DELIVERY_DEADLINE_MS ?? ''}`,
    `SCOREBUG_TEST_DEADLINE_RESETS=${deadlineResets ? '1' : ''}`,
    `SCOREBUG_TEST_PROFILE_TRANSITIONS=${profileTransitionSequence ?? ''}`,
    `SCOREBUG_TEST_ADAPTIVE_PROFILES=${adaptiveProfiles ? '1' : ''}`,
    `SCOREBUG_TEST_SOURCE_CADENCE_PACING=${sourceCadencePacing ? '1' : ''}`,
    `SCOREBUG_TEST_CANDIDATE_PROFILE=${candidateProfile ?? ''}`,
    `SCOREBUG_TEST_CANDIDATE_HEADROOM=${candidateHeadroom ? '1' : ''}`,
    `SCOREBUG_TEST_MEASURED_TRIAL=${measuredTrial ? '1' : ''}`,
    `SCOREBUG_TEST_DIRECT_RTMP_RECORDER=${process.env.SCOREBUG_TEST_DIRECT_RTMP_RECORDER ?? ''}`,
    `SCOREBUG_TEST_BANDWIDTH_PROBE=${bandwidthProbe ?? ''}`,
    `SCOREBUG_TEST_LIVE_PROFILE=${['540p30', '360p30', '240p30'].includes(liveProfile) ? liveProfile : ''}`,
    `SCOREBUG_TEST_UPLINK_PROXY_PORT=${proxy?.publishingProxyPort ?? ''}`,
  ];
  if (fileFixture) {
    await run('xcrun', ['simctl', 'boot', simulator], 'file-boot');
    await run('xcrun', ['simctl', 'bootstatus', simulator, '-b'], 'file-boot-ready');
    const buildArguments = workflowArguments
      .filter(
        (value, index, all) =>
          value !== '-resultBundlePath' && all[index - 1] !== '-resultBundlePath',
      )
      .map((value) => (value === 'test-without-building' ? 'build-for-testing' : value));
    await run('xcodebuild', buildArguments, 'file-build', {
      timeout: streamingBudget.workflowTimeoutMs,
    });
    await run(
      'xcrun',
      [
        'simctl',
        'install',
        simulator,
        join(root, 'ios/DerivedData/App/Build/Products/Debug-iphonesimulator/Scorebug.app'),
      ],
      'file-install',
    );
    const before = await run(
      'xcrun',
      ['simctl', 'get_app_container', simulator, 'live.scorebug.app', 'data'],
      'file-container-before',
    );
    assert(isAbsolute(before));
    await stageNativeFileFixture({
      source: join(artifact, 'input.mov'),
      destination: join(before, 'Library/Application Support/Scorebug/QA/input.mov'),
      sha256: fileInputEvidence.sha256,
    });
    await writeFile(
      join(artifact, 'file-staging.json'),
      JSON.stringify({ container: before, sha256: fileInputEvidence.sha256 }, null, 2),
      { flag: 'wx' },
    );
  }
  await run('xcodebuild', workflowArguments, 'workflow', {
    timeout: streamingBudget.workflowTimeoutMs,
  });
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
  if (fileFixture) {
    const sha256 = await verifyNativeFileFixtureHash(
      join(container, 'Library/Application Support/Scorebug/QA/input.mov'),
      fileInputEvidence.sha256,
    );
    await writeFile(
      join(artifact, 'file-staging-after.json'),
      JSON.stringify({ container, sha256 }, null, 2),
      { flag: 'wx' },
    );
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/file-source.json'),
      join(artifact, 'file-source.json'),
      { errorOnExist: true, force: false },
    );
  }
  if (repeatedRecovery) {
    // Diagnostic only: preserve it before media/proxy qualification can fail.
    // The existing failure snapshot also retains QA if earlier collection fails.
    const name = 'native-candidate-wait.json';
    const path = join(container, 'Library/Application Support/Scorebug/QA', name);
    try {
      const info = await lstat(path);
      if (info.isFile() && info.size <= 4 * 1024 * 1024)
        await cp(path, join(artifact, name), { errorOnExist: true, force: false });
      else
        console.warn('Candidate wait diagnostic exceeds its file bound or is not a regular file');
    } catch (error) {
      if (error?.code !== 'ENOENT')
        console.warn('Candidate wait diagnostic could not be collected');
    }
  }
  const source = join(container, 'Library/Application Support/Scorebug/Recordings');
  const saved = join(artifact, 'recordings');
  await cp(source, saved, { recursive: true, errorOnExist: true, force: false });
  let observationSnapshot, archiveDiagnosticsSnapshot, qualitySnapshot;
  if (cadenceReports || measuredTrial) {
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/worker-cadence-reports.json'),
      join(artifact, 'worker-cadence-reports.json'),
    );
  }
  if (measuredTrial) {
    for (const name of ['native-profile-transitions.json', 'native-candidate-lifecycle.json']) {
      await cp(
        join(container, 'Library/Application Support/Scorebug/QA', name),
        join(artifact, name),
        { errorOnExist: true, force: false },
      );
    }
  }
  if (decoderStall || measuredTrial) {
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/delivery-deadlines.json'),
      join(artifact, 'delivery-deadlines.json'),
      { errorOnExist: true, force: false },
    );
  }
  if (requireQuality || decoderStall || measuredTrial) {
    const file = join(artifact, 'quality-control.json');
    await cp(join(container, 'Library/Application Support/Scorebug/QA/quality-control.json'), file);
    qualitySnapshot = await readBoundedJSON(file, measuredTrialArtifacts.quality[1]);
  }
  if (streaming) {
    const observationPath = join(artifact, 'video-observation.json');
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/video-observation.json'),
      observationPath,
      { errorOnExist: true, force: false },
    );
    observationSnapshot = await readBoundedJSON(
      observationPath,
      measuredTrialArtifacts.snapshot[1],
    );
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
  if (fileFixture) {
    fileRecordingQualification = qualifyNativeFileRecording({
      recordings: states.map((status, index) => ({ status, folder: recordingFolders[index] })),
      exports,
      archive: archiveDiagnosticsSnapshot,
      file: await readBoundedJSON(join(artifact, 'file-source.json'), 16384),
      videoFrames: media[0].frames,
    });
    await writeFile(
      join(artifact, 'file-recording-qualification.json'),
      JSON.stringify(fileRecordingQualification, null, 2),
      { flag: 'wx' },
    );
  }
  let repeatedRecoveryQualification,
    measuredRecoveryQualification,
    measuredTrialQualification,
    candidateQualification,
    candidateHeadroomQualification,
    nativeVideoCostQualification,
    nativeFormatQualification,
    profileTransitionQualification,
    profileTransitionSnapshot,
    bandwidthProbeQualification,
    receiverProbeQualification,
    nativeReceiverIntervalQualification;
  if (!measuredTrial && !stallReset && ['540p30', '360p30', '240p30'].includes(liveProfile)) {
    const formatPath = join(artifact, 'native-publishing-format.json');
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/native-publishing-format.json'),
      formatPath,
      { errorOnExist: true, force: false },
    );
    const formatBytes = await readFile(formatPath);
    nativeFormatQualification = qualifyNativeFormat(
      parseNativeFormatEvidence(formatBytes),
      observationSnapshot,
      liveProfile,
      { requireStartup: true },
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
      decoderStall || measuredTrial
        ? {
            initialReceipt: qualitySnapshot.events.find((event) => event.kind === 'bootstrap')
              ?.receipt,
          }
        : {},
    );
  }
  if (candidateProfile && !measuredTrial) {
    const candidatePath = join(artifact, 'native-candidate-measurement.json');
    await cp(
      join(container, 'Library/Application Support/Scorebug/QA/native-candidate-measurement.json'),
      candidatePath,
      { errorOnExist: true, force: false },
    );
    const candidateBytes = await readFile(candidatePath);
    assert.ok(candidateBytes.length <= 256 * 1024, 'Oversized candidate evidence');
    candidateQualification = qualifyNativeCandidateMeasurement(
      JSON.parse(candidateBytes.toString('utf8')),
      {
        scope: observationSnapshot.scope,
        profile: candidateProfile,
        liveProfile,
        format: nativeFormatQualification,
        requiredFormatVersion: 3,
      },
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
    let measuredRaw;
    if (measuredTrial) {
      // Fixed-format cost/candidate checks cannot describe an encoder change.
      // Preserve all originals and qualify the explicit measured route instead.
      for (const name of [
        'native-publishing-format.json',
        'native-candidate-measurement.json',
        'native-bandwidth-probe.json',
        'native-receiver-intervals.json',
      ]) {
        await cp(
          join(container, 'Library/Application Support/Scorebug/QA', name),
          join(artifact, name),
          { errorOnExist: true, force: false },
        );
      }
      measuredRaw = {};
      for (const [key, [name, maximum]] of Object.entries(
        repeatedRecovery ? repeatedMeasuredArtifacts : measuredTrialArtifacts,
      ))
        measuredRaw[key] = await readBoundedJSON(join(artifact, name), maximum);
    }
    const decodedEvidence =
      measuredRaw?.decodedEvidence ??
      (await readBoundedJSON(
        join(artifact, 'decoded-video-status.json'),
        measuredTrialArtifacts.decodedEvidence[1],
      ));
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
    if (profileTransitions || adaptiveProfiles || stallReset) {
      const path = join(artifact, 'native-profile-transitions.json');
      await cp(
        join(container, 'Library/Application Support/Scorebug/QA/native-profile-transitions.json'),
        path,
        { errorOnExist: true, force: false },
      );
      const bytes = await readFile(path);
      assert.ok(bytes.length <= 8 * 1024 * 1024, 'Oversized native transition evidence');
      profileTransitionSnapshot = JSON.parse(bytes.toString('utf8'));
      profileTransitionQualification = qualifyNativeProfileTransitions(
        profileTransitionSnapshot,
        observationSnapshot,
        liveSegments.flat(),
        {
          adaptive: adaptiveProfiles,
          sequence: stallReset ? 'stall540' : (profileTransitionSequence ?? '1'),
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
    if (bandwidthProbe && !measuredTrial) {
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
          candidateHeadroom,
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
        { includeIntervalIndexes: candidateHeadroom },
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
      directRecorderDelivery = qualifyDirectRecorderDelivery(
        {
          recorder: JSON.parse(await readFile(join(artifact, 'direct-rtmp-recorder.json'), 'utf8')),
          workerEvidence: JSON.parse(
            await readFile(join(artifact, 'worker-terminal-evidence.json'), 'utf8'),
          ),
          videoObservation,
          live,
        },
        { packetTimingDiagnostics: process.env.SCOREBUG_TEST_WORKER_PACKET_TIMING === '1' },
      );
      directRecorderDelivery.sourceDurationSeconds = qualifyNativeStreamingHold({
        holdSeconds: streamingOptions.holdSeconds,
        savedFrames: directRecorderDelivery.savedFrames,
      });
    }
    if (decoderStall) {
      if (deadlineResets) {
        const result = (stallReset ? qualifyNativeDeadlineReset : qualifyNativeDeadlineDecisions)({
          ...(stallReset
            ? {
                format: profileTransitionSnapshot,
                snapshot: observationSnapshot,
                liveIDs: liveSegments.flat(),
              }
            : {}),
          quality: qualitySnapshot,
          audit: JSON.parse(await readFile(join(artifact, 'delivery-deadlines.json'), 'utf8')),
          reports: JSON.parse(
            await readFile(join(artifact, 'worker-cadence-reports.json'), 'utf8'),
          ),
          fault: JSON.parse(await readFile(join(artifact, 'owned-decoder-stall.json'), 'utf8')),
          scope: observationSnapshot.scope,
        });
        await writeFile(
          join(artifact, 'deadline-decision-qualification.json'),
          JSON.stringify(result, null, 2),
        );
      } else {
        const result = (stallReset ? qualifyNativeStallReset : qualifyNativeControlledStall)({
          ...(stallReset
            ? {
                format: profileTransitionSnapshot,
                snapshot: observationSnapshot,
                liveIDs: liveSegments.flat(),
              }
            : {}),
          quality: qualitySnapshot,
          audit: JSON.parse(await readFile(join(artifact, 'worker-cadence-reports.json'), 'utf8')),
          fault: JSON.parse(await readFile(join(artifact, 'owned-decoder-stall.json'), 'utf8')),
          scope: observationSnapshot.scope,
        });
        await writeFile(
          join(artifact, 'controlled-stall-qualification.json'),
          JSON.stringify(result, null, 2),
        );
      }
      const deadlineResult = qualifyNativeDeliveryDeadlines({
        audit: JSON.parse(await readFile(join(artifact, 'delivery-deadlines.json'), 'utf8')),
        reports: JSON.parse(await readFile(join(artifact, 'worker-cadence-reports.json'), 'utf8')),
        scope: observationSnapshot.scope,
        expectedLatencyBudget: deliveryLatencyBudget,
      });
      assert(deadlineResult.successfulRows >= 20, 'Insufficient native deadline coverage');
      for (const duration of [1, 2]) {
        assert(
          deadlineResult.lanes.some(
            (lane) => lane.duration === duration && lane.successfulRows >= 10,
          ),
          'Missing native deadline lane',
        );
      }
      assert(
        deadlineResult.counts.lateFrames + deadlineResult.counts.missingFrames > 0,
        'Owned decoder pause produced no classified deadline failures',
      );
      if (deliveryLatencyBudget === 1.5) {
        for (const duration of [1, 2]) {
          assert(
            deadlineResult.lanes.some(
              (lane) => lane.duration === duration && lane.observations.healthyRows >= 10,
            ),
            'Insufficient proven healthy baseline in deadline lane',
          );
        }
        assert(
          deadlineResult.observations.below24FPSRows > 0,
          'No fully classified deadline FPS failure',
        );
      }
      await writeFile(
        join(artifact, 'delivery-deadline-qualification.json'),
        JSON.stringify(deadlineResult, null, 2),
      );
    }
    if (cadenceReports) {
      const result = qualifyNativeCadenceReports({
        audit: JSON.parse(await readFile(join(artifact, 'worker-cadence-reports.json'), 'utf8')),
        scope: observationSnapshot.scope,
      });
      await writeFile(
        join(artifact, 'cadence-report-qualification.json'),
        JSON.stringify(result, null, 2),
      );
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
    if (measuredTrial) {
      const measuredInput = {
        ...measuredRaw,
        expectedScope: {
          recordingID: states[0].id,
          matchID: proxy.matchID,
          broadcastGeneration: generations[0],
        },
        archiveIDs,
        liveIDs: liveSegments.flat(),
        completedWindowLimit: streamingOptions.completedWindowLimit,
      };
      const qualification = repeatedRecovery
        ? qualifyRepeatedMeasuredNativeRecovery({
            ...measuredInput,
            faults: await readBoundedJSON(join(artifact, 'owned-decoder-stalls.json'), 512 * 1024),
          })
        : measuredRecovery
          ? qualifyMeasuredNativeRecovery({
              ...measuredInput,
              fault: await readBoundedJSON(join(artifact, 'owned-decoder-stall.json'), 256 * 1024),
            })
          : qualifyMeasuredNativeTrial(measuredInput);
      if (repeatedRecovery) {
        const terminalPath = join(artifact, 'quality-control-live.json');
        await cp(
          join(container, 'Library/Application Support/Scorebug/QA/quality-control-live.json'),
          terminalPath,
          { errorOnExist: true, force: false },
        );
        const terminal = await readBoundedJSON(terminalPath, measuredTrialArtifacts.quality[1]);
        const reconciliation = proxy.reconcileRepeatedQuality(terminal, qualitySnapshot);
        await writeFile(
          join(artifact, 'repeated-live-reconciliation.json'),
          JSON.stringify(reconciliation, null, 2),
          { flag: 'wx' },
        );
        repeatedRecoveryQualification = qualification;
      } else if (measuredRecovery) measuredRecoveryQualification = qualification;
      else measuredTrialQualification = qualification;
      await writeFile(
        join(
          artifact,
          repeatedRecovery
            ? 'repeated-measured-recovery-qualification.json'
            : measuredRecovery
              ? 'measured-recovery-qualification.json'
              : 'measured-trial-qualification.json',
        ),
        JSON.stringify(qualification, null, 2),
        { flag: 'wx' },
      );
    }
    if (candidateHeadroom && !measuredTrial) {
      candidateHeadroomQualification = qualifyCandidateProbeHeadroom({
        candidate: candidateQualification,
        candidateProof: JSON.parse(
          await readFile(join(artifact, 'native-candidate-measurement.json'), 'utf8'),
        ),
        accepted: bandwidthProbeQualification,
        nativeProof: JSON.parse(
          await readFile(join(artifact, 'native-bandwidth-probe.json'), 'utf8'),
        ),
        intervals: JSON.parse(
          await readFile(join(artifact, 'native-receiver-intervals.json'), 'utf8'),
        ),
        intervalQualification: nativeReceiverIntervalQualification,
      });
      await writeFile(
        join(artifact, 'candidate-headroom-qualification.json'),
        JSON.stringify(candidateHeadroomQualification, null, 2),
      );
    }
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
        fileFixture,
        fileInputEvidence,
        fileRecordingQualification,
        streamingOptions,
        fixtureWorkload,
        liveProfile,
        workerOutputProfile,
        measuredTrial,
        measuredRecovery,
        repeatedRecovery,
        measuredTrialQualification,
        measuredRecoveryQualification,
        repeatedRecoveryQualification,
        nativeFormatQualification,
        nativeVideoCostQualification,
        candidateProfile,
        candidateQualification,
        candidateHeadroomQualification,
        profileTransitions,
        profileTransitionSequence,
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
  if (repeatedRecovery)
    assert.equal(repeatedRecoveryQualification?.measuredRepeatedRecoveryQualified, true);
  else if (measuredRecovery)
    assert.equal(measuredRecoveryQualification?.measuredRecoveryQualified, true);
  else if (measuredTrial) assert.equal(measuredTrialQualification?.measuredTrialQualified, true);
  console.log(
    `${repeatedRecovery ? 'REPEATED MEASURED NATIVE RECOVERY PASS (local laboratory route)' : measuredRecovery ? 'MEASURED NATIVE RECOVERY PASS (local laboratory route)' : measuredTrial ? 'MEASURED NATIVE TRIAL PASS (local laboratory route)' : ['rate4m', 'rate3m'].includes(uplinkProfile) || ['540p30', '360p30', '240p30'].includes(liveProfile) || profileTransitions ? 'DIAGNOSTIC MEDIA PASS (native adaptation/recovery not yet qualified)' : 'PASS'}: native ${streaming ? 'streaming and scoring' : 'offline recording, scoring role, recovery'}, export, and ${media.length + live.length} fully decoded MP4s.`,
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
