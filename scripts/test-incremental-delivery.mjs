import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createApp } from '../apps/control-plane/src/app.ts';
import { testConfig } from '../apps/control-plane/test/helpers.ts';
import { WorkerReporter } from '../apps/home-daemon/src/worker-reporter.ts';
import { advanceDelivery } from '../packages/protocol/dist/index.js';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { createSocket } from 'node:dgram';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startPipeline } from '../apps/home-daemon/src/pipeline.ts';
import { mediaTools } from './media-tools.mjs';
const root = fileURLToPath(new URL('..', import.meta.url));
const artifact = await mkdtemp(join(root, 'artifacts/qa/incremental-delivery-native-'));
const { ffmpeg, ffprobe, font } = mediaTools();
const execute = promisify(execFile);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const sourcePath = join(artifact, 'source.ts'),
  outputPath = join(artifact, 'output.flv');
await writeFile(join(artifact, 'score.txt'), 'Home 0 - 0 Away');
console.log(`Decoder delivery evidence: ${artifact}`);
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
let stopReporting, reportingResult;
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
  const delivery = pipeline.snapshotDecoderDelivery();
  assert(delivery && delivery.arrivals.length <= 256);
  samples.push({ before, after: performance.now(), snapshot, delivery });
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
      gameId: 'decoder-delivery',
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
      deliveryTimeline: true,
      onTerminal: (value) => {
        terminal = value;
      },
    },
  );
  stopReporting = await startReporting(pipeline);
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
  reportingResult = await stopReporting();
  stopReporting = undefined;
  pipeline.stop();
  const pipelineResult = await pipeline.waitExit();
  clearInterval(timer);
  timer = undefined;
  sample();
  assert.ok(terminal && terminal.telemetryEOF && terminal.decoderCadence.ended);
  assert.equal(terminal.decoderCadence.invalidReason, null);
  const delivery = pipeline.snapshotDecoderDelivery();
  assert(delivery.ended && delivery.invalidReason === null);
  assert.equal(delivery.lastOrdinal, terminal.decodedVideo.freshFrames);
  assert.equal(delivery.arrivals.length, Math.min(256, delivery.lastOrdinal));
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
    reportingResult,
    delivery,
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
        reporting: reportingResult.summary,
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
  if (stopReporting) await stopReporting();
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

