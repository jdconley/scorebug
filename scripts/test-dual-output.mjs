import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createSocket } from 'node:dgram';
import { mkdtemp, mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { command, mediaTools } from './media-tools.mjs';
import { cancellation } from './cancellation.mjs';
import { validatePublishingClockEvidence } from './publishing-clock-evidence.mjs';
import {
  qualifyEncoderConfiguration,
  qualifyEncoderSourceHistory,
} from './encoder-configuration-evidence.mjs';
import { qualifyTransportIntervals } from './transport-interval-evidence.mjs';
import { qualifyIngressPressure } from './ingress-pressure-evidence.mjs';
import { qualifyTransportStatistics } from './transport-statistics-evidence.mjs';
import { inspectFrameCodeSamples } from './impaired-media-diagnostics.mjs';
import { createUDPImpairmentProxy } from './udp-impairment.mjs';
import {
  sourceFrameCodeFilter,
  frameCodeReadFilter,
  decodeFrameCodes,
} from './media-frame-codes.mjs';
import {
  sourceAudioExpression,
  analyzeMediaSync,
  assertMediaSync,
  assertMediaCoverage,
} from './media-sync.mjs';
import { measureFreshCadence } from './media-soak.mjs';

const impairment = process.argv.includes('--impairment');
assert.ok(
  process.argv.slice(2).every((arg) => arg === '--impairment'),
  'Unknown native test option',
);
assert.equal(process.platform, 'darwin', 'Native dual-output qualification requires macOS');
const root = fileURLToPath(new URL('..', import.meta.url));
const checkCancellation = cancellation();
const { ffmpeg, ffprobe } = mediaTools();
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/dual-output-'));
const binary = join(root, 'tools/media-sdk-probe/.build/debug/DualOutputSmoke');
const archiveBinary = join(root, 'tools/media-harness/.build/debug/ArchiveHarness');
const children = new Set();
const proxies = new Set();
async function run(binary, args, label, timeout = 60_000) {
  checkCancellation();
  const result = await command(binary, args, timeout);
  assert.ok(
    result.ok,
    `${label} failed (${result.error ?? 'unknown'}): ${(result.stdout + result.stderr).slice(-4000)}`,
  );
  return result.stdout;
}
function start(binary, args) {
  const child = spawn(binary, args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  const item = {
    child,
    exited: false,
    code: null,
    output: '',
    error: '',
    events: [],
    pending: '',
    stopped: false,
  };
  children.add(item);
  child.stdout.on('data', (chunk) => {
    item.output = (item.output + chunk).slice(-128_000);
    item.pending += chunk;
    let newline;
    while ((newline = item.pending.indexOf('\n')) >= 0) {
      const line = item.pending.slice(0, newline);
      item.pending = item.pending.slice(newline + 1);
      try {
        item.events.push(JSON.parse(line));
      } catch {}
    }
  });
  child.stderr.on('data', (chunk) => {
    item.error = (item.error + chunk).slice(-32_000);
  });
  item.done = new Promise((resolve) => {
    const finish = (code) => {
      if (item.exited) return;
      item.exited = true;
      item.code = code;
      children.delete(item);
      resolve();
    };
    child.once('error', () => finish(null));
    child.once('close', finish);
  });
  return item;
}
async function until(predicate, label, timeout = 30_000) {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    checkCancellation();
    if (await predicate()) return;
    await delay(20);
  }
  throw new Error(`Timed out: ${label}`);
}
async function stop(item) {
  if (!item || item.exited) return;
  if (item.stopped) {
    item.child.kill('SIGCONT');
    item.stopped = false;
  }
  item.child.kill('SIGINT');
  await Promise.race([item.done, delay(2000)]);
  if (!item.exited) item.child.kill('SIGKILL');
  await Promise.race([item.done, delay(2000)]);
  assert.ok(item.exited, 'Owned native test process did not exit');
}
async function freePort() {
  const socket = createSocket('udp4');
  await new Promise((resolve, reject) => {
    socket.once('error', reject);
    socket.bind(0, '127.0.0.1', resolve);
  });
  const port = socket.address().port;
  await new Promise((resolve) => socket.close(resolve));
  return port;
}

async function analyze(path, label, requireComplete) {
  await run(
    ffmpeg,
    ['-v', 'error', '-xerror', '-i', path, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'],
    `${label} full decode`,
  );
  const probe = JSON.parse(
    await run(
      ffprobe,
      ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', path],
      `${label} formats`,
    ),
  );
  const streams = probe.streams;
  const video = streams.find((x) => x.codec_type === 'video');
  const audio = streams.find((x) => x.codec_type === 'audio');
  assert.equal(video?.codec_name, 'h264');
  assert.equal(video.width, 1920);
  assert.equal(video.height, 1080);
  assert.equal(audio?.codec_name, 'aac');
  assert.equal(Number(audio.sample_rate), 48000);
  if (requireComplete) {
    assert.ok(Math.abs(Number(probe.format.start_time)) <= 0.1, 'Export has a leading clock gap');
    assert.ok(
      Math.abs(Number(probe.format.duration) - 14) <= 0.1,
      'Export duration must exclude the source clock origin',
    );
  }
  const codeFile = join(artifact, `${label}.codes`);
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-i',
      path,
      '-an',
      '-vf',
      frameCodeReadFilter,
      '-fps_mode',
      'passthrough',
      '-f',
      'rawvideo',
      codeFile,
    ],
    `${label} frame identities`,
  );
  const codes = decodeFrameCodes(await readFile(codeFile));
  if (requireComplete) {
    assert.equal(codes.length, 420, 'Archive must retain all source frames');
    assert.ok(
      codes.every((code, i) => code === i),
      'Archive lost or repeated source frames',
    );
  } else {
    assert.equal(codes[0], 0, 'Normal fixture stream lost its first video sample');
    assert.ok(
      codes[0] <= 30 && codes.at(-1) >= 390,
      'Normal stream startup or final-frame gap exceeded one second',
    );
  }
  const frames = async (selector, fields) =>
    JSON.parse(
      await run(
        ffprobe,
        [
          '-v',
          'error',
          '-select_streams',
          selector,
          '-show_frames',
          '-show_entries',
          `frame=${fields}`,
          '-of',
          'json',
          path,
        ],
        `${label} timestamps`,
      ),
    ).frames;
  const videoTimes = (await frames('v:0', 'best_effort_timestamp_time')).map((x) =>
    Number(x.best_effort_timestamp_time),
  );
  const cadence = measureFreshCadence(codes, videoTimes);
  const audioFrames = await frames('a:0', 'best_effort_timestamp_time,nb_samples');
  const audioStartTime = Number(audioFrames[0].best_effort_timestamp_time);
  let sampleCount = 0;
  for (const frame of audioFrames) {
    assert.ok(
      Math.abs(Number(frame.best_effort_timestamp_time) - audioStartTime - sampleCount / 48000) <
        0.002,
      `${label} audio discontinuity`,
    );
    sampleCount += frame.nb_samples;
  }
  const coverage = assertMediaCoverage({
    videoTimes,
    audioStartTime,
    audioSampleCount: sampleCount,
    sampleRate: 48000,
  });
  const raw = join(artifact, `${label}.audio`);
  await run(
    ffmpeg,
    ['-v', 'error', '-y', '-i', path, '-vn', '-ac', '1', '-ar', '48000', '-f', 'f32le', raw],
    `${label} PCM`,
  );
  const bytes = await readFile(raw);
  assert.equal(bytes.length, sampleCount * 4);
  const sync = analyzeMediaSync({
    codes,
    videoTimes,
    audioSamples: new Float32Array(bytes.buffer, bytes.byteOffset, sampleCount),
    sampleRate: 48000,
    audioStartTime,
  });
  assertMediaSync(sync);
  return {
    frames: codes.length,
    firstCode: codes[0],
    lastCode: codes.at(-1),
    cadence,
    coverage,
    sync,
  };
}

