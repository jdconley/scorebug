import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createReadStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { mediaTools } from './media-tools.mjs';
import { startReconnectingRTMPRecorder } from './reconnecting-rtmp-recorder.mjs';

const execute = promisify(execFile);
assert.equal(process.argv.length, 4, 'Use --input PATH to prepared representative footage');
assert.equal(process.argv[2], '--input');
const input = resolve(process.argv[3]);
const root = resolve('artifacts/qa');
await mkdir(root, { recursive: true });
const artifact = await mkdtemp(join(root, 'reconnecting-rtmp-'));
console.log(`Reconnecting RTMP validation: ${artifact}`);
const commands = [];
async function digest(path) {
  const h = createHash('sha256');
  for await (const chunk of createReadStream(path)) h.update(chunk);
  return h.digest('hex');
}
async function save(name, value) {
  await writeFile(join(artifact, name), JSON.stringify(value, null, 2) + '\n', { flag: 'wx' });
}
async function run(name, file, args) {
  const event = { name, file, args, joined: false };
  commands.push(event);
  try {
    const result = await execute(file, args, {
      timeout: 30000,
      killSignal: 'SIGKILL',
      maxBuffer: 4 * 1024 * 1024,
    });
    Object.assign(event, { joined: true, exitCode: 0, signal: null });
    await writeFile(join(artifact, name + '.stdout'), result.stdout, { flag: 'wx' });
    await writeFile(join(artifact, name + '.stderr'), result.stderr, { flag: 'wx' });
    return result.stdout;
  } catch (error) {
    Object.assign(event, {
      joined: true,
      exitCode: Number.isInteger(error.code) ? error.code : null,
      signal: error.signal ?? null,
      errorCode: typeof error.code === 'string' ? error.code : null,
    });
    throw new Error(`Owned command failed: ${name}`, { cause: error });
  }
}
const paths = [
  input,
  import.meta.filename,
  ...[
    'reconnecting-rtmp-recorder.mjs',
    'direct-rtmp-recorder.mjs',
    'recorder-packet-timing.mjs',
    'media-tools.mjs',
  ].map((f) => resolve('scripts', f)),
];
const hashes = Object.fromEntries(await Promise.all(paths.map(async (p) => [p, await digest(p)])));
const { ffmpeg, ffprobe } = mediaTools();
let recorder, report;
try {
  recorder = await startReconnectingRTMPRecorder({ artifact, ffmpeg, port: 0 });
  const source = JSON.parse(
    await run('input-probe', ffprobe, [
      '-v',
      'error',
      '-show_format',
      '-show_streams',
      '-of',
      'json',
      input,
    ]),
  );
  assert(Number(source.format.duration) >= 34, 'Need at least34s of prepared footage');
  const publisherFrames = [];
  for (const [index, start] of [10, 30].entries()) {
    const progress = await run(`publish-${index + 1}`, ffmpeg, [
      '-nostdin',
      '-v',
      'error',
      '-re',
      '-ss',
      String(start),
      '-i',
      input,
      '-t',
      '3',
      '-map',
      '0:v:0',
      '-map',
      '0:a:0',
      '-vf',
      'scale=320:180',
      '-r',
      '30',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-tune',
      'zerolatency',
      '-pix_fmt',
      'yuv420p',
      '-b:v',
      '600k',
      '-g',
      '30',
      '-c:a',
      'aac',
      '-ar',
      '44100',
      '-ac',
      '1',
      '-b:a',
      '64k',
      '-progress',
      'pipe:1',
      '-f',
      'flv',
      recorder.url,
    ]);
    const frames = [...progress.matchAll(/^frame=(\d+)$/gm)].at(-1);
    assert(frames);
    publisherFrames.push(Number(frames[1]));
    assert.match(progress, /progress=end/);
  }
  report = await recorder.finish();
  assert.equal(report.closed, true);
  assert.equal(report.terminal, 'finished');
  assert.equal(report.finishTimedOut, false);
  assert.equal(report.listenerFailure, false);
  assert.equal(report.rejectedConnections, 0);
  assert.equal(report.sessions.length, 2);
  const media = [];
  for (const [index, session] of report.sessions.entries()) {
    assert.equal(session.failure, null);
    assert.equal(session.interrupted, false);
    assert(session.receivedBytes > 0 && session.returnedBytes > 0);
    const path = join(artifact, session.recordingRelativePath);
    const manifest = JSON.parse(
      await readFile(join(artifact, session.directoryRelativePath, 'direct-rtmp-recorder.json')),
    );
    assert.equal(manifest.readinessObserved, true);
    assert.equal(manifest.actualCode, 0);
    assert.equal(manifest.actualSignal, null);
    assert.equal(manifest.terminationRequested, false);
    const timing = JSON.parse(
      await readFile(
        join(artifact, session.directoryRelativePath, 'direct-rtmp-packet-timing.json'),
      ),
    );
    await run(`decode-${index + 1}`, ffmpeg, [
      '-v',
      'error',
      '-xerror',
      '-i',
      path,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0',
      '-f',
      'null',
      '-',
    ]);
    const probe = JSON.parse(
      await run(`probe-${index + 1}`, ffprobe, [
        '-v',
        'error',
        '-show_streams',
        '-show_frames',
        '-show_entries',
        'stream=codec_type,width,height,sample_rate,channels:frame=media_type,best_effort_timestamp_time,nb_samples',
        '-of',
        'json',
        path,
      ]),
    );
    const video = probe.streams.find((s) => s.codec_type === 'video'),
      audio = probe.streams.find((s) => s.codec_type === 'audio');
    assert.equal(video.width, 320);
    assert.equal(video.height, 180);
    assert.equal(Number(audio.sample_rate), 44100);
    assert.equal(audio.channels, 1);
    const frames = probe.frames.filter((f) => f.media_type === 'video');
    assert.equal(frames.length, publisherFrames[index]);
    assert.equal(frames.length, 90);
    const times = frames.map((f) => Number(f.best_effort_timestamp_time));
    for (let i = 1; i < times.length; i++) assert(times[i] > times[i - 1]);
    const audioSamples = probe.frames
      .filter((f) => f.media_type === 'audio')
      .reduce((n, f) => n + Number(f.nb_samples), 0);
    assert(Math.abs(audioSamples / 44100 - 3) < 0.1);
    const frameHash = await run(`first-frame-${index + 1}`, ffmpeg, [
      '-v',
      'error',
      '-i',
      path,
      '-map',
      '0:v:0',
      '-frames:v',
      '1',
      '-f',
      'framemd5',
      '-',
    ]);
    media.push({
      sequence: session.sequence,
      frames: frames.length,
      firstPTS: times[0],
      lastPTS: times.at(-1),
      audioSamples,
      firstFrameHash: frameHash.trim().split('\n').at(-1),
      recorder: manifest,
      packetTiming: timing,
    });
  }
  assert.notEqual(
    media[0].firstFrameHash,
    media[1].firstFrameHash,
    'Distinct source excerpts required',
  );
  for (const [path, hash] of Object.entries(hashes))
    assert.equal(await digest(path), hash, 'Source changed during verification');
  await save('qualification.json', {
    passed: true,
    artifact,
    input,
    hashes,
    commands,
    recorder: report,
    media,
    scope:
      'Two real publishers to a stable loopback recorder, separate fully decodable recordings. No native adaptation, session continuity, outage recovery or production qualification.',
    networkRecoveryQualified: false,
  });
  console.log(
    JSON.stringify({
      artifact,
      passed: true,
      sessions: media.map(({ sequence, frames, audioSamples }) => ({
        sequence,
        frames,
        audioSamples,
      })),
      sourceHashesUnchanged: true,
    }),
  );
} catch (error) {
  await save('failure.json', { message: error.message, commands, report });
  throw error;
} finally {
  await recorder?.stop();
  await save('commands.json', commands);
}
