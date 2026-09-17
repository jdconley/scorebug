import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { createSocket } from 'node:dgram';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startPipeline } from '../apps/home-daemon/src/pipeline.ts';
import { mediaTools } from './media-tools.mjs';
const root = fileURLToPath(new URL('..', import.meta.url));
const artifact = await mkdtemp(join(root, 'artifacts/qa/decoder-cadence-native-'));
const { ffmpeg, ffprobe, font } = mediaTools();
const execute = promisify(execFile);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const sourcePath = join(artifact, 'source.ts'),
  outputPath = join(artifact, 'output.flv');
await writeFile(join(artifact, 'score.txt'), 'Home 0 - 0 Away');
console.log(`Decoder cadence evidence: ${artifact}`);
await execute(
  ffmpeg,
  [
    '-v',
    'error',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=320x180:rate=30',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=1000:sample_rate=48000',
    '-t',
    '16',
    '-c:v',
    'libx264',
    '-preset',
    'ultrafast',
    '-tune',
    'zerolatency',
    '-g',
    '30',
    '-bf',
    '0',
    '-c:a',
    'aac',
    '-f',
    'mpegts',
    sourcePath,
  ],
  { timeout: 30000, maxBuffer: 1024 * 1024 },
);
const socket = createSocket('udp4');
await new Promise((resolve) => socket.bind(0, '127.0.0.1', resolve));
const port = socket.address().port;
await new Promise((resolve) => socket.close(resolve));
const events = [],
  samples = [];
let terminal,
  pipeline,
  source,
  sourceExit,
  sourceDone = false,
  timer,
  paused = false;
const log = Object.fromEntries(
  ['debug', 'info', 'warn', 'error'].map((level) => [
    level,
    (message, fields) => events.push({ level, message, ...fields }),
  ]),
);
const sample = () => {
  const before = performance.now(),
    snapshot = pipeline.snapshotDecoderCadence();
  assert.ok(samples.length < 1000, 'Bounded cadence fixture exceeded sample budget');
  samples.push({ before, after: performance.now(), snapshot });
  return snapshot;
};
const waitFor = async (predicate) => {
  const until = performance.now() + 12000;
  while (!predicate()) {
    assert.ok(performance.now() < until, 'Cadence condition timed out');
    await sleep(25);
  }
};
try {
  pipeline = startPipeline(
    {
      gameId: 'decoder-cadence',
      pullUrl: `udp://127.0.0.1:${port}?fifo_size=100000&overrun_nonfatal=0&timeout=3000000`,
      publishUrl: outputPath,
      scoreFile: join(artifact, 'score.txt'),
      nvenc: false,
      encoder: 'software',
      decoderThreading: 'slice',
      profile: { width: 320, height: 180, fps: 30, bitrateKbps: 500 },
      ffmpegPath: ffmpeg,
      fontPath: font,
    },
    log,
    {
      encoderTiming: true,
      onTerminal: (value) => {
        terminal = value;
      },
    },
  );
  timer = setInterval(sample, 50);
  await sleep(250);
  source = spawn(
    ffmpeg,
    [
      '-v',
      'error',
      '-re',
      '-i',
      sourcePath,
      '-c',
      'copy',
      '-f',
      'mpegts',
      `udp://127.0.0.1:${port}?pkt_size=1316`,
    ],
    { stdio: ['ignore', 'ignore', 'pipe'] },
  );
  let stderr = '';
  source.stderr.on('data', (chunk) => {
    if (stderr.length < 65536) stderr += chunk.toString();
  });
  sourceExit = new Promise((resolve) => {
    source.once('error', () => {});
    source.once('close', (code, signal) => {
      sourceDone = true;
      resolve({ code, signal, stderr });
    });
  });
  await waitFor(() => sample().oneSecond?.freshFrames >= 24);
  await sleep(2200);
  const pauseAt = performance.now();
  assert.ok(source.kill('SIGSTOP'));
  paused = true;
  await waitFor(() => sample().progress?.stalled === true);
  const stalledAt = performance.now();
  await sleep(200);
  assert.ok(source.kill('SIGCONT'));
  paused = false;
  const resumeAt = performance.now();
  await waitFor(() => sample().progress?.stalled === false);
  const resumedAt = performance.now();
  await waitFor(() => sourceDone);
  const sourceResult = await sourceExit;
  assert.equal(sourceResult.code, 0);
  assert.equal(sourceResult.signal, null);
  await sleep(600);
  pipeline.stop();
  const pipelineResult = await pipeline.waitExit();
  clearInterval(timer);
  timer = undefined;
  sample();
  assert.ok(terminal && terminal.telemetryEOF && terminal.decoderCadence.ended);
  assert.equal(terminal.decoderCadence.invalidReason, null);
  assert.equal(terminal.decodedFrameHistory.invalidReason, null);
  assert.ok([0, 255].includes(pipelineResult.code));
  assert.equal(pipelineResult.signal, null);
  const decoded = await execute(ffmpeg, ['-v', 'error', '-i', outputPath, '-f', 'null', '-'], {
    timeout: 30000,
    maxBuffer: 1024 * 1024,
  });
  assert.equal(decoded.stderr, '');
  const probe = JSON.parse(
    (
      await execute(ffprobe, [
        '-v',
        'error',
        '-count_frames',
        '-show_streams',
        '-of',
        'json',
        outputPath,
      ])
    ).stdout,
  );
  const report = {
    pauseAt,
    stalledAt,
    resumeAt,
    resumedAt,
    sourceResult,
    pipelineResult,
    terminal,
    probe,
    events,
    samples,
  };
  await writeFile(join(artifact, 'results.json'), JSON.stringify(report, null, 2));
  await writeFile(join(artifact, 'decode.log'), decoded.stderr);
  console.log(
    JSON.stringify(
      {
        samples: samples.length,
        decodedFrames: terminal.decodedVideo.freshFrames,
        pauseToStallMs: stalledAt - pauseAt,
        resumeToProgressMs: resumedAt - resumeAt,
        artifact,
      },
      null,
      2,
    ),
  );
} finally {
  if (timer) clearInterval(timer);
  if (source && !sourceDone) {
    if (paused) source.kill('SIGCONT');
    source.kill('SIGTERM');
    await sourceExit;
  }
  if (pipeline) {
    pipeline.stop();
    await pipeline.waitExit();
  }
  await writeFile(
    join(artifact, 'observations.json'),
    JSON.stringify({ events, samples, terminal }, null, 2),
  );
}