async function startReporting(pipeline) {
  const config = testConfig();
  let built = createApp(config);
  const matches = built.matches;
  const team = { name: 'Team', shortName: 'T', color: '#123456' };
  matches.create({
    id: 'delivery',
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const credential = matches.issueCredential('delivery', 'scorer', 'score');
  matches.issueCredential('delivery', 'phone', 'capture');
  matches.media.reportRecording('delivery', 'phone', {
    recordingId: 'archive',
    sequence: 0,
    status: 'recording',
    startedAt: new Date().toISOString(),
  });
  matches.media.execute({
    commandId: 'start',
    gameId: 'delivery',
    expectedGeneration: 0,
    issuedAt: new Date().toISOString(),
    operation: {
      type: 'start',
      selection: {
        workerId: 'local',
        outputId: 'sink',
        captureDeviceId: 'phone',
        recordingId: 'archive',
      },
    },
  });
  let lostAcknowledgement = false,
    lostAcknowledgementOrdinal,
    clientResynchronized = false,
    restarted = false,
    posts = 0;
  const exchanges = [],
    sourcePackets = [],
    wirePackets = [],
    errors = [];
  const server = createServer(async (req, res) => {
    try {
      let raw = '';
      for await (const chunk of req) raw += chunk;
      const response = await built.app.request(req.url, {
        method: req.method,
        headers: req.headers,
        ...(raw ? { body: raw } : {}),
      });
      if (req.url.endsWith('/observations')) {
        posts++;
        const body = JSON.parse(raw);
        wirePackets.push({
          sequence: body.sequence,
          packet: body.observation.decoderDelivery,
          status: response.status,
          bytes: Buffer.byteLength(raw),
        });
        if (
          !lostAcknowledgement &&
          body.observation.decoderDelivery.lastOrdinal >= 100 &&
          body.observation.decoderDelivery.arrivals.length > 0 &&
          response.status === 200
        ) {
          lostAcknowledgement = true;
          lostAcknowledgementOrdinal = body.observation.decoderDelivery.lastOrdinal;
          res.destroy();
          return;
        }
      }
      res.writeHead(response.status, Object.fromEntries(response.headers));
      res.end(await response.text());
    } catch (error) {
      errors.push(String(error));
      res.writeHead(500);
      res.end('{}');
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  const reporter = new WorkerReporter(url, config.HOME_TOKEN, 'local', 1500, 'actual-delivery');
  let stop = false,
    failure,
    clientHistory,
    clientEpoch,
    reportErrors = 0,
    ticks = 0;
  const task = (async () => {
    while (!stop) {
      if (!restarted && clientHistory?.lastOrdinal >= 200) {
        built = createApp(config, { matches });
        restarted = true;
      }
      ticks++;
      try {
        await reporter.report(() => {
          const e = pipeline.snapshotVideoEvidence();
          sourcePackets.push(e.decoderDelivery);
          return {
            gameId: 'delivery',
            generation: 1,
            state: 'starting',
            reason: null,
            attempt: 1,
            frame: null,
            outTimeUs: null,
            scoreRevision: 0,
            pipelineReadId: '22222222-2222-4222-8222-222222222222',
            decodedVideo: e.decodedVideo,
            decoderDelivery: e.decoderDelivery,
          };
        });
      } catch (error) {
        reportErrors++;
        assert.equal(reportErrors, 1);
        assert(lostAcknowledgement);
      }
      if (!clientResynchronized && clientHistory?.lastOrdinal >= 300) {
        clientHistory = undefined;
        clientResynchronized = true;
      }
      const query = new URLSearchParams({ decoderDelivery: 'decoder-delivery-delta-v1' });
      if (clientHistory) {
        query.set('deliveryScope', clientHistory.scopeID);
        query.set('deliveryAfter', String(clientHistory.lastOrdinal));
      }
      const before = performance.now();
      const response = await fetch(`${url}/v1/matches/delivery/media/status?${query}`, {
        headers: { authorization: `Bearer ${credential.token}` },
      });
      assert.equal(response.status, 200);
      const raw = await response.text(),
        status = JSON.parse(raw).status;
      const after = performance.now();
      const packet = status.observation.decoderDelivery;
      // Scope-relative history is reusable after API restart only because this
      // diagnostic checks exact collector identity; native ownership still resets.
      const epochChanged = clientEpoch !== undefined && clientEpoch !== status.workerEpoch;
      clientHistory = advanceDelivery(clientHistory, packet);
      clientEpoch = status.workerEpoch;
      assert.deepEqual(clientHistory, sourcePackets.at(-1));
      assert(Number.isFinite(status.decoderDeliveryAgeUpperBoundMs));
      exchanges.push({
        before,
        after,
        packet,
        epoch: clientEpoch,
        epochChanged,
        ageUpperBoundMs: status.decoderDeliveryAgeUpperBoundMs,
        responseBytes: Buffer.byteLength(raw),
        sourcePacketIndex: sourcePackets.length - 1,
      });
      await sleep(100);
    }
  })().catch((error) => {
    failure = String(error);
    stop = true;
  });
  return async () => {
    stop = true;
    await task;
    await new Promise((resolve) => {
      server.closeAllConnections();
      server.close(resolve);
    });
    matches.close();
    const result = {
      exchanges,
      sourcePackets,
      wirePackets,
      errors,
      failure: failure ?? null,
      lostAcknowledgement,
      lostAcknowledgementOrdinal,
      clientResynchronized,
      restarted,
      reportErrors,
      ticks,
    };
    await writeFile(join(artifact, 'http-reporting.json'), JSON.stringify(result, null, 2));
    assert.equal(failure, undefined);
    assert.deepEqual(errors, []);
    assert(lostAcknowledgement && restarted && clientResynchronized);
    assert.equal(reportErrors, 1);
    assert(exchanges.length > 100 && exchanges.some((e) => e.epochChanged));
    const packetBytes = exchanges.map((e) => Buffer.byteLength(JSON.stringify(e.packet)));
    const durationSeconds = (exchanges.at(-1).after - exchanges[0].before) / 1000;
    const sum = (values) => values.reduce((a, b) => a + b, 0);
    result.summary = {
      reports: exchanges.length,
      workerPosts: wirePackets.length,
      retainedArrivals: clientHistory.arrivals.length,
      lastOrdinal: clientHistory.lastOrdinal,
      averagePacketBytes: sum(packetBytes) / packetBytes.length,
      maximumPacketBytes: Math.max(...packetBytes),
      packetPayloadBitsPerSecond: (sum(packetBytes) * 8) / durationSeconds,
      workerRequestBodyBitsPerSecond: (sum(wirePackets.map((p) => p.bytes)) * 8) / durationSeconds,
      statusResponseBodyBitsPerSecond:
        (sum(exchanges.map((e) => e.responseBytes)) * 8) / durationSeconds,
      clientCursorResynchronized: true,
      lostAcknowledgementRecovered: true,
      apiRestartRecovered: true,
    };
    return result;
  };
}
