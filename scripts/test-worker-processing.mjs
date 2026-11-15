import { fixtureDecoderThreading } from './native-streaming-options.mjs';
import assert from 'node:assert/strict';
import { assertMediaCoverage } from './media-sync.mjs';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { probeEncoderStatistics } from '../apps/home-daemon/src/encoder-statistics-capability.ts';
import { mkdir, mkdtemp, readFile, writeFile, access } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mediaTools, command } from './media-tools.mjs';
import {
  sourceFrameCodeFilter,
  frameCodeReadFilter,
  decodeFrameCodes,
} from './media-frame-codes.mjs';
import { startPipeline } from '../apps/home-daemon/src/pipeline.ts';
import { encoderTime90k } from '../apps/home-daemon/src/encoder-timing.ts';
import { workerProcessingInterval } from '../apps/home-daemon/src/worker-processing.ts';
import { createLogger } from '../apps/home-daemon/src/logger.ts';

const encoder = process.argv[2] ?? 'software';
const decoderThreading = fixtureDecoderThreading(process.env);
const sourceFPS = Number(process.argv[3] ?? '30');
const paced = process.argv[4] === '--paced';
const aspectTransitions = process.argv[4] === '--transitions-aspect';
const transitions = process.argv[4] === '--transitions' || aspectTransitions;
const durationSeconds = paced ? 24 : 3;
assert(
  ['software', 'videotoolbox', 'nvenc'].includes(encoder),
  'Choose software, videotoolbox or nvenc',
);
assert(
  ['25', '30', '60'].includes(process.argv[3] ?? '30') &&
    process.argv.length <= 5 &&
    (process.argv[4] === undefined || paced || transitions),
  'Source fps must be 25, 30 or 60; optional final flag is --paced, --transitions or --transitions-aspect',
);
assert(
  !transitions || sourceFPS === 60,
  'Transition qualification requires a 60fps source with odd switch indices',
);
const root = fileURLToPath(new URL('..', import.meta.url));
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/worker-processing-'));
const { ffmpeg, ffprobe, font } = mediaTools();
await writeFile(
  join(artifact, 'configuration.json'),
  JSON.stringify(
    {
      encoder,
      decoderThreading,
      sourceFPS,
      ffmpeg,
      ffprobe,
      font,
      durationSeconds,
      paced,
      transitions,
      aspectTransitions,
      profile: { width: 640, height: 360, fps: 30, bitrateKbps: 1000 },
    },
    null,
    2,
  ) + '\n',
);
console.log(`Worker processing qualification: ${artifact}`);
async function run(binary, args, label, timeout = 30_000) {
  const result = await command(binary, args, timeout);
  await writeFile(
    join(artifact, label + '.json'),
    JSON.stringify({ binary, args, ...result }, null, 2) + '\n',
  );
  assert(result.ok, `${label} failed; see saved evidence`);
  return result.stdout;
}
const help = await run(ffmpeg, ['-hide_banner', '-h', 'full'], 'ffmpeg-capabilities');
assert(
  help.includes('-stats_enc_pre') && help.includes('-stats_enc_post'),
  'This FFmpeg build lacks encoder statistics; choose a supported FFMPEG_PATH',
);
await run(ffmpeg, ['-version'], 'ffmpeg-version');
const capability = await probeEncoderStatistics(ffmpeg);
await writeFile(join(artifact, 'capability.json'), JSON.stringify(capability, null, 2) + '\n');
assert.deepEqual(capability, { available: true, reason: 'supported' });
await access(font);
const input = join(artifact, 'input.ts'),
  output = join(artifact, 'output.flv'),
  scoreFile = join(artifact, 'score.txt');