async function measureBitrateChange(path) {
  const packets = JSON.parse(
    await run(
      ffprobe,
      [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_packets',
        '-show_entries',
        'packet=pts_time,size',
        '-of',
        'json',
        path,
      ],
      'Live encoded video bitrate',
    ),
  ).packets;
  const origin = Number(packets[0].pts_time);
  const rates = [
    [1, 4],
    [7, 12],
  ].map(
    ([start, end]) =>
      (packets
        .filter((packet) => {
          const time = Number(packet.pts_time) - origin;
          return time >= start && time < end;
        })
        .reduce((sum, packet) => sum + Number(packet.size), 0) *
        8) /
      (end - start),
  );
  assert.ok(
    rates[0] > 4_000_000 && rates[1] > 1_000_000,
    'Encoded video rate was unexpectedly low',
  );
  assert.ok(rates[1] / rates[0] < 0.6, 'Live bitrate change did not affect encoded output');
  return {
    beforeBitsPerSecond: rates[0],
    afterBitsPerSecond: rates[1],
    ratio: rates[1] / rates[0],
  };
}

function qualifyProxy(snapshot, scenario) {
  assert.equal(snapshot.closed, true);
  assert.deepEqual(snapshot.errors, []);
  assert.equal(snapshot.foreignPeerPackets, 0);
  for (const direction of [snapshot.forward, snapshot.reverse]) {
    const queue = direction.queue,
      config = queue.configuration;
    assert.ok(
      queue.received.packets > 0 && queue.forwarded.packets > 0,
      'Missing bidirectional proxy traffic',
    );
    assert.equal(direction.pendingPackets, 0);
    assert.equal(direction.pendingPayloadBytes, 0);
    assert.ok(
      direction.peakPendingPackets <= 16 &&
        direction.peakPendingPayloadBytes <= 16 * config.maxDatagramBytes,
    );
    assert.equal(queue.closed, true);
    assert.equal(queue.queue.packets, 0);
    assert.equal(queue.queue.wireBytes, 0);
    assert.equal(queue.oversizeDrop.packets, 0);
    assert.ok(
      queue.queue.peakPackets <= config.maxQueuePackets &&
        queue.queue.peakWireBytes <= config.maxQueueBytes,
    );
    for (const key of ['packets', 'wireBytes'])
      assert.equal(
        queue.received[key],
        ['forwarded', 'injectedDrop', 'overflowDrop', 'oversizeDrop', 'closeDiscard'].reduce(
          (n, k) => n + queue[k][key],
          0,
        ),
      );
    if (config.rateBitsPerSecond !== null) {
      const elapsed = queue.lastForwardedAt - queue.firstForwardedAt;
      assert.ok(
        queue.forwarded.wireBytes <=
          config.burstBytes + (elapsed * config.rateBitsPerSecond) / 8000 + 1e-6,
        'Actual proxy departures exceed rate plus burst',
      );
    }
  }
  if (scenario === 'proxy-recoverable') {
    assert.ok(snapshot.forward.queue.injectedDrop.packets > 0);
    assert.ok(snapshot.reverse.queue.injectedDrop.packets > 0);
  }
  if (scenario === 'proxy-overload')
    assert.ok(
      snapshot.forward.queue.overflowDrop.packets > 0,
      'Overload did not exercise bounded queue loss',
    );
}

