import assert from 'node:assert/strict';
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
const sourceFPS = Number(process.argv[3] ?? '30');
assert(
  ['software', 'videotoolbox', 'nvenc'].includes(encoder),
  'Choose software, videotoolbox or nvenc',
);
assert(
  ['25', '30', '60'].includes(process.argv[3] ?? '30') && process.argv.length <= 4,
  'Source fps must be 25, 30 or 60',
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
      sourceFPS,
      ffmpeg,
      ffprobe,
      font,
      durationSeconds: 3,
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
await access(font);
const input = join(artifact, 'input.ts'),
  output = join(artifact, 'output.flv'),
  scoreFile = join(artifact, 'score.txt');
await writeFile(scoreFile, 'Home 12 - Away 11');
await run(
  ffmpeg,
  [
    '-hide_banner',
    '-loglevel',
    'error',
    '-f',
    'lavfi',
    '-i',
    `testsrc2=duration=3:size=640x360:rate=${sourceFPS}`,
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=1000:sample_rate=44100:duration=3',
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
const probe = JSON.parse(
  await run(
    ffprobe,
    [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=time_base:frame=pts',
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
assert.equal(sourcePTS.length, sourceFPS * 3);
assert(
  sourcePTS.every((pts, i) => Number.isSafeInteger(pts) && (i === 0 || pts > sourcePTS[i - 1])),
);
let pipeline;
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
  pipeline = startPipeline(
    {
      gameId: 'local-processing-qualification',
      pullUrl: input,
      publishUrl: output,
      scoreFile,
      nvenc: false,
      encoder,
      profile: { width: 640, height: 360, fps: 30, bitrateKbps: 1000 },
      ffmpegPath: ffmpeg,
      fontPath: font,
    },
    createLogger('error'),
    { encoderTiming: true },
  );
  const exit = await deadline(pipeline.waitExit(), 30_000);
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
    sourcePTS,
  );
  const expectedCount = Math.min(sourceFPS, 30) * 3;
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
    expectedCodes,
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
      frameCodeReadFilter,
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
  const codes = decodeFrameCodes(await readFile(raw));
  assert.deepEqual(codes, expectedCodes);
  const interval = workerProcessingInterval(snapshot, encodedPTS[0], encodedPTS.at(-1));
  assert(interval);
  assert.equal(interval.submittedFrames, expectedCount - 1);
  assert.equal(interval.completedFrames, expectedCount - 1);
  assert.equal(interval.pendingFrames, 0);
  assert.equal(interval.decodedFrames, expectedCodes.at(-1) - expectedCodes[0]);
  assert.equal(
    interval.omittedBeforeEncoderFrames,
    expectedCodes.at(-1) - expectedCodes[0] - (expectedCount - 1),
  );
  // Replay raw observations without calling the production duration aggregator.
  const expectedDurations = {};
  for (const [field, timestamp] of [
    ['filterDuration', 'submittedAt'],
    ['processingDuration', 'completedAt'],
  ]) {
    let total = 0,
      maximum = 0,
      known = true;
    for (let i = 1; i < expectedCodes.length; i++) {
      const decodedAt = snapshot.decoded.frames[expectedCodes[i]].observedAt;
      const encodedAt = snapshot.encoded.frames[i][timestamp];
      const elapsed = encodedAt - decodedAt;
      if (encodedAt === null || !Number.isFinite(elapsed) || elapsed < 0) known = false;
      total += elapsed;
      maximum = Math.max(maximum, elapsed);
    }
    expectedDurations[field] = known
      ? { meanMs: total / (expectedCount - 1), maximumMs: maximum }
      : null;
    assert.deepEqual(interval[field], expectedDurations[field]);
  }
  const streams = JSON.parse(
    await run(
      ffprobe,
      ['-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'json', output],
      'output-streams',
    ),
  );
  assert(streams.streams.some((stream) => stream.codec_type === 'audio'));
  const result = {
    encoder,
    sourceFPS,
    sourceFrames: sourcePTS.length,
    outputFrames: codes.length,
    sourcePTS,
    encodedPTS,
    codes,
    interval,
    expectedDurations,
    scope:
      'Finite local fixture. Reader-observed processing timing, not spare capacity, network or sustained-load qualification.',
  };
  await writeFile(join(artifact, 'results.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(
    `PASS ${encoder}: ${sourcePTS.length} decoded source frames; ${codes.length} complete encoded/output identities; ${interval.submittedFrames} matched interval frames; filter timing ${interval.filterDuration ? 'observed' : 'unknown'}, total timing ${interval.processingDuration ? 'observed' : 'unknown'}`,
  );
} finally {
  if (pipeline) {
    pipeline.stop();
    await deadline(pipeline.waitExit(), 10_000);
  }
}
