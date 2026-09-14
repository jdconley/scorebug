import { randomUUID } from 'node:crypto';
import { mkdtemp, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { mediaTools, command } from './media-tools.mjs';
import { cancellation } from './cancellation.mjs';
import { IngestRelay, deriveIngestGrant } from '../apps/control-plane/src/ingest.ts';

const checkCancellation = cancellation();
const name = `scorebug-relay-${randomUUID()}`;
const directory = await mkdtemp(join(tmpdir(), 'scorebug-relay-'));
const owned = new Set();
const processes = [];
const { ffmpeg, ffprobe } = mediaTools();
function start(args) {
  const child = spawn(ffmpeg, args, { stdio: ['ignore', 'pipe', 'ignore'] });
  owned.add(child);
  const result = { child, exited: false, code: null, signal: null, frames: false };
  let progress = '';
  child.stdout.on('data', (chunk) => {
    progress = (progress + chunk.toString()).slice(-2048);
    if (/(?:^|\n)frame=\s*[1-9]\d*\s*\n/.test(progress)) result.frames = true;
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
  const run = await command(
    'docker',
    [
      'run',
      '-d',
      '--name',
      name,
      '-p',
      '127.0.0.1::9997',
      '-p',
      '127.0.0.1::8890/udp',
      '-v',
      `${join(directory, 'mediamtx.yml')}:/mediamtx.yml:ro`,
      'bluenviron/mediamtx:1.21.0',
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
    if (publisher.exited) throw new Error('Valid publisher exited before relay readiness');
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
  await relay.remove(grant.path);
  await until(
    () => liveReader.exited && publisher.exited,
    'revocation disconnects existing clients',
  );
  await relay.remove(grant.path);
  await denied(publishArgs(grant.publishUrl), 'revoked publishing credential');
  await denied(readArgs(grant.readUrl), 'revoked reading credential');
  if ((await relay.status(grant.path)).ready) throw new Error('Revoked path remains ready');
  console.log('Revocation disconnects existing clients and rejects reuse of both credentials.');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
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
