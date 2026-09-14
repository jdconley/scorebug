import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { createSocket } from 'node:dgram';
import { mkdtemp, mkdir, copyFile, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { mediaTools, command } from './media-tools.mjs';
import { cancellation } from './cancellation.mjs';
import { startScoringTestServer, scoringTestToken } from './scoring-test-server.mjs';
import { buildFfmpegArgs } from '../apps/home-daemon/src/pipeline.ts';
import {
  sourceFrameCodeFilter,
  frameCodeReadFilter,
  decodeFrameCodes,
} from './media-frame-codes.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const encoder = process.argv[2] ?? 'software';
assert.ok(['software', 'videotoolbox'].includes(encoder), 'Choose software or videotoolbox');
const checkCancellation = cancellation();
const directory = await mkdtemp(join(tmpdir(), 'scorebug-worker-'));
const artifact = join(root, 'artifacts', 'qa', `native-worker-${encoder}`);
const names = [];
const children = new Set();
const { ffmpeg, ffprobe, font } = mediaTools();
let api;
let worker;
const headers = {
  authorization: `Basic ${Buffer.from('qa-admin:qa-admin-not-production').toString('base64')}`,
};

async function port(udp = false) {
  const socket = udp ? createSocket('udp4') : createServer();
  await new Promise((resolve, reject) => {
    socket.once('error', reject);
    if (udp) socket.bind(0, '127.0.0.1', resolve);
    else socket.listen(0, '127.0.0.1', resolve);
  });
  const number = socket.address().port;
  await new Promise((resolve) => socket.close(resolve));
  return number;
}
function start(binary, args, env = {}) {
  const child = spawn(binary, args, {
    cwd: root,
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const item = { child, exited: false, code: null, output: '' };
  children.add(item);
  child.stdout.on('data', (chunk) => {
    item.output = (item.output + chunk).slice(-64_000);
  });
  // Drain diagnostics; media tools can echo credential-bearing URLs.
  child.stderr.resume();
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
async function until(predicate, label, timeout = 15_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    checkCancellation();
    if (await predicate()) return;
    await delay(150);
  }
  throw new Error(`Timed out: ${label}`);
}
async function stop(item) {
  if (!item || item.exited) return;
  item.child.kill('SIGTERM');
  await Promise.race([item.done, delay(4000)]);
  if (!item.exited) {
    item.child.kill('SIGKILL');
    await Promise.race([item.done, delay(2000)]);
  }
  assert.ok(item.exited, 'Owned process did not exit');
}
async function fixture(kind, mediaPort, apiPort) {
  const name = `scorebug-worker-${kind}-${randomUUID()}`;
  const config = join(directory, `${kind}.yml`);
  await copyFile(new URL(`../infra/local/${kind}.yml`, import.meta.url), config);
  const result = await command(
    'docker',
    [
      'run',
      '-d',
      '--name',
      name,
      '-p',
      `127.0.0.1:${apiPort}:9997`,
      '-p',
      `127.0.0.1:${mediaPort}:${kind === 'ingest' ? '8890/udp' : '1935'}`,
      '-v',
      `${config}:/mediamtx.yml:ro`,
      'bluenviron/mediamtx:1.21.0',
    ],
    120_000,
  );
  names.push(name);
  assert.ok(result.ok, 'Owned fixture could not start');
  await until(async () => {
    try {
      return (
        await fetch(`http://127.0.0.1:${apiPort}/v3/config/paths/list`, {
          headers,
          signal: AbortSignal.timeout(1000),
        })
      ).ok;
    } catch {
      return false;
    }
  }, `${kind} readiness`);
}
async function request(path, token, body) {
  const response = await fetch(`${api.baseURL}${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(5000),
  });
  assert.ok(response.ok, `Native request HTTP ${response.status}`);
  return response.json();
}
async function mediaCommand(binary, args, label, timeout = 20_000) {
  const result = await command(binary, args, timeout);
  assert.ok(result.ok, `${label} failed`);
  return result.stdout;
}
async function frameCodes(path, label) {
  const samples = join(directory, `${label}-codes.raw`);
  await mediaCommand(
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
      samples,
    ],
    `${label} source frame codes`,
  );
  return decodeFrameCodes(await readFile(samples));
}

try {
  await mkdir(artifact, { recursive: true });
  const profileScore = join(directory, 'profile-score.txt');
  await writeFile(profileScore, 'HOME 0-0 AWAY');
  const duplicated = join(directory, 'duplicated.mp4');
  await mediaCommand(
    ffmpeg,
    [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=320x180:rate=12',
      '-t',
      '3',
      '-vf',
      `${sourceFrameCodeFilter},fps=30`,
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-b:v',
      '3000k',
      duplicated,
    ],
    'deliberately duplicated source',
  );
  const duplicateCodes = await frameCodes(duplicated, 'duplicated');
  assert.equal(duplicateCodes.length, 90);
  assert.equal(new Set(duplicateCodes).size, 36, 'Fresh-frame check accepted duplicated frames');
  console.log('Frame-code check rejects 12fps motion disguised as 30fps output.');
  for (const rate of [60, 25]) {
    const source = join(directory, `source-${rate}.mp4`);
    await mediaCommand(
      ffmpeg,
      [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        `testsrc2=size=320x180:rate=${rate}`,
        '-f',
        'lavfi',
        '-i',
        'sine=sample_rate=48000',
        '-t',
        '2',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        '-c:a',
        'aac',
        source,
      ],
      'profile source',
    );
    const destination = join(directory, `profile-${rate}.flv`);
    await mediaCommand(
      ffmpeg,
      buildFfmpegArgs({
        gameId: 'profile',
        pullUrl: source,
        publishUrl: destination,
        scoreFile: profileScore,
        nvenc: false,
        encoder,
        fontPath: font,
        profile: { width: 1280, height: 720, fps: 30, bitrateKbps: 3000 },
      }),
      'profile cadence',
    );
    const probe = JSON.parse(
      await mediaCommand(
        ffprobe,
        ['-v', 'error', '-select_streams', 'v:0', '-show_streams', '-of', 'json', destination],
        'profile rate probe',
      ),
    );
    const [numerator, denominator] = probe.streams[0].avg_frame_rate.split('/').map(Number);
    assert.equal(
      numerator / denominator,
      Math.min(rate, 30),
      'Profile changed lower input cadence or exceeded cap',
    );
  }
  console.log('Real encoder cadence: 60fps capped at 30; 25fps preserved.');
  const ingestPort = await port(true);
  const relayPort = await port();
  const sinkPort = await port();
  const sinkApiPort = await port();
  await fixture('ingest', ingestPort, relayPort);
  await fixture('sink', sinkPort, sinkApiPort);
  const environment = {
    RELAY_API_URL: `http://127.0.0.1:${relayPort}`,
    RELAY_API_USERNAME: 'qa-admin',
    RELAY_API_PASSWORD: 'qa-admin-not-production',
    INGEST_HOST: '127.0.0.1',
    INGEST_PORT: String(ingestPort),
  };
  const database = join(directory, 'matches.sqlite');
  api = await startScoringTestServer(database, environment);
  const apiPort = new URL(api.baseURL).port;
  const matchId = randomUUID();
  const team = (shortName) => ({ name: shortName, shortName, color: '#123456' });
  const created = await request('/v1/matches', scoringTestToken, {
    id: matchId,
    deviceId: 'scorer',
    teams: { home: team('HOME'), away: team('AWAY') },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const capture = await request(`/v1/matches/${matchId}/join`, scoringTestToken, {
    deviceId: 'camera',
    role: 'capture',
  });
  await request(`/v1/matches/${matchId}/media/recordings`, capture.credential.token, {
    recordingId: 'archive',
    sequence: 0,
    status: 'recording',
    startedAt: new Date().toISOString(),
  });
  await request(`/v1/matches/${matchId}/media/commands`, scoringTestToken, {
    commandId: 'broadcast',
    gameId: matchId,
    expectedGeneration: 0,
    issuedAt: new Date().toISOString(),
    operation: {
      type: 'start',
      selection: {
        workerId: 'mac',
        outputId: 'local-sink',
        captureDeviceId: 'camera',
        recordingId: 'archive',
      },
    },
  });
  const access = await request(`/v1/matches/${matchId}/media/publish`, capture.credential.token, {
    recordingId: 'archive',
    generation: 1,
  });
  const outputUrl = `rtmp://127.0.0.1:${sinkPort}/live/fixture?user=qa-worker&pass=qa-output-not-production`;
  const startWorker = () =>
    start(
      process.execPath,
      [
        '--import',
        './apps/home-daemon/node_modules/tsx/dist/loader.mjs',
        'apps/home-daemon/src/index.ts',
      ],
      {
        CONTROL_PLANE_URL: api.baseURL,
        HOME_TOKEN: 'qa-home-token-not-production',
        WORKER_ID: 'mac',
        OUTPUT_ID: 'local-sink',
        OUTPUT_URL: outputUrl,
        ENCODER: encoder,
        VIDEO_PROFILE: '720p30',
        SCORE_DIR: directory,
        FFMPEG_PATH: ffmpeg,
        FFPROBE_PATH: ffprobe,
        FONT_PATH: font,
        LOG_LEVEL: 'info',
      },
    );
  const sinkState = async () => {
    const response = await fetch(`http://127.0.0.1:${sinkApiPort}/v3/paths/get/live/fixture`, {
      headers,
      signal: AbortSignal.timeout(2000),
    });
    if (response.status === 404) return { ready: false };
    assert.ok(response.ok, 'Sink observation failed');
    return response.json();
  };
  const ready = async () => {
    await until(
      async () => {
        assert.ok(!worker.exited, 'Worker exited before output');
        const state = await sinkState();
        return state.ready && state.bytesReceived > 0 && worker.output.includes('producing_output');
      },
      'real worker output',
      25_000,
    );
  };
  const clip = async (label) => {
    const path = join(artifact, `${label}.mp4`);
    await mediaCommand(
      ffmpeg,
      [
        '-v',
        'error',
        '-y',
        '-i',
        outputUrl,
        '-t',
        '3',
        '-map',
        '0:v:0',
        '-map',
        '0:a:0',
        '-c',
        'copy',
        path,
      ],
      `${label} capture`,
    );
    const probe = JSON.parse(
      await mediaCommand(
        ffprobe,
        ['-v', 'error', '-count_frames', '-show_streams', '-of', 'json', path],
        `${label} probe`,
      ),
    );
    const video = probe.streams.find((s) => s.codec_type === 'video');
    assert.equal(video?.width, 1280);
    assert.equal(video?.height, 720);
    assert.ok(probe.streams.some((s) => s.codec_type === 'audio'));
    const fps = Number(video.nb_read_frames) / Number(video.duration);
    assert.ok(fps >= 24, `${label} measured only ${fps.toFixed(2)} decoded fps`);
    await mediaCommand(
      ffmpeg,
      ['-v', 'error', '-xerror', '-i', path, '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'],
      `${label} full decode`,
    );
    const unique = new Set(await frameCodes(path, label)).size;
    assert.ok(unique / Number(video.duration) >= 24, `${label} repeated test pattern frames`);
    await mediaCommand(
      ffmpeg,
      [
        '-v',
        'error',
        '-y',
        '-ss',
        '1',
        '-i',
        path,
        '-frames:v',
        '1',
        join(artifact, `${label}.png`),
      ],
      `${label} image`,
    );
    await mediaCommand(
      ffmpeg,
      [
        '-v',
        'error',
        '-y',
        '-ss',
        '1',
        '-i',
        path,
        '-frames:v',
        '1',
        '-vf',
        'crop=500:80:0:620,format=gray',
        '-f',
        'rawvideo',
        join(directory, `${label}.raw`),
      ],
      `${label} overlay pixels`,
    );
    console.log(`${label}: decoded ${fps.toFixed(2)} fps, audio present, fresh moving frames.`);
    return readFile(join(directory, `${label}.raw`));
  };
  worker = startWorker();
  await until(() => worker.output.includes('waiting_source'), 'worker waits for source');
  assert.equal((await sinkState()).ready, false);
  const publisher = start(ffmpeg, [
    '-v',
    'error',
    '-re',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=1280x720:rate=30',
    '-re',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=1000:sample_rate=48000',
    '-t',
    '300',
    '-vf',
    `drawbox=x=0:y=600:w=iw:h=120:color=black:t=fill,${sourceFrameCodeFilter}`,
    '-c:v',
    'libx264',
    '-preset',
    'ultrafast',
    '-tune',
    'zerolatency',
    '-g',
    '30',
    '-pix_fmt',
    'yuv420p',
    '-b:v',
    '3000k',
    '-c:a',
    'aac',
    '-f',
    'mpegts',
    access.publishUrl,
  ]);
  await ready();
  const initial = await clip('initial-zero');
  const score = await request(`/v1/matches/${matchId}/commands`, created.credential.token, {
    commandId: 'point',
    gameId: matchId,
    deviceId: 'scorer',
    expectedRevision: 1,
    scorerEpoch: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'award_point', side: 'home' },
  });
  await until(
    async () => (await readFile(join(directory, 'score.txt'), 'utf8')).includes('HOME 1-0 AWAY'),
    'authoritative score update',
  );
  const changed = await clip('point-one');
  let changedPixels = 0;
  for (let i = 0; i < initial.length; i++)
    if (initial[i] > 180 !== changed[i] > 180) changedPixels++;
  assert.ok(changedPixels > 20, 'Score update did not change burned-in overlay pixels');
  assert.equal(
    worker.output.split('ffmpeg_spawning').length - 1,
    1,
    'Score update restarted encoder',
  );
  console.log('Native point updated overlay pixels without restarting the encoder.');
  await stop(worker);
  assert.equal(worker.code, 0, 'Worker did not shut down gracefully');
  await until(async () => !(await sinkState()).ready, 'worker shutdown removes output');
  worker = startWorker();
  await ready();
  await clip('worker-restarted');
  await api.stop();
  await until(async () => !(await sinkState()).ready, 'control lease stops stale output', 10_000);
  assert.ok(!publisher.exited, 'Control outage stopped the independent source');
  api = await startScoringTestServer(database, { ...environment, PORT: apiPort });
  await ready();
  await clip('api-recovered');
  await request(`/v1/matches/${matchId}/commands`, created.credential.token, {
    commandId: 'end',
    gameId: matchId,
    deviceId: 'scorer',
    expectedRevision: score.snapshot.revision,
    scorerEpoch: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'end_match', reason: 'Local media validation complete' },
  });
  await until(async () => !(await sinkState()).ready, 'match end stops output');
  await until(() => publisher.exited, 'match end revokes input');
  const media = await request(`/v1/matches/${matchId}/media`, capture.credential.token);
  assert.equal(media.snapshot.recordings[0].status, 'recording');
  console.log('Worker restart, API outage lease, recovery, and match-end stop verified.');
} catch (error) {
  console.error(error.message);
  if (worker) console.error(worker.output);
  process.exitCode = 1;
} finally {
  const cleanup = async (action, label) => {
    try {
      await action();
    } catch {
      console.error(`Owned cleanup failed: ${label}`);
      process.exitCode = 1;
    }
  };
  await cleanup(() => stop(worker), 'worker');
  await cleanup(async () => {
    await api?.stop();
  }, 'API');
  for (const child of [...children]) await cleanup(() => stop(child), 'child process');
  for (const name of names) {
    if (!(await command('docker', ['rm', '-f', name], 30_000)).ok) {
      console.error(`Owned container cleanup failed: ${name}`);
      process.exitCode = 1;
    }
  }
  await cleanup(() => rm(directory, { recursive: true, force: true }), 'temporary files');
}
if (!process.exitCode)
  console.log(`PASS: ${encoder} native worker local media; clips in ${artifact}`);
