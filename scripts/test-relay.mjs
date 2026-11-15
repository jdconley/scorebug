import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { createSocket } from 'node:dgram';
import { setTimeout as delay } from 'node:timers/promises';
import { mediaTools, command } from './media-tools.mjs';
import { cancellation } from './cancellation.mjs';
import { startScoringTestServer, scoringTestToken } from './scoring-test-server.mjs';
import { IngestRelay, deriveIngestGrant } from '../apps/control-plane/src/ingest.ts';

const checkCancellation = cancellation();
const name = `scorebug-relay-${randomUUID()}`;
const directory = await mkdtemp(join(tmpdir(), 'scorebug-relay-'));
const owned = new Set();
const processes = [];
let api;
const { ffmpeg, ffprobe } = mediaTools();
async function availablePort(protocol) {
  const socket = protocol === 'udp' ? createSocket('udp4') : createServer();
  await new Promise((resolve, reject) => {
    socket.once('error', reject);
    if (protocol === 'udp') socket.bind(0, '127.0.0.1', resolve);
    else socket.listen(0, '127.0.0.1', resolve);
  });
  const port = socket.address().port;
  await new Promise((resolve) => socket.close(resolve));
  return port;
}
function start(args) {
  const child = spawn(ffmpeg, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  owned.add(child);
  const result = {
    child,
    exited: false,
    code: null,
    signal: null,
    frames: false,
    frameCount: 0,
    stderr: '',
  };
  child.stderr.on('data', (chunk) => {
    result.stderr = (result.stderr + chunk.toString()).slice(-4096);
  });
  let progress = '';
  child.stdout.on('data', (chunk) => {
    progress = (progress + chunk.toString()).slice(-2048);
    for (const match of progress.matchAll(/(?:^|\n)frame=\s*(\d+)\s*\n/g)) {
      result.frameCount = Math.max(result.frameCount, Number(match[1]));
      result.frames ||= result.frameCount > 0;
    }
  });
  result.done = new Promise((resolve) => {
    const finish = (code, signal) => {
      if (result.exited) return;
      result.exited = true;
      result.code = code;
      result.signal = signal;
      owned.delete(child);
      resolve(result);
    };
    child.once('error', () => finish(null, 'spawn-error'));
    child.once('exit', finish);
  });
  processes.push(result);
  return result;
}
async function until(predicate, label, timeout = 10_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    checkCancellation();
    if (await predicate()) return;
    await delay(150);
  }
  throw new Error(`Timed out: ${label}`);
}
const publishArgs = (url) => [
  '-hide_banner',
  '-loglevel',
  'error',
  '-re',
  '-f',
  'lavfi',
  '-i',
  'testsrc2=size=640x360:rate=30',
  '-re',
  '-f',
  'lavfi',
  '-i',
  'sine=frequency=1000:sample_rate=48000',
  '-t',
  '90',
  '-c:v',
  'libx264',
  '-preset',
  'ultrafast',
  '-tune',
  'zerolatency',
  '-pix_fmt',
  'yuv420p',
  '-g',
  '30',
  '-b:v',
  '1000k',
  '-c:a',
  'aac',
  '-b:a',
  '96k',
  '-f',
  'mpegts',
  url,
];
const readArgs = (url, destination = '-') => [
  '-hide_banner',
  '-loglevel',
  'error',
  '-i',
  url,
  '-t',
  '3',
  '-map',
  '0:v:0',
  '-map',
  '0:a:0',
  ...(destination === '-' ? ['-f', 'null', '-'] : ['-c', 'copy', '-f', 'mpegts', destination]),
];
function passphrase(url, value) {
  const result = new URL(url);
  result.searchParams.set('passphrase', value);
  return result.toString();
}
async function denied(args, label) {
  const child = start(args);
  await until(() => child.exited, label, 8_000);
  if (child.code === 0 || child.signal)
    throw new Error(`${label}: did not get a normal rejected connection exit`);
}
try {
  await copyFile(
    new URL('../infra/local/ingest.yml', import.meta.url),
    join(directory, 'mediamtx.yml'),
  );
  // Explicit ephemeral ports stay fixed when Docker restarts the same container.
  // If another process claims one before Docker binds, startup fails safely.
  const apiPort = await availablePort('tcp');
  const srtPort = await availablePort('udp');
  const run = await command(
    'docker',
    [
      'run',
      '-d',
      '--name',
      name,
      '-p',
      `127.0.0.1:${apiPort}:9997`,
      '-p',
      `127.0.0.1:${srtPort}:8890/udp`,
      '-v',
      `${join(directory, 'mediamtx.yml')}:/mediamtx.yml:ro`,
      'scorebug/ingest:drain-v1',
    ],
    120_000,
  );
  checkCancellation();
  if (!run.ok) throw new Error('Owned relay container could not start');
  const inspected = await command('docker', [
    'inspect',
    '--format',
    '{{json .NetworkSettings.Ports}}',
    name,
  ]);
  if (!inspected.ok) throw new Error('Owned relay ports unavailable');
  const ports = JSON.parse(inspected.stdout);
  const apiUrl = `http://127.0.0.1:${ports['9997/tcp'][0].HostPort}`;
  const relay = new IngestRelay({
    apiUrl,
    username: 'qa-admin',
    password: 'qa-admin-not-production',
  });
  const selection = {
    workerId: 'mac',
    outputId: 'local-sink',
    captureDeviceId: 'fixture',
    recordingId: 'archive',
  };
  const grant = deriveIngestGrant(
    'qa-relay-installation-not-production',
    randomUUID(),
    selection,
    1,
    '127.0.0.1',
    Number(ports['8890/udp'][0].HostPort),
  );
  await until(async () => {
    try {
      await relay.ensure(grant);
      return true;
    } catch {
      return false;
    }
  }, 'relay provisioning');
  await relay.ensure(grant);
  const anonymous = await fetch(`${apiUrl}/v3/config/paths/list`, {
    signal: AbortSignal.timeout(2000),
  });
  if (anonymous.status !== 401) throw new Error('Relay management allowed anonymous access');
  if ((await relay.status(grant.path)).ready)
    throw new Error('Relay claimed readiness before source');
  await denied(
    publishArgs(passphrase(grant.publishUrl, grant.readPassphrase)),
    'reader credential publishing',
  );
  await denied(
    publishArgs(passphrase(grant.publishUrl, 'incorrect-passphrase')),
    'incorrect publishing credential',
  );
  console.log('Relay provisioning and rejected publishing credentials verified.');
  const publisher = start(publishArgs(grant.publishUrl));
  await until(async () => {
    if (publisher.exited)
      throw new Error(
        `Valid publisher exited before relay readiness (code ${publisher.code}, signal ${publisher.signal}): ${publisher.stderr.trim()}`,
      );
    const state = await relay.status(grant.path);
    return state.ready && state.tracks.includes('H264') && state.tracks.includes('MPEG-4 Audio');
  }, 'real audio/video source');
  await denied(publishArgs(grant.publishUrl), 'second publisher takeover');
  await denied(
    readArgs(passphrase(grant.readUrl, grant.publishPassphrase)),
    'publisher credential reading',
  );
  await denied(
    readArgs(passphrase(grant.readUrl, 'incorrect-passphrase')),
    'incorrect reading credential',
  );
  const recording = join(directory, 'received.ts');
  const received = start(readArgs(grant.readUrl, recording));
  await until(() => received.exited, 'authorized read', 15_000);
  if (received.code !== 0) throw new Error('Authorized reader failed');
  const probe = await command(ffprobe, ['-v', 'error', '-show_streams', '-of', 'json', recording]);
  if (!probe.ok) throw new Error('Received media probe failed');
  const streams = JSON.parse(probe.stdout).streams;
  if (
    !streams.some((s) => s.codec_type === 'video' && s.width === 640 && s.height === 360) ||
    !streams.some((s) => s.codec_type === 'audio')
  )
    throw new Error('Received media lacks expected audio/video');
  const decoded = await command(ffmpeg, [
    '-v',
    'error',
    '-xerror',
    '-i',
    recording,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0',
    '-f',
    'null',
    '-',
  ]);
  if (!decoded.ok) throw new Error('Received media did not fully decode');
  console.log('Authorized SRT audio/video received, probed, and fully decoded.');
  const liveReader = start([
    '-hide_banner',
    '-nostats',
    '-progress',
    'pipe:1',
    '-loglevel',
    'error',
    '-i',
    grant.readUrl,
    '-f',
    'null',
    '-',
  ]);
  await until(() => {
    if (liveReader.exited) throw new Error('Reader exited before revocation');
    return liveReader.frames;
  }, 'live reader output before revocation');
  const framesBeforeDrain = liveReader.frameCount;
  await relay.retire(grant.path);
  await Promise.all([
    denied(publishArgs(grant.publishUrl), 'draining publisher credential'),
    denied(readArgs(grant.readUrl), 'draining reader credential'),
  ]);
  await until(
    () => {
      if (liveReader.exited || publisher.exited) throw new Error('Drain cut accepted media early');
      return liveReader.frameCount >= framesBeforeDrain + 15;
    },
    'accepted media continues after admission revocation',
    3000,
  );
  await until(
    () => liveReader.exited && publisher.exited,
    'relay drain deadline disconnects existing clients',
  );
  await relay.remove(grant.path);
  await denied(publishArgs(grant.publishUrl), 'revoked publishing credential');
  await denied(readArgs(grant.readUrl), 'revoked reading credential');
  if ((await relay.status(grant.path)).ready) throw new Error('Revoked path remains ready');
  console.log(
    'Drain rejects new connections, preserves accepted media, and enforces its deadline.',
  );
  const environment = {
    RELAY_API_URL: apiUrl,
    RELAY_API_USERNAME: 'qa-admin',
    RELAY_API_PASSWORD: 'qa-admin-not-production',
    INGEST_HOST: '127.0.0.1',
    INGEST_PORT: ports['8890/udp'][0].HostPort,
  };
  const database = join(directory, 'matches.sqlite');
  // Startup must remove a crash-orphaned path while preserving other installations.
  const orphan = deriveIngestGrant(
    scoringTestToken,
    randomUUID(),
    selection,
    1,
    '127.0.0.1',
    Number(ports['8890/udp'][0].HostPort),
  );
  await relay.ensure(orphan);
  await relay.ensure(grant);
  api = await startScoringTestServer(database, environment);
  await until(
    async () => !(await relay.list(orphan.path.slice(0, 26))).includes(orphan.path),
    'startup orphan revocation',
  );
  if (!(await relay.list(grant.path.slice(0, 26))).includes(grant.path))
    throw new Error('Reconciliation removed another installation path');
  await relay.remove(grant.path);
  const request = async (path, token, body, rejection) => {
    const response = await fetch(`${api.baseURL}${path}`, {
      method: body ? 'POST' : 'GET',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(5000),
    });
    if (rejection) {
      assert.equal(response.status, 409);
      assert.deepEqual(await response.json(), { error: rejection });
      return;
    }
    if (!response.ok)
      throw Object.assign(new Error(`Native relay request failed: HTTP ${response.status}`), {
        status: response.status,
      });
    return response.json();
  };
  console.log('Startup orphan cleanup and installation isolation verified.');
  const matchId = randomUUID();
  const team = { name: 'Relay test', shortName: 'QA', color: '#123456' };
  const created = await request('/v1/matches', scoringTestToken, {
    id: matchId,
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const capture = await request(`/v1/matches/${matchId}/join`, scoringTestToken, {
    deviceId: 'phone',
    role: 'capture',
  });
  await request(`/v1/matches/${matchId}/media/recordings`, capture.credential.token, {
    recordingId: 'native-archive',
    sequence: 0,
    status: 'recording',
    startedAt: new Date().toISOString(),
  });
  await request(`/v1/matches/${matchId}/media/commands`, scoringTestToken, {
    commandId: 'start',
    gameId: matchId,
    expectedGeneration: 0,
    issuedAt: new Date().toISOString(),
    operation: {
      type: 'start',
      selection: {
        workerId: 'mac',
        outputId: 'local-sink',
        captureDeviceId: 'phone',
        recordingId: 'native-archive',
      },
    },
  });
  const access = await request(`/v1/matches/${matchId}/media/publish`, capture.credential.token, {
    recordingId: 'native-archive',
    generation: 1,
  });
  let nativePublisher = start(publishArgs(access.publishUrl));
  const workerToken = 'qa-home-token-not-production';
  await until(async () => {
    if (nativePublisher.exited) throw new Error('Native authorized publisher exited');
    return (await request('/v1/worker/connection?workerId=mac', workerToken)).connection?.source
      .ready;
  }, 'native source readiness');
  const beforeAPIRestart = (await request('/v1/worker/connection?workerId=mac', workerToken))
    .connection.source.inboundBytes;
  await api.stop();
  api = await startScoringTestServer(database, environment);
  const restored = await request(`/v1/matches/${matchId}/media/publish`, capture.credential.token, {
    recordingId: 'native-archive',
    generation: 1,
  });
  if (restored.publishUrl !== access.publishUrl || nativePublisher.exited)
    throw new Error('API restart interrupted or changed current publishing access');
  await until(async () => {
    if (nativePublisher.exited) throw new Error('Publisher disconnected after API restart');
    const connection = (await request('/v1/worker/connection?workerId=mac', workerToken))
      .connection;
    return connection?.source.ready && connection.source.inboundBytes > beforeAPIRestart;
  }, 'continued source bytes after API restart');
  console.log('API restart preserved current publishing access.');
  const restarted = await command('docker', ['restart', name], 30_000);
  if (!restarted.ok) throw new Error('Owned relay restart failed');
  const restartedPorts = await command('docker', [
    'inspect',
    '--format',
    '{{json .NetworkSettings.Ports}}',
    name,
  ]);
  if (!restartedPorts.ok) throw new Error('Restarted relay ports unavailable');
  if (JSON.stringify(JSON.parse(restartedPorts.stdout)) !== JSON.stringify(ports))
    throw new Error('Owned relay published ports changed during restart');
  console.log('Owned relay restarted; waiting for management and path recovery.');
  await until(() => nativePublisher.exited, 'publisher disconnect during relay restart');
  const nativePath = new URL(access.publishUrl).searchParams
    .get('streamid')
    .slice('publish:'.length);
  await until(async () => {
    try {
      return (await relay.list(nativePath.slice(0, 26))).includes(nativePath);
    } catch (error) {
      // Docker reports the process started before its HTTP listener is ready.
      if (error.message === 'relay_unavailable') return false;
      throw error;
    }
  }, 'automatic path restoration after relay restart');
  nativePublisher = start(publishArgs(access.publishUrl));
  await until(async () => {
    try {
      return (await request('/v1/worker/connection?workerId=mac', workerToken)).connection?.source
        .ready;
    } catch (error) {
      // Management/path recovery can precede source status availability. Keep the
      // same bounded restart wait; authentication and other failures still abort.
      if (error.status === 503) return false;
      throw error;
    }
  }, 'source reconnect after relay restart');
  const oldConnection = (await request('/v1/worker/connection?workerId=mac', workerToken))
    .connection;
  const firstSession = await request('/v1/worker/sessions', workerToken, {
    workerId: 'mac',
    runId: 'first-checked-worker',
  });
  const firstReport = {
    workerId: 'mac',
    sessionId: firstSession.sessionId,
    sequence: 1,
    observation: {
      gameId: matchId,
      generation: 1,
      state: 'producing_output',
      reason: null,
      attempt: 1,
      frame: 12,
      outTimeUs: 400_000,
      scoreRevision: 1,
    },
  };
  await request('/v1/worker/observations', workerToken, firstReport);
  const status = async () =>
    (await request(`/v1/matches/${matchId}/media/status`, capture.credential.token)).status;
  const firstStatus = await status();
  assert.equal(firstStatus.state, 'producing_output');
  assert(firstStatus.workerEpoch);
  for (const [expectedGeneration, operation] of [
    [1, { type: 'stop' }],
    [
      2,
      {
        type: 'start',
        selection: {
          workerId: 'mac',
          outputId: 'local-sink',
          captureDeviceId: 'phone',
          recordingId: 'native-archive',
        },
      },
    ],
  ]) {
    const outcome = await request(`/v1/matches/${matchId}/media/commands`, scoringTestToken, {
      commandId: `generation-${expectedGeneration}`,
      gameId: matchId,
      expectedGeneration,
      issuedAt: new Date().toISOString(),
      operation,
    });
    assert.equal(outcome.accepted, true);
    assert.equal(outcome.snapshot.broadcast.generation, expectedGeneration + 1);
  }
  const unreported = await status();
  assert.equal(unreported.generation, 3);
  assert.equal(unreported.state, 'unknown');
  assert.equal(unreported.observation, null);
  await request('/v1/worker/observations', workerToken, firstReport, 'broadcast_changed');
  await request(
    `/v1/matches/${matchId}/media/publish`,
    capture.credential.token,
    { recordingId: 'native-archive', generation: 1 },
    'broadcast_changed',
  );
  const replacement = await request(
    `/v1/matches/${matchId}/media/publish`,
    capture.credential.token,
    { recordingId: 'native-archive', generation: 3 },
  );
  assert.notEqual(replacement.publishUrl, access.publishUrl);
  await Promise.all([
    denied(publishArgs(access.publishUrl), 'old generation publisher'),
    denied(readArgs(oldConnection.readUrl), 'old generation late reader'),
  ]);
  await until(() => nativePublisher.exited, 'old generation drain ends existing publisher');
  nativePublisher = start(publishArgs(replacement.publishUrl));
  let currentConnection;
  await until(async () => {
    currentConnection = (await request('/v1/worker/connection?workerId=mac', workerToken))
      .connection;
    return currentConnection?.generation === 3 && currentConnection.source.ready;
  }, 'replacement generation source');
  assert.notEqual(currentConnection.readUrl, oldConnection.readUrl);
  const secondSession = await request('/v1/worker/sessions', workerToken, {
    workerId: 'mac',
    runId: 'replacement-checked-worker',
  });
  assert.equal((await status()).state, 'unknown');
  await request('/v1/worker/observations', workerToken, firstReport, 'worker_session_retired');
  const replacementReport = {
    ...firstReport,
    sessionId: secondSession.sessionId,
    observation: { ...firstReport.observation, generation: 3 },
  };
  await request('/v1/worker/observations', workerToken, replacementReport);
  const currentStatus = await status();
  assert.equal(currentStatus.state, 'producing_output');
  assert.notEqual(currentStatus.workerEpoch, firstStatus.workerEpoch);
  await request('/v1/worker/observations', workerToken, firstReport, 'worker_session_retired');
  assert.equal((await status()).workerEpoch, currentStatus.workerEpoch);
  // Attach only after independently observing continuing source bytes. The reader
  // really decodes both tracks; the posted worker reports above test control scope.
  const beforeLateReader = currentConnection.source.inboundBytes;
  await until(
    async () =>
      (await request('/v1/worker/connection?workerId=mac', workerToken)).connection.source
        .inboundBytes > beforeLateReader,
    'source advances before late reader',
  );
  const lateReader = start(readArgs(currentConnection.readUrl));
  await until(() => lateReader.exited, 'new generation late reader decodes', 15_000);
  assert.equal(lateReader.code, 0);
  assert.equal(lateReader.signal, null);
  assert.equal(nativePublisher.exited, false);
  console.log(
    'Broadcast and worker replacement reject stale reports/credentials; late current reader decodes A/V.',
  );
  const endingMatch = (await request(`/v1/matches/${matchId}`, created.credential.token)).snapshot;
  await request(`/v1/matches/${matchId}/commands`, created.credential.token, {
    commandId: 'end',
    gameId: matchId,
    deviceId: 'scorer',
    expectedRevision: endingMatch.revision,
    scorerEpoch: endingMatch.scorer.epoch,
    issuedAt: new Date().toISOString(),
    operation: { type: 'end_match', reason: 'Relay validation finished' },
  });
  // No direct adapter delete: the production reconciliation loop must revoke it.
  await until(() => nativePublisher.exited, 'match end automatically revokes relay publishing');
  await denied(publishArgs(replacement.publishUrl), 'ended match credential');
  const ended = await request(`/v1/matches/${matchId}/media`, capture.credential.token);
  if (ended.snapshot.recordings[0]?.status !== 'recording')
    throw new Error('Match end changed independent recording metadata');
  console.log(
    'Native access, orphan cleanup, API and relay restart recovery, and automatic match-end revocation verified.',
  );
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await api?.stop();
  for (const child of owned) child.kill('SIGTERM');
  await delay(300);
  for (const child of owned) child.kill('SIGKILL');
  if (owned.size)
    await Promise.race([Promise.all(processes.map((item) => item.done)), delay(2000)]);
  if (owned.size) {
    console.error('Owned media process did not exit during cleanup');
    process.exitCode = 1;
  }
  const removed = await command('docker', ['rm', '-f', name], 30_000);
  if (!removed.ok) {
    console.error(`Could not remove owned relay ${name}`);
    process.exitCode = 1;
  }
  await rm(directory, { recursive: true, force: true });
}
if (!process.exitCode)
  console.log(
    'PASS: isolated real SRT credentials, media decode, and revocation; owned resources removed.',
  );