async function inspectImpairedLive(path, label) {
  let qualificationError;
  try {
    return { qualified: true, media: await analyze(path, label, false) };
  } catch (error) {
    qualificationError = String(error.message).slice(0, 4000);
  }
  const codeFile = join(artifact, `${label}-best-effort.codes`);
  const decoded = await command(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-i',
      path,
      '-an',
      '-vf',
      frameCodeReadFilter,
      '-fps_mode',
      'passthrough',
      '-f',
      'rawvideo',
      codeFile,
    ],
    30000,
  );
  await writeFile(join(artifact, `${label}-best-effort.log`), decoded.stdout + decoded.stderr);
  let codeSamples = null;
  try {
    codeSamples = await readFile(codeFile);
  } catch {}
  const probed = await command(
    ffprobe,
    [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_frames',
      '-show_entries',
      'frame=best_effort_timestamp_time',
      '-of',
      'json',
      path,
    ],
    30000,
  );
  let times = [];
  try {
    times = JSON.parse(probed.stdout).frames.map((x) => Number(x.best_effort_timestamp_time));
  } catch {}
  return {
    qualified: false,
    qualificationError,
    bestEffortDecodeSucceeded: decoded.ok,
    ...inspectFrameCodeSamples(codeSamples, times),
  };
}

try {
  await run(
    'swift',
    ['build', '--package-path', 'tools/media-sdk-probe', '--product', 'DualOutputSmoke'],
    'Dual output build',
    180_000,
  );
  await run(
    'swift',
    ['build', '--package-path', 'tools/media-harness'],
    'Archive export harness build',
    120_000,
  );
  const source = join(artifact, 'source.mp4');
  await run(
    ffmpeg,
    [
      '-v',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=1920x1080:rate=30',
      '-f',
      'lavfi',
      '-i',
      sourceAudioExpression(),
      '-t',
      '14',
      '-vf',
      `drawbox=x=0:y=900:w=iw:h=180:color=black:t=fill,${sourceFrameCodeFilter}`,
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-b:v',
      '12000k',
      '-g',
      '60',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-ar',
      '48000',
      '-b:a',
      '128k',
      source,
    ],
    'Fixture source',
  );
  const results = [];
  const scenarios = impairment
    ? ['proxy-transparent', 'proxy-recoverable', 'proxy-overload']
    : ['record-only', 'normal', 'normal-clock-offset', 'stalled-receiver', 'no-receiver'];
  for (const scenario of scenarios) {
    const normal =
      scenario.startsWith('normal') ||
      ['proxy-transparent', 'proxy-recoverable'].includes(scenario);
    const port = await freePort();
    const live = join(artifact, `${scenario}.ts`);
    let receiver;
    if (normal || scenario === 'stalled-receiver' || scenario === 'proxy-overload') {
      receiver = start(ffmpeg, [
        '-nostdin',
        '-v',
        'warning',
        '-y',
        '-i',
        `srt://127.0.0.1:${port}?mode=listener&latency=120000&timeout=5000000`,
        '-map',
        '0:v:0',
        '-map',
        '0:a:0',
        '-c',
        'copy',
        '-f',
        'mpegts',
        live,
      ]);
      await until(async () => {
        assert.ok(!receiver.exited, `Receiver failed: ${receiver.error}`);
        return (
          await command(
            '/usr/sbin/lsof',
            ['-nP', '-a', '-p', String(receiver.child.pid), `-iUDP:${port}`],
            2000,
          )
        ).ok;
      }, 'owned UDP listener');
    }
    let proxyRecord;
    if (impairment) {
      const forward =
        scenario === 'proxy-recoverable'
          ? { rateBitsPerSecond: 12000000, delayMilliseconds: 10, dropEvery: 100 }
          : scenario === 'proxy-overload'
            ? { rateBitsPerSecond: 3000000, delayMilliseconds: 10, maxQueueBytes: 32768 }
            : {};
      const reverse =
        scenario === 'proxy-transparent'
          ? {}
          : {
              rateBitsPerSecond: 1000000,
              delayMilliseconds: 10,
              dropEvery: scenario === 'proxy-recoverable' ? 80 : 0,
            };
      const proxy = await createUDPImpairmentProxy({ receiverPort: port, forward, reverse });
      proxyRecord = { proxy, path: join(artifact, `${scenario}-proxy.json`) };
      proxies.add(proxyRecord);
    }
    const publisherPort = proxyRecord?.proxy.port ?? port;
    const directory = join(artifact, `${scenario}-archive`);
    // SDK URI values use libsrt milliseconds; FFmpeg latency above uses microseconds.
    const nativeArgs = [
      source,
      directory,
      scenario === 'record-only'
        ? 'record-only'
        : `srt://127.0.0.1:${publisherPort}?mode=caller&latency=120&conntimeo=1500&sndtimeo=200&peeridletimeo=2000`,
    ];
    if (scenario === 'normal-clock-offset') nativeArgs.push('123.25');
    const native = start(binary, nativeArgs);
    const memory = [];
    const started = performance.now();
    let nextMemory = 0;
    await until(
      async () => {
        const elapsed = (performance.now() - started) / 1000;
        if (proxyRecord)
          assert.deepEqual(
            proxyRecord.proxy.snapshot().errors,
            [],
            'Owned impairment proxy failed',
          );
        if (scenario === 'stalled-receiver' && !receiver.stopped && elapsed >= 6) {
          assert.ok(!receiver.exited, receiver.error);
          assert.ok(receiver.child.kill('SIGSTOP'));
          receiver.stopped = true;
        }
        if (!native.exited && elapsed >= nextMemory) {
          const rss = await command(
            '/bin/ps',
            ['-p', String(native.child.pid), '-o', 'rss='],
            2000,
          );
          if (rss.ok) memory.push({ elapsed, bytes: Number(rss.stdout.trim()) * 1024 });
          nextMemory = elapsed + 0.5;
        }
        return native.exited;
      },
      `${scenario} native completion`,
      35_000,
    );
    await writeFile(join(artifact, `${scenario}.log`), native.output + native.error);
    // Structured evidence is intentionally separate from the bounded diagnostic tail.
    // The joined 420-frame descriptor event can exceed that log's character limit.
    await writeFile(
      join(artifact, `${scenario}-events.json`),
      JSON.stringify(native.events, null, 2),
    );
    await writeFile(join(artifact, `${scenario}-memory.json`), JSON.stringify(memory, null, 2));
    assert.equal(native.code, 0, native.output + native.error);
    const finished = native.events.find((x) => x.event === 'archive-finished');
    assert.ok(finished, 'Archive did not report finalization');
    assert.equal(finished.videoFrames, 420);
    assert.equal(finished.audioSamples, 672000);
    assert.equal(finished.archiveRejected, 0);
    assert.ok(
      finished.maximumSourceLagSeconds <= 0.25,
      'Fixture producer fell behind real time by more than 250 ms',
    );
    assert.ok(finished.archivePeakBytes <= 24 * 1024 * 1024);
    assert.ok(finished.livePeakBytes <= 12 * 1024 * 1024);
    const peakRSS = Math.max(...memory.map((x) => x.bytes));
    assert.ok(peakRSS < 512 * 1024 * 1024, `Native memory exceeded 512 MiB: ${peakRSS}`);
    let networkImpairment;
    if (proxyRecord) {
      await until(
        () => {
          const snapshot = proxyRecord.proxy.snapshot();
          return [snapshot.forward, snapshot.reverse].every(
            (direction) => direction.queue.queue.packets === 0 && direction.pendingPackets === 0,
          );
        },
        'owned proxy drain',
        2000,
      );
      await proxyRecord.proxy.close();
      networkImpairment = proxyRecord.proxy.snapshot();
      await writeFile(proxyRecord.path, JSON.stringify(networkImpairment, null, 2));
      proxies.delete(proxyRecord);
      qualifyProxy(networkImpairment, scenario);
    }
    await stop(receiver);
    if (receiver) await writeFile(join(artifact, `${scenario}-receiver.log`), receiver.error);
    const exported = join(artifact, `${scenario}-archive.mp4`);
    await run(archiveBinary, ['export', directory, exported], `${scenario} archive export`);
    const archiveResult = await analyze(exported, `${scenario}-archive`, true);
    let liveResult;
    let bitrateChange;
    let transportClock;
    let transportStatistics;
    let encoderConfiguration;
    let encoderSourceHistory;
    let ingressPressure;
    let transportIntervals;
    let impairedLive;
    if (scenario === 'record-only') {
      assert.equal(finished.livePeakBytes, 0);
      assert.deepEqual(
        native.events.filter((x) => x.event.startsWith('publisher-')).map((x) => x.event),
        ['publisher-disabled'],
        'Offline recording must not start a publisher',
      );
    }
    if (normal || scenario === 'proxy-overload') {
      assert.ok(native.events.some((x) => x.event === 'bitrate-changed'));
      const sent = native.events.find((x) => x.event === 'publisher-finished');
      assert.ok(sent?.sentBytes > 0 && sent.publishingBeforeStop);
      transportClock = validatePublishingClockEvidence(
        sent.transportClockBeforeStop,
        sent.transportClockAfterStop,
        { value: scenario === 'normal-clock-offset' ? 493n : 0n, timescale: 4n },
      );
      transportStatistics = qualifyTransportStatistics(
        native.events,
        sent,
        transportClock.publishingGeneration,
      );
      assert.ok(transportStatistics.windows.length >= 2, 'Missing complete transport windows');
      const changes = native.events.filter((x) => x.event === 'bitrate-changed');
      assert.equal(changes.length, 1);
      encoderConfiguration = qualifyEncoderConfiguration({
        clock: transportClock,
        receipt: changes[0].receipt,
        evidence: sent.encoderEvidence,
        decodedSourceFrames: decodeFrameCodes(
          await readFile(join(artifact, `${scenario}-archive.codes`)),
        ),
      });
      encoderSourceHistory = qualifyEncoderSourceHistory({
        clock: transportClock,
        receipt: changes[0].receipt,
        evidence: sent.encoderEvidence,
        history: sent.encoderSourceHistory,
        decodedSourceFrames: decodeFrameCodes(
          await readFile(join(artifact, `${scenario}-archive.codes`)),
        ),
      });
      ingressPressure = qualifyIngressPressure({
        pressure: sent.ingressPressure,
        source: sent.encoderSourceHistory,
      });
      transportIntervals = qualifyTransportIntervals({
        history: sent.transportHistory,
        source: sent.encoderSourceHistory,
        validatedSamples: transportStatistics.samples,
      });
      if (normal) {
        liveResult = await analyze(live, `${scenario}-live`, false);
        bitrateChange = await measureBitrateChange(live);
        qualifyEncoderConfiguration({
          clock: transportClock,
          receipt: changes[0].receipt,
          evidence: sent.encoderEvidence,
          decodedSourceFrames: decodeFrameCodes(
            await readFile(join(artifact, `${scenario}-live.codes`)),
          ),
        });
      }
    }
    if (scenario === 'proxy-overload') {
      impairedLive = await inspectImpairedLive(live, `${scenario}-live`);
      assert.ok(
        native.events.some((x) => ['publisher-finished', 'publisher-failed'].includes(x.event)),
        'Overloaded publisher did not settle',
      );
    }
    if (scenario === 'no-receiver')
      assert.ok(native.events.some((x) => x.event === 'publisher-failed'));
    if (scenario === 'stalled-receiver') {
      assert.ok(native.events.some((x) => x.event === 'publisher-started'));
      assert.ok(
        native.events.some((x) => x.event === 'publisher-failed'),
        'Stalled stream did not report failure',
      );
    }
    results.push({
      scenario,
      archive: archiveResult,
      live: liveResult,
      bitrateChange,
      transportClock,
      transportStatistics,
      encoderConfiguration,
      encoderSourceHistory,
      ingressPressure,
      transportIntervals,
      networkImpairment,
      impairedLive,
      counters: finished,
      peakRSS,
    });
    console.log(
      `${scenario}: archive ${archiveResult.frames} fresh frames; peak RSS ${(peakRSS / 1024 / 1024).toFixed(1)} MiB.`,
    );
  }
  await writeFile(join(artifact, 'results.json'), JSON.stringify(results, null, 2));
  console.log(`PASS: native dual output; evidence in ${artifact}`);
} finally {
  for (const child of [...children]) await stop(child);
  for (const { proxy, path } of proxies) {
    await proxy.close();
    await writeFile(path, JSON.stringify(proxy.snapshot(), null, 2));
  }
}