await writeFile(scoreFile, 'Home 12 - Away 11');
if (transitions) {
  // Odd switch indices expose accidental resetting of the 30fps selector anchor.
  const parts = [];
  for (const [index, start, count, width, height] of [
    [0, 0, 61, 640, 360],
    [1, 61, 60, 320, aspectTransitions ? 240 : 180],
    [2, 121, 59, 640, 360],
  ]) {
    const part = join(artifact, `phase-${index}.ts`);
    await run(
      ffmpeg,
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=640x360:rate=60',
        '-frames:v',
        String(count),
        '-vf',
        sourceFrameCodeFilter.replaceAll('N', `(N+${start})`) +
          `,scale=${width}:${height},setsar=1`,
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-bf',
        '0',
        '-g',
        '30',
        '-output_ts_offset',
        String(start / 60),
        '-muxdelay',
        '0',
        '-f',
        'mpegts',
        '-y',
        part,
      ],
      `generate-phase-${index}`,
    );
    parts.push(await readFile(part));
  }
  const video = join(artifact, 'changing-video.ts');
  await writeFile(video, Buffer.concat(parts));
  await run(
    ffmpeg,
    [
      '-hide_banner',
      '-loglevel',
      'warning',
      '-copyts',
      '-i',
      video,
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=1000:sample_rate=44100:duration=3',
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-c:v',
      'copy',
      '-c:a',
      'aac',
      '-shortest',
      '-y',
      input,
    ],
    'mux-changing-source',
  );
} else {
  await run(
    ffmpeg,
    [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      `testsrc2=duration=${durationSeconds}:size=640x360:rate=${sourceFPS}`,
      '-f',
      'lavfi',
      '-i',
      `sine=frequency=1000:sample_rate=44100:duration=${durationSeconds}`,
      '-vf',
      sourceFrameCodeFilter,
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-bf',
      '0',
      '-c:a',
      'aac',
      '-shortest',
      '-y',
      input,
    ],
    'generate',
  );
}
const probe = JSON.parse(
  await run(
    ffprobe,
    [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=time_base:frame=pts,width,height,sample_aspect_ratio',
      '-show_streams',
      '-show_frames',
      '-of',
      'json',
      input,
    ],
    'source-probe',
  ),
);
assert.equal(probe.streams[0].time_base, '1/90000');
const sourcePTS = probe.frames.map((frame) => frame.pts);
assert.equal(sourcePTS.length, sourceFPS * durationSeconds);
assert(
  sourcePTS.every((pts, i) => Number.isSafeInteger(pts) && (i === 0 || pts > sourcePTS[i - 1])),
);
if (transitions) {
  assert(
    probe.frames.every((frame) => frame.sample_aspect_ratio === '1:1'),
    'Fixture pixels must be square so display aspect really changes',
  );
  assert.deepEqual(
    probe.frames.map((f) => [f.width, f.height]),
    Array.from({ length: 180 }, (_, i) =>
      i >= 61 && i < 121 ? [320, aspectTransitions ? 240 : 180] : [640, 360],
    ),
  );
  assert(
    sourcePTS.every((pts, i) => i === 0 || pts - sourcePTS[i - 1] === 1500),
    'Source PTS discontinuity',
  );
}
let pipeline, server, source, sourceExit, sampleTimer;
const samples = [];
let sourceError = '';
let sourceRequests = 0;
async function deadline(promise, ms) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Owned pipeline deadline exceeded')), ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
try {
  let pullUrl = input;
  if (paced) {
    server = createServer((request, response) => {
      if (request.method !== 'GET' || request.url !== '/source.ts' || sourceRequests++ > 0) {
        response.writeHead(404);
        response.end();
        return;
      }
      response.writeHead(200, { 'content-type': 'video/mp2t' });
      source = spawn(
        ffmpeg,
        [
          '-hide_banner',
          '-loglevel',
          'error',
          '-re',
          '-copyts',
          '-i',
          input,
          '-map',
          '0',
          '-c',
          'copy',
          '-mpegts_copyts',
          '1',
          '-f',
          'mpegts',
          'pipe:1',
        ],
        { stdio: ['ignore', 'pipe', 'pipe'], detached: true },
      );
      sourceExit = new Promise((resolve) => {
        source.on('error', () => {
          sourceError = 'source_spawn_failed';
          response.destroy();
        });
        source.once('close', (code, signal) => resolve({ code, signal }));
      });
      source.stderr.on('data', (chunk) => {
        sourceError = (sourceError + chunk.toString()).slice(-4096);
      });
      source.stdout.pipe(response);
      response.on('close', () => {
        if (!response.writableFinished && source.exitCode === null) source.kill('SIGKILL');
      });
    });
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    pullUrl = `http://127.0.0.1:${server.address().port}/source.ts`;
  }
  pipeline = startPipeline(
    {
      gameId: 'local-processing-qualification',
      pullUrl,
      publishUrl: output,
      scoreFile,
      nvenc: false,
      encoder,
      decoderThreading,
      profile: { width: 640, height: 360, fps: 30, bitrateKbps: 1000 },
      ffmpegPath: ffmpeg,
      fontPath: font,
    },
    createLogger('error'),
    { encoderTiming: capability.available },
  );
  if (paced) {
    sampleTimer = setInterval(() => {
      const beforeVideo = pipeline.snapshotDecodedVideo();
      const window = pipeline.snapshotProcessingWindow();
      samples.push({
        observedAt: performance.now(),
        beforeVideo,
        window,
        video: pipeline.snapshotDecodedVideo(),
        snapshot: pipeline.snapshotProcessing(),
      });
    }, 100);
  }
  const exit = await deadline(pipeline.waitExit(), 40_000);
  clearInterval(sampleTimer);
  await writeFile(join(artifact, 'live-samples.json'), JSON.stringify(samples) + '\n');
  if (paced) {
    const sourceResult = await deadline(sourceExit, 5000);
    await writeFile(
      join(artifact, 'source-exit.json'),
      JSON.stringify({ ...sourceResult, sourceError }) + '\n',
    );
    assert.equal(sourceResult.code, 0);
    assert.equal(sourceError, '');
    assert.equal(pipeline.snapshotProcessingWindow(), null, 'closed pipeline has no live window');
  }
  const snapshot = pipeline.snapshotProcessing();
  await writeFile(
    join(artifact, 'processing.json'),
    JSON.stringify({ exit, snapshot }, null, 2) + '\n',
  );
  assert.equal(exit.code, 0);
  assert(snapshot);
  assert.equal(snapshot.decoded.invalidReason, null);
  assert.equal(snapshot.encoded.invalidReason, null);
  assert(snapshot.decoded.ended && snapshot.encoded.ended);
  assert.equal(snapshot.decoded.scopeID, snapshot.encoded.scopeID);
  assert.deepEqual(
    snapshot.decoded.frames.map((frame) => frame.pts),
    sourcePTS.slice(-512),
  );
  const expectedCount = Math.min(sourceFPS, 30) * durationSeconds;
  assert.equal(snapshot.encoded.submittedFrames, expectedCount);
  assert.equal(snapshot.encoded.completedFrames, expectedCount);
  assert.equal(snapshot.encoded.pendingFrames, 0);
  const sourceIndex = new Map(sourcePTS.map((pts, i) => [pts, i]));
  const encodedPTS = snapshot.encoded.frames.map(encoderTime90k);
  assert(encodedPTS.every((pts) => pts !== null && sourceIndex.has(pts)));
  // The regular fixture independently defines which source frames the 30 fps cap keeps.
  const expectedCodes = Array.from({ length: expectedCount }, (_, i) =>
    sourceFPS === 60 ? i * 2 : i,
  );
  assert.deepEqual(
    encodedPTS.map((pts) => sourceIndex.get(pts)),
    expectedCodes.slice(-256),
  );
  const raw = join(artifact, 'codes.gray');
  await run(ffmpeg, ['-v', 'error', '-xerror', '-i', output, '-f', 'null', '-'], 'full-decode');
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-i',
      output,
      '-vf',
      aspectTransitions ? 'crop=iw:2:0:16,format=gray' : frameCodeReadFilter,
      '-fps_mode',
      'passthrough',
      '-pix_fmt',
      'gray',
      '-f',
      'rawvideo',
      '-y',
      raw,
    ],
    'frame-codes',
  );
  let barcodeBytes = await readFile(raw);
  if (aspectTransitions) {
    assert.equal(barcodeBytes.length, expectedCodes.length * 640 * 2);
    const cells = Buffer.alloc(expectedCodes.length * 16);
    expectedCodes.forEach((sourceID, i) => {
      const middle = sourceID >= 61 && sourceID < 121;
      for (let bit = 0; bit < 16; bit++) {
        const x = Math.floor((middle ? 80 : 0) + (bit + 0.5) * (middle ? 15 : 20));
        cells[i * 16 + bit] = barcodeBytes[i * 1280 + x];
      }
      if (middle) {
        assert(
          barcodeBytes[i * 1280 + 5] < 32 && barcodeBytes[i * 1280 + 635] < 32,
          'Changed aspect ratio must remain centered within black bars',
        );
      }
    });
    barcodeBytes = cells;
  }
  const codes = decodeFrameCodes(barcodeBytes);
  assert.deepEqual(codes, expectedCodes);
  let transitionOutput;
  if (transitions) {
    const outputProbe = JSON.parse(
      await run(
        ffprobe,
        [
          '-v',
          'error',
          '-show_streams',
          '-show_frames',
          '-show_entries',
          'stream=codec_type,width,height,sample_rate:frame=media_type,best_effort_timestamp_time,width,height,nb_samples',
          '-of',
          'json',
          output,
        ],
        'transition-output-probe',
      ),
    );
    const video = outputProbe.frames.filter((f) => f.media_type === 'video');
    const audio = outputProbe.frames.filter((f) => f.media_type === 'audio');
    const audioStream = outputProbe.streams.find((s) => s.codec_type === 'audio');
    assert.equal(video.length, expectedCodes.length);
    assert(
      video.every((f) => f.width === 640 && f.height === 360),
      'Worker canvas changed with input size',
    );
    const times = video.map((f) => Number(f.best_effort_timestamp_time));
    const offset = times[0] - sourcePTS[expectedCodes[0]] / 90000;
    assert(
      times.every((t, i) => Math.abs(t - sourcePTS[expectedCodes[i]] / 90000 - offset) <= 0.0011),
      'Resolution change shifted the output source clock',
    );
    transitionOutput = assertMediaCoverage({
      videoTimes: times,
      audioStartTime: Number(audio[0].best_effort_timestamp_time),
      audioSampleCount: audio.reduce((sum, f) => sum + Number(f.nb_samples), 0),
      sampleRate: Number(audioStream.sample_rate),
    });
  }
  const replay = (snapshot, startPTS, endPTS, interval) => {
    const includedCodes = expectedCodes.filter(
      (id) => sourcePTS[id] > startPTS && sourcePTS[id] <= endPTS,
    );
    const startIndex = sourceIndex.get(startPTS),
      endIndex = sourceIndex.get(endPTS);
    assert.notEqual(startIndex, undefined);
    assert.notEqual(endIndex, undefined);
    assert(interval);
    assert.equal(interval.sourceStartExclusive, startPTS);
    assert.equal(interval.sourceEndInclusive, endPTS);
    assert.equal(interval.decodedFrames, endIndex - startIndex);
    assert.equal(interval.submittedFrames, includedCodes.length);
    assert.equal(interval.omittedBeforeEncoderFrames, endIndex - startIndex - includedCodes.length);
    const rawEncoded = new Map(
      snapshot.encoded.frames.map((frame) => [encoderTime90k(frame), frame]),
    );
    const rawDecoded = new Map(
      snapshot.decoded.frames.map((frame) => [frame.pts, frame.observedAt]),
    );
    const frames = includedCodes.map((id) => {
      const frame = rawEncoded.get(sourcePTS[id]);
      assert(frame);
      return frame;
    });
    const completed = frames.filter((frame) => frame.completedAt !== null).length;
    assert.equal(interval.completedFrames, completed);
    assert.equal(interval.pendingFrames, frames.length - completed);
    const expectedDurations = {};
    for (const [field, timestamp] of [
      ['filterDuration', 'submittedAt'],
      ['processingDuration', 'completedAt'],
    ]) {
      let total = 0,
        maximum = 0,
        known = frames.length > 0;
      for (const frame of frames) {
        const decodedAt = rawDecoded.get(encoderTime90k(frame));
        const encodedAt = frame[timestamp];
        const elapsed = encodedAt - decodedAt;
        if (
          decodedAt === undefined ||
          encodedAt === null ||
          !Number.isFinite(elapsed) ||
          elapsed < 0
        )
          known = false;
        total += elapsed;
        maximum = Math.max(maximum, elapsed);
      }
      expectedDurations[field] = known
        ? { meanMs: total / frames.length, maximumMs: maximum }
        : null;
      assert.deepEqual(interval[field], expectedDurations[field]);
    }
    return expectedDurations;
  };
  const interval = workerProcessingInterval(snapshot, encodedPTS[0], encodedPTS.at(-1));
  const expectedDurations = replay(snapshot, encodedPTS[0], encodedPTS.at(-1), interval);
  const liveWindows = new Map();
  const seenDecoderWindows = new Map();
  for (const sample of samples) {
    assert(
      sample.snapshot.decoded.frames.length <= 512 && sample.snapshot.encoded.frames.length <= 256,
    );
    const before = sample.beforeVideo.completed,
      after = sample.video.completed;
    for (const decoded of [before, after]) {
      if (decoded) seenDecoderWindows.set(decoded.sequence, decoded);
    }
    if (!sample.window) continue;
    const window = sample.window;
    assert(
      [before?.sequence, after?.sequence].includes(window.sequence),
      'processing window must still be current',
    );
    assert(!sample.video.ended && !sample.beforeVideo.ended);
    assert.equal(sample.video.invalidReason, null);
    assert.equal(sample.beforeVideo.invalidReason, null);
    for (const history of [sample.snapshot.decoded, sample.snapshot.encoded]) {
      assert(!history.ended);
      assert.equal(history.invalidReason, null);
    }
    const previous = seenDecoderWindows.get(window.previousSequence);
    const current = seenDecoderWindows.get(window.sequence);
    assert(previous && current);
    for (const decoded of [previous, current]) {
      assert(decoded.valid && decoded.freshFrames > 0);
      assert.equal(decoded.duplicateFrames, 0);
      assert.equal(decoded.reorderedFrames, 0);
    }
    assert.equal(window.sequence, window.previousSequence + 1);
    assert.equal(window.scopeID, sample.snapshot.decoded.scopeID);
    assert.equal(window.scopeID, sample.snapshot.encoded.scopeID);
    assert.equal(window.firstPTS, current.firstPTS);
    assert.equal(window.interval.sourceStartExclusive, previous.lastPTS);
    assert.equal(window.interval.sourceEndInclusive, current.lastPTS);
    assert.equal(window.interval.decodedFrames, current.freshFrames);
    // A completed frozen result may outlive raw history. Replay its first complete observation.
    const prior = liveWindows.get(window.sequence);
    if (prior) assert.deepEqual(window, prior);
    else {
      replay(sample.snapshot, previous.lastPTS, current.lastPTS, window.interval);
      if (window.interval.pendingFrames === 0 && window.interval.submittedFrames > 0)
        liveWindows.set(window.sequence, window);
    }
  }
  if (paced) assert(liveWindows.size >= 2, 'At least two complete live windows must qualify');
  const streams = JSON.parse(
    await run(
      ffprobe,
      ['-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'json', output],
      'output-streams',
    ),
  );
  assert(streams.streams.some((stream) => stream.codec_type === 'audio'));
  const result = {
    transitions,
    transitionOutput,
    encoder,
    sourceFPS,
    sourceFrames: sourcePTS.length,
    outputFrames: codes.length,
    sourcePTS,
    encodedPTS,
    codes,
    interval,
    expectedDurations,
    liveWindows: [...liveWindows.values()],
    paced,
    scope:
      'Finite local fixture. Reader-observed processing timing, not spare capacity, network or sustained-load qualification.',
  };
  await writeFile(join(artifact, 'results.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(
    `PASS ${encoder}${paced ? ' paced' : ''}: ${sourcePTS.length} decoded source frames; ${codes.length} complete encoded/output identities; ${interval.submittedFrames} matched interval frames; filter timing ${interval.filterDuration ? 'observed' : 'unknown'}, total timing ${interval.processingDuration ? 'observed' : 'unknown'}`,
  );
} finally {
  clearInterval(sampleTimer);
  const joins = [];
  if (server) {
    server.closeAllConnections();
    joins.push(new Promise((resolve) => server.close(resolve)));
  }
  if (source) {
    if (source.pid !== undefined) {
      try {
        process.kill(-source.pid, 'SIGKILL');
      } catch {
        /* Owned group already exited. */
      }
    }
    source.kill('SIGKILL');
    joins.push(deadline(sourceExit, 5000));
  }
  if (pipeline) {
    pipeline.stop();
    joins.push(deadline(pipeline.waitExit(), 10_000));
  }
  const results = await Promise.allSettled(joins);
  const failure = results.find((result) => result.status === 'rejected');
  if (failure) throw failure.reason;
}
