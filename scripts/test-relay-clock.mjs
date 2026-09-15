import assert from 'node:assert/strict';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createServer } from 'node:net';
import { createSocket } from 'node:dgram';
import { mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { buildFfmpegArgs } from '../apps/home-daemon/src/pipeline.ts';
import { runInstrumentedWorker } from './test-worker-timestamps.mjs';
import { parseTransport, MAX_TS_BYTES, MAX_FRAMES } from './transport-clock-parser.mjs';
import { videoPayloadHashes, compareRelayClock } from './relay-clock-comparison.mjs';
import {
  decodeFrameCodes,
  frameCodeReadFilter,
  sourceFrameCodeFilter,
} from './media-frame-codes.mjs';
import { sourceAudioExpression } from './media-sync.mjs';
import { validatePublishingClockEvidence } from './publishing-clock-evidence.mjs';
import { cancellation } from './cancellation.mjs';
import { mediaTools, executable } from './media-tools.mjs';

assert.equal(process.platform, 'darwin', 'Native relay clock qualification requires macOS');
const checkCancellation = cancellation();
const setupFailure = process.env.SCOREBUG_TEST_RELAY_SETUP_FAILURE;
assert.ok(
  setupFailure === undefined || setupFailure === 'before-send',
  'Unknown relay setup failure injection',
);
const execute = promisify(execFile);
const root = fileURLToPath(new URL('..', import.meta.url));
const directory = await mkdtemp(join(root, 'artifacts/qa/relay-clock-'));
console.log(`Relay clock evidence: ${directory}`);
const { ffmpeg, ffprobe, font } = mediaTools();
const transmitter = executable('srt-live-transmit');
const image = 'bluenviron/mediamtx:1.21.0';
const report = {
  meaning:
    'Finite native/relay/decoder correspondence. A measured offset is not a runtime correction or a loss denominator.',
  directory,
  setupFailure,
  startedAt: new Date().toISOString(),
  image,
  commands: [],
  scenarios: [],
};
const save = () =>
  writeFile(join(directory, 'results.json'), JSON.stringify(report, null, 2) + '\n');
async function run(binary, args, timeout = 30000, cleanup = false) {
  if (!cleanup) checkCancellation();
  const command = { binary, args };
  report.commands.push(command);
  try {
    const result = await execute(binary, args, {
      cwd: root,
      timeout,
      killSignal: 'SIGKILL',
      maxBuffer: 4 * 1024 * 1024,
    });
    command.terminal = { code: 0, signal: null };
    return result;
  } catch (error) {
    command.terminal = { code: error.code ?? null, signal: error.signal ?? null };
    command.stderr = String(error.stderr ?? '').slice(-64000);
    throw error;
  }
}
async function boundedRead(path, maximum = MAX_TS_BYTES) {
  assert.ok((await stat(path)).size <= maximum, 'Artifact byte bound');
  return readFile(path);
}
async function freePort(udp = false) {
  const socket = udp ? createSocket('udp4') : createServer();
  await new Promise((resolve, reject) => {
    socket.once('error', reject);
    if (udp) socket.bind(0, '127.0.0.1', resolve);
    else socket.listen(0, '127.0.0.1', resolve);
  });
  const port = socket.address().port;
  await new Promise((resolve) => socket.close(resolve));
  return port;
}
function start(label, binary, args, result, limit = MAX_TS_BYTES) {
  checkCancellation();
  const child = spawn(binary, args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
  const evidence = { label, binary, args, bytes: 0, stderr: '' };
  result.processes.push(evidence);
  const chunks = [];
  const timeout = setTimeout(() => {
    evidence.timedOut = true;
    child.kill('SIGKILL');
  }, 30000);
  child.stdout.on('data', (data) => {
    evidence.bytes += data.length;
    if (evidence.bytes > limit) {
      evidence.overflow = true;
      child.kill('SIGKILL');
    } else chunks.push(data);
  });
  child.stderr.on('data', (data) => {
    evidence.stderr = (evidence.stderr + data).slice(-64000);
  });
  child.once('error', (error) => {
    evidence.spawnError = String(error);
  });
  const done = new Promise((resolve) =>
    child.once('close', (code, signal) => {
      clearTimeout(timeout);
      evidence.terminal = { code, signal };
      resolve();
    }),
  );
  return { child, evidence, chunks, done };
}
async function stop(item) {
  if (!item) return;
  if (!item.evidence.terminal) {
    item.evidence.stopRequested = true;
    item.child.kill('SIGTERM');
  }
  await Promise.race([item.done, delay(2000)]);
  if (!item.evidence.terminal) item.child.kill('SIGKILL');
  await item.done;
}
async function until(fn, label, processes = []) {
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) {
    checkCancellation();
    for (const item of processes)
      assert.equal(
        item.evidence.terminal,
        undefined,
        `${item.evidence.label} exited during ${label}`,
      );
    if (await fn()) return;
    await delay(100);
  }
  throw new Error(`Timed out waiting for ${label}`);
}
async function boundFrames(file, label, scenario) {
  const raw = await boundedRead(file);
  const transport = parseTransport(raw);
  const hashes = videoPayloadHashes(raw);
  const codesPath = join(directory, `${scenario.name}-${label}.gray`);
  // Full A/V decode also rejects damaged unbounded-length PES tails that framing
  // validation alone cannot prove to be complete H264 syntax.
  await run(ffmpeg, [
    '-v',
    'error',
    '-xerror',
    '-i',
    file,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0',
    '-f',
    'null',
    '-',
  ]);
  await run(ffmpeg, [
    '-v',
    'error',
    '-xerror',
    '-i',
    file,
    '-map',
    '0:v:0',
    '-vf',
    frameCodeReadFilter,
    '-fps_mode',
    'passthrough',
    '-f',
    'rawvideo',
    codesPath,
  ]);
  const codes = decodeFrameCodes(await boundedRead(codesPath, MAX_FRAMES * 16));
  const decoded = JSON.parse(
    (
      await run(ffprobe, [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_frames',
        '-show_entries',
        'frame=pts',
        '-of',
        'json',
        file,
      ])
    ).stdout,
  ).frames;
  assert.equal(codes.length, transport.video.length, 'One decoded picture per video PES');
  assert.equal(decoded.length, codes.length);
  assert.equal(hashes.length, codes.length);
  return transport.video.map((frame, index) => ({
    code: codes[index],
    wirePTS: frame.pts,
    decoderPTS: decoded[index].pts,
    payloadHash: hashes[index],
  }));
}
async function scenario(source, name, origin, readerDelay) {
  const result = { name, origin, readerDelay, processes: [] };
  report.scenarios.push(result);
  const container = `scorebug-relay-clock-${randomUUID()}`;
  result.container = container;
  const children = [];
  let udp,
    forwarded = Promise.resolve(),
    forwardingError;
  let remainder = Buffer.alloc(0);
  const launch = (...args) => {
    const child = start(...args, result);
    children.push(child);
    return child;
  };
  try {
    const ingress = await freePort(true),
      api = await freePort(),
      nativePort = await freePort(true),
      forwardPort = await freePort(true);
    const config = join(directory, `${name}.yml`);
    await writeFile(
      config,
      `logLevel: info\napi: true\napiAddress: :9997\nrtsp: false\nrtmp: false\nhls: false\nwebrtc: false\nmoq: false\nsrt: true\nsrtAddress: :8890\nauthInternalUsers:\n- user: any\n  permissions:\n  - action: publish\n    path: fixture\n  - action: read\n    path: fixture\n  - action: api\npaths:\n  fixture:\n    srtPublishPassphrase: qa-publish-encryption\n    srtReadPassphrase: qa-read-encryption\n`,
    );
    await run('docker', [
      'run',
      '-d',
      '--name',
      container,
      '-p',
      `127.0.0.1:${ingress}:8890/udp`,
      '-p',
      `127.0.0.1:${api}:9997`,
      '-v',
      `${config}:/mediamtx.yml:ro`,
      report.imageID,
    ]);
    const apiURL = `http://127.0.0.1:${api}/v3/paths/get/fixture`;
    await until(async () => {
      try {
        return (
          await fetch(`http://127.0.0.1:${api}/v3/paths/list`, {
            signal: AbortSignal.timeout(1000),
          })
        ).ok;
      } catch {
        return false;
      }
    }, 'owned relay API');
    const publisher = launch('raw-publisher', transmitter, [
      '-a:no',
      '-t:25',
      '-c:1316',
      `udp://127.0.0.1:${forwardPort}`,
      `srt://127.0.0.1:${ingress}?mode=caller&streamid=publish:fixture&passphrase=qa-publish-encryption&latency=120`,
    ]);
    const bridge = launch('native-raw-capture', transmitter, [
      '-a:no',
      '-t:25',
      '-c:1316',
      `srt://127.0.0.1:${nativePort}?mode=listener&latency=120`,
      'file://con',
    ]);
    udp = createSocket('udp4');
    if (setupFailure === 'before-send') throw new Error('Injected failure before first UDP send');
    // Avoid SRT 1.5.6 ConsoleSource's short-read padding bug. Stdout remains a raw
    // byte stream; reframe it into <=1316-byte UDP payloads without changing bytes.
    const send = (packet) =>
      new Promise((resolve, reject) =>
        udp.send(packet, forwardPort, '127.0.0.1', (error) => (error ? reject(error) : resolve())),
      );
    bridge.child.stdout.on('data', (chunk) => {
      if (bridge.evidence.overflow || forwardingError) return;
      remainder = Buffer.concat([remainder, chunk]);
      while (remainder.length >= 1316) {
        const packet = Buffer.from(remainder.subarray(0, 1316));
        remainder = remainder.subarray(1316);
        forwarded = forwarded
          .then(() => (forwardingError ? undefined : send(packet)))
          .catch((error) => {
            forwardingError = error;
          });
      }
    });
    for (const [item, port] of [
      [publisher, forwardPort],
      [bridge, nativePort],
    ]) {
      await until(
        async () => {
          try {
            await run('/usr/sbin/lsof', [
              '-nP',
              '-a',
              '-p',
              String(item.child.pid),
              `-iUDP:${port}`,
            ]);
            return true;
          } catch {
            return false;
          }
        },
        'owned raw listener',
        [item],
      );
    }
    const native = launch(
      'native',
      join(root, 'tools/media-sdk-probe/.build/debug/DualOutputSmoke'),
      [
        source,
        join(directory, `${name}-archive`),
        `srt://127.0.0.1:${nativePort}?mode=caller&latency=120&conntimeo=1500&sndtimeo=200&peeridletimeo=2000`,
        String(origin),
      ],
    );
    await until(
      async () => {
        const response = await fetch(apiURL, { signal: AbortSignal.timeout(1000) });
        if (!response.ok) return false;
        const path = await response.json();
        if (path.ready) result.readyPath = path;
        return path.ready;
      },
      'published path',
      [native, bridge, publisher],
    );
    const launchReader = (label) =>
      launch(label, transmitter, [
        '-a:no',
        '-t:25',
        '-c:1316',
        `srt://127.0.0.1:${ingress}?mode=caller&streamid=read:fixture&passphrase=qa-read-encryption&latency=120`,
        'file://con',
      ]);
    // Same publication, two distinct reader acquisition boundaries.
    const earlyReader = readerDelay > 0 ? launchReader('early-reader') : undefined;
    await delay(readerDelay);
    checkCancellation();
    const reader = launchReader('raw-reader');
    await native.done;
    await bridge.done;
    await forwarded;
    assert.equal(forwardingError, undefined, 'Raw UDP forwarding failed');
    assert.equal(remainder.length % 188, 0, 'Native byte stream ended inside TS packet');
    if (remainder.length) await send(remainder);
    // Tail integrity is independently gated below; this drain allowance cannot
    // turn a partial recording into a passing result.
    await delay(1500);
    await stop(publisher);
    await stop(reader);
    await stop(earlyReader);
    for (const child of children) {
      assert.equal(child.evidence.timedOut, undefined, `${child.evidence.label} timed out`);
      assert.equal(
        child.evidence.overflow,
        undefined,
        `${child.evidence.label} exceeded byte bound`,
      );
      assert.deepEqual(
        child.evidence.terminal,
        { code: 0, signal: null },
        `${child.evidence.label} terminal result`,
      );
      await writeFile(
        join(directory, `${name}-${child.evidence.label}.log`),
        child.evidence.stderr,
      );
    }
    const eventsText = Buffer.concat(native.chunks).toString();
    await writeFile(join(directory, `${name}-native-events.jsonl`), eventsText);
    const events = eventsText
      .split('\n')
      .filter((line) => line.startsWith('{'))
      .map((line) => JSON.parse(line));
    const archive = events.find((event) => event.event === 'archive-finished');
    assert.equal(archive?.videoFrames, 240);
    assert.equal(archive.archiveRejected, 0);
    const finished = events.find((event) => event.event === 'publisher-finished');
    assert.equal(finished?.videoSubmitted, 240);
    assert.equal(finished.publishingBeforeStop, true);
    result.nativeClock = validatePublishingClockEvidence(
      finished.transportClockBeforeStop,
      finished.transportClockAfterStop,
      { value: origin === 0 ? 0n : 493n, timescale: 4n },
    );
    for (const [label, child] of [
      ['before', bridge],
      ['after', reader],
      ...(earlyReader ? [['early', earlyReader]] : []),
    ]) {
      const path = join(directory, `${name}-${label}.ts`);
      await writeFile(path, Buffer.concat(child.chunks));
      result[label] = await boundFrames(path, label, result);
    }
    assert.equal(result.before.length, 240, 'Raw capture must preserve every native frame');
    const diagnostics = {};
    const workerArgs = buildFfmpegArgs({
      gameId: 'relay-clock',
      pullUrl: join(directory, `${name}-after.ts`),
      publishUrl: join(directory, `${name}-worker.flv`),
      scoreFile: join(directory, 'score.txt'),
      fontPath: font,
      nvenc: false,
      encoder: 'software',
      profile: { width: 1920, height: 1080, fps: 30, bitrateKbps: 6000 },
    });
    result.worker = { args: workerArgs, diagnostics };
    const decoded = await runInstrumentedWorker(ffmpeg, workerArgs, diagnostics);
    assert.equal(
      decoded.length,
      result.after.length,
      'Production decoder must retain every relay frame',
    );
    for (let i = 0; i < decoded.length; i++)
      assert.equal(decoded[i], result.after[i].decoderPTS, 'Production decoder changed input PTS');
    const output = join(directory, `${name}-worker.flv`);
    const outputCodes = join(directory, `${name}-worker.gray`);
    await run(ffmpeg, [
      '-v',
      'error',
      '-xerror',
      '-i',
      output,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0',
      '-f',
      'null',
      '-',
    ]);
    await run(ffmpeg, [
      '-v',
      'error',
      '-xerror',
      '-i',
      output,
      '-map',
      '0:v:0',
      '-vf',
      frameCodeReadFilter,
      '-fps_mode',
      'passthrough',
      '-f',
      'rawvideo',
      outputCodes,
    ]);
    result.worker.outputCodes = decodeFrameCodes(await boundedRead(outputCodes, MAX_FRAMES * 16));
    assert.deepEqual(
      result.worker.outputCodes,
      result.after.map((frame) => frame.code),
      'Production output must retain every acquired source picture',
    );
    result.comparison = compareRelayClock({ before: result.before, after: result.after });
    if (earlyReader) {
      result.earlyComparison = compareRelayClock({ before: result.before, after: result.early });
      assert.ok(
        result.comparison.firstCode > result.earlyComparison.firstCode,
        'Late reader must establish a different acquisition boundary',
      );
      assert.equal(
        result.comparison.offsetTicks,
        result.earlyComparison.offsetTicks,
        'Relay shift changed with reader acquisition within one publication',
      );
    }
    // Pinned normalizing relay is deliberately a negative control for equality.
    assert.equal(
      result.comparison.timestampsPreserved,
      false,
      'Pinned relay unexpectedly preserved the native clock; investigate changed contract',
    );
    result.qualified = true;
    console.log(
      `${name}: ${result.comparison.matchedFrames} matching pictures; relay offset ${result.comparison.offsetTicks} ticks; production decoder preserves relay PTS.`,
    );
  } catch (error) {
    result.error = String(error);
    throw error;
  } finally {
    const cleanupErrors = [];
    for (const child of [...children].reverse()) {
      try {
        await stop(child);
      } catch (error) {
        cleanupErrors.push(String(error));
      }
    }
    await forwarded;
    // A setup failure can leave the socket unbound. It must not bypass Docker
    // teardown or evidence persistence (dgram.close throws in that state).
    if (udp) {
      try {
        await new Promise((resolve) => udp.close(resolve));
      } catch (error) {
        if (error.code !== 'ERR_SOCKET_DGRAM_NOT_RUNNING') cleanupErrors.push(String(error));
      }
    }
    try {
      const logs = await run('docker', ['logs', container], 10000, true);
      await writeFile(join(directory, `${name}-relay.log`), logs.stdout + logs.stderr);
      result.relayWarnings = (logs.stdout + logs.stderr)
        .split('\n')
        .filter((line) => /\b(?:WAR|ERR)\b/.test(line));
      assert.deepEqual(result.relayWarnings, [], 'Relay emitted decode/transport warnings');
    } catch (error) {
      cleanupErrors.push(String(error));
    }
    try {
      await run('docker', ['rm', '-f', container], 10000, true);
      result.containerRemoved = true;
    } catch (error) {
      cleanupErrors.push(String(error));
    }
    result.cleanupErrors = cleanupErrors;
    if (cleanupErrors.length) result.qualified = false;
    await save();
    assert.deepEqual(cleanupErrors, [], 'Owned relay cleanup or logs failed');
  }
}
try {
  report.imageID = (
    await run('docker', ['image', 'inspect', image, '--format', '{{.Id}}'])
  ).stdout.trim();
  const transmitterVersion = await run(transmitter, ['-version']);
  report.transmitterVersion = transmitterVersion.stdout + transmitterVersion.stderr;
  report.ffmpegVersion = (await run(ffmpeg, ['-version'])).stdout.split('\n')[0];
  await run(
    'swift',
    ['build', '--package-path', 'tools/media-sdk-probe', '--product', 'DualOutputSmoke'],
    180000,
  );
  const source = join(directory, 'source.mp4');
  await run(ffmpeg, [
    '-v',
    'error',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=1920x1080:rate=30',
    '-f',
    'lavfi',
    '-i',
    sourceAudioExpression(),
    '-t',
    '8',
    '-vf',
    `drawbox=x=0:y=900:w=iw:h=180:color=black:t=fill,${sourceFrameCodeFilter}`,
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-b:v',
    '12M',
    '-c:a',
    'aac',
    '-ar',
    '48000',
    '-ac',
    '1',
    source,
  ]);
  await writeFile(join(directory, 'score.txt'), 'HOME 1-0 AWAY');
  for (const [name, origin, readerDelay] of [
    ['zero', 0, 0],
    ['offset', 123.25, 0],
    ['late', 123.25, 2500],
  ])
    await scenario(source, name, origin, readerDelay);
  report.qualified = true;
  console.log(`PASS: native relay clock characterization; evidence in ${directory}`);
} catch (error) {
  report.error = String(error);
  throw error;
} finally {
  await save();
}
