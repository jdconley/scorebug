import assert from 'node:assert/strict';
import { createSocket } from 'node:dgram';
import { randomInt, createHash } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { ownedCommand } from './owned-command.mjs';
import { mediaTools } from './media-tools.mjs';
import { startProbeProcess } from './capacity-probe-process.mjs';
import { closeMPEGTSProbe } from './mpegts-probe-cleanup.mjs';
import { createUDPImpairmentProxy } from './udp-impairment.mjs';
import { qualifyDatagramTimeline } from './datagram-timeline-qualification.mjs';
import { qualifyMPEGTSProbe } from './mpegts-probe-evidence.mjs';

assert.equal(process.argv.length, 2);
const root = fileURLToPath(new URL('..', import.meta.url));
await mkdir(join(root, 'artifacts/qa'), { recursive: true });
const artifact = await mkdtemp(join(root, 'artifacts/qa/mpegts-probe-'));
console.log(`Local MPEG-TS padding qualification: ${artifact}`);
const controller = new AbortController(),
  now = () => performance.now() / 1000;
const abort = () => controller.abort();
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, abort);
const deadline = setTimeout(abort, 150000);
const { ffmpeg, ffprobe } = mediaTools();
const sourceSHA256 = {},
  commands = [],
  results = [];
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
let error;
async function command(binary, args, label) {
  const r = await ownedCommand(binary, args, {
    cwd: root,
    signal: controller.signal,
    timeout: 60000,
    maxOutputBytes: 2 * 1024 * 1024,
  });
  commands.push({
    binary,
    args,
    label,
    ok: r.ok,
    code: r.code,
    reason: r.reason,
    signal: r.signal,
  });
  await writeFile(join(artifact, label + '.log'), r.stdout + r.stderr);
  assert(r.ok, `${label}: ${r.reason ?? r.code}`);
  return r.stdout;
}
async function boundedRead(path) {
  assert((await stat(path)).size <= 32 * 1024 * 1024);
  return readFile(path);
}
async function decoded(path, label) {
  const frames = join(artifact, label + '.framehash');
  await command(
    ffmpeg,
    [
      '-v',
      'error',
      '-xerror',
      '-i',
      path,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0',
      '-c:v',
      'rawvideo',
      '-c:a',
      'pcm_s16le',
      '-f',
      'framehash',
      '-hash',
      'sha256',
      frames,
    ],
    label + '-decode',
  );
  const bytes = await boundedRead(frames);
  const rows = bytes
    .toString()
    .split('\n')
    .filter((line) => line && !line.startsWith('#'));
  const videoFrames = rows.filter((line) => line.startsWith('0,')).length;
  const audioFrames = rows.filter((line) => line.startsWith('1,')).length;
  assert.equal(videoFrames, 360);
  assert(audioFrames >= 562 && audioFrames <= 565);
  return { framehash: bytes.toString(), sha256: hash(bytes), videoFrames, audioFrames };
}
async function scenario(name, binary, source, sourceDecode) {
  const directory = join(artifact, name);
  await mkdir(directory);
  const owners = [],
    sentCommands = [];
  const runID = randomInt(1, 0xffffffff);
  let proxy, failure, evidence;
  function start(role, port, extra) {
    const owner = startProbeProcess(binary, [role, String(port), String(runID), ...extra], {
      cwd: root,
      role,
      now,
    });
    owners.push(owner);
    return owner;
  }
  function send(owner, line) {
    assert(!owner.closed && !owner.failure);
    sentCommands.push({ role: owner.role, line, at: now() });
    owner.child.stdin.write(line + '\n');
  }
  async function until(predicate, label, timeout = 8, step = () => {}) {
    const end = now() + timeout;
    while (now() < end) {
      assert(!controller.signal.aborted, 'cancelled');
      assert(
        owners.every((o) => !o.closed && !o.failure),
        'native owner failed',
      );
      step();
      if (predicate()) return;
      await delay(10);
    }
    throw Error(`${name}: ${label} timeout`);
  }
  try {
    const reservation = createSocket('udp4');
    const port = await new Promise((resolve, reject) => {
      reservation.once('error', reject);
      reservation.bind(0, '127.0.0.1', () => resolve(reservation.address().port));
    }).finally(() => new Promise((resolve) => reservation.close(resolve)));
    const receiver = start('receiver', port, [join(directory, 'received.ts')]);
    await until(() => receiver.rows.some((r) => r.kind === 'listening'), 'listener');
    proxy = await createUDPImpairmentProxy({
      receiverPort: port,
      forward: {
        rateBitsPerSecond: name === 'pressure' ? 4_000_000 : 12_000_000,
        recordTimeline: true,
      },
      reverse: { recordTimeline: true },
    });
    const sender = start('sender', proxy.port, [
      join(artifact, 'source.ts'),
      join(directory, 'accepted.ts'),
    ]);
    await until(() => owners.every((o) => o.rows.some((r) => r.kind === 'ready')), 'connection');
    for (const owner of owners)
      assert.equal(owner.rows.find((r) => r.kind === 'ready').runID, runID);
    send(sender, 'start');
    await until(() => sender.sample?.sourceBytes >= (3 * 3_500_000) / 8, 'baseline warmup');
    if (name !== 'baseline') {
      send(sender, `probe ${name === 'lease' ? 1_000_000 : 2_000_000}`);
      const began = now();
      let renewed = began;
      await until(
        () => sender.rows.some((r) => r.kind === 'withdrawn'),
        'padding withdrawal',
        4,
        () => {
          if (now() - began < 2 && now() - renewed >= 0.08) {
            send(sender, 'lease');
            renewed = now();
          }
        },
      );
    }
    await until(
      () =>
        sender.rows.some((r) => r.kind === 'source-ended') &&
        sender.sample?.sourceBytes === source.length &&
        receiver.sample?.transportBytes === sender.sample?.transportBytes &&
        sender.sample?.bufferMs === 0,
      'media drain',
      15,
    );
  } catch (e) {
    failure = String(e.stack ?? e);
  } finally {
    const cleanupFailures = await closeMPEGTSProbe(owners, proxy, async () => {
      for (const owner of owners) {
        await writeFile(
          join(directory, owner.role + '.json'),
          JSON.stringify(owner.rows, null, 2) + '\n',
        );
        await writeFile(join(directory, owner.role + '.log'), owner.output + owner.error);
      }
    });
    failure ??= cleanupFailures[0];
    const transport = proxy?.snapshot();
    await writeFile(
      join(directory, 'proxy.json'),
      JSON.stringify(transport ?? null, null, 2) + '\n',
    );
    const cleanup = owners.map((o) => ({
      role: o.role,
      closed: o.closed,
      code: o.code,
      failure: o.failure,
    }));
    if (!failure)
      try {
        assert.equal(owners.length, 2);
        assert(cleanup.every((o) => o.closed && o.code === 0 && !o.failure));
        assert(transport.closed);
        assert.deepEqual(transport.errors, []);
        for (const direction of ['forward', 'reverse']) {
          assert.equal(transport[direction].pendingPackets, 0);
          assert(qualifyDatagramTimeline(transport[direction].queue).complete);
        }
        const sender = owners.find((o) => o.role === 'sender'),
          receiver = owners.find((o) => o.role === 'receiver');
        evidence = qualifyMPEGTSProbe({
          source,
          accepted: await boundedRead(join(directory, 'accepted.ts')),
          received: await boundedRead(join(directory, 'received.ts')),
          senderRows: sender.rows,
          receiverRows: receiver.rows,
          scenario: name,
        });
        const decode = await decoded(join(directory, 'received.ts'), name);
        assert.equal(
          decode.framehash,
          sourceDecode.framehash,
          'Decoded A/V pictures, samples or timestamps differ',
        );
        evidence.decode = {
          sha256: decode.sha256,
          videoFrames: decode.videoFrames,
          audioFrames: decode.audioFrames,
        };
      } catch (e) {
        failure = String(e.stack ?? e);
      }
    const result = {
      name,
      runID,
      error: failure ?? null,
      evidence,
      cleanup,
      commands: sentCommands,
    };
    results.push(result);
    await writeFile(join(directory, 'result.json'), JSON.stringify(result, null, 2) + '\n');
  }
  assert(!failure, failure);
  console.log(
    `${name}: original media and received A/V match; ${evidence.probeBytes} padding bytes`,
  );
}
try {
  for (const path of [
    'tools/capacity-probe/mpegts-padding.h',
    'tools/capacity-probe/mpegts-padding-test.cpp',
    'tools/capacity-probe/mpegts-probe.cpp',
    'scripts/test-mpegts-probe.mjs',
    'scripts/mpegts-probe-evidence.mjs',
    'scripts/capacity-probe-process.mjs',
    'scripts/mpegts-probe-cleanup.mjs',
    'scripts/owned-command.mjs',
    'scripts/media-tools.mjs',
    'scripts/udp-impairment.mjs',
    'scripts/datagram-timeline-qualification.mjs',
  ]) {
    const bytes = await readFile(join(root, path));
    sourceSHA256[path] = hash(bytes);
    const target = join(artifact, 'source-snapshot', path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, bytes);
  }
  await writeFile(
    join(artifact, 'source-sha256.json'),
    JSON.stringify(sourceSHA256, null, 2) + '\n',
  );
  const flags = (await command('pkg-config', ['--cflags', '--libs', 'srt'], 'pkg-config'))
    .trim()
    .split(/\s+/);
  assert(flags.every((f) => /^[-A-Za-z0-9_/.+@]+$/.test(f)));
  const binary = join(artifact, 'mpegts-probe'),
    unit = join(artifact, 'mpegts-padding-test');
  await command(
    'c++',
    [
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      join(root, 'tools/capacity-probe/mpegts-padding-test.cpp'),
      '-o',
      unit,
    ],
    'build-unit',
  );
  await command(unit, [], 'unit');
  await command(
    'c++',
    [
      '-std=c++17',
      '-Wall',
      '-Wextra',
      '-Werror',
      join(root, 'tools/capacity-probe/mpegts-probe.cpp'),
      '-o',
      binary,
      ...flags,
    ],
    'build',
  );
  await command(ffmpeg, ['-version'], 'ffmpeg-version');
  await command(
    ffmpeg,
    [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=1280x720:rate=30',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=1000:sample_rate=48000',
      '-t',
      '12',
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-tune',
      'zerolatency',
      '-b:v',
      '1500k',
      '-maxrate',
      '1500k',
      '-bufsize',
      '3000k',
      '-g',
      '60',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-b:a',
      '128k',
      '-muxrate',
      '3500000',
      '-f',
      'mpegts',
      join(artifact, 'source.ts'),
    ],
    'generate',
  );
  await command(
    ffprobe,
    [
      '-v',
      'error',
      '-count_frames',
      '-show_streams',
      '-show_format',
      '-of',
      'json',
      join(artifact, 'source.ts'),
    ],
    'source-probe',
  );
  const source = await boundedRead(join(artifact, 'source.ts'));
  const sourceDecode = await decoded(join(artifact, 'source.ts'), 'source');
  for (const name of ['baseline', 'lease', 'pressure'])
    await scenario(name, binary, source, sourceDecode);
  assert.equal(
    hash(await boundedRead(join(artifact, 'source.ts'))),
    hash(source),
    'Source recording changed',
  );
  for (const [path, digest] of Object.entries(sourceSHA256))
    assert.equal(hash(await readFile(join(root, path))), digest, 'Runtime source changed');
} catch (e) {
  error = String(e.stack ?? e);
} finally {
  clearTimeout(deadline);
  for (const signal of ['SIGINT', 'SIGTERM']) process.off(signal, abort);
  await writeFile(
    join(artifact, 'result.json'),
    JSON.stringify(
      {
        error: error ?? null,
        results,
        commands,
        scope:
          'Installed-library loopback SRT MPEG-TS replay. Not a native camera/archive, GoSRT relay, capacity admission or production qualification.',
      },
      null,
      2,
    ) + '\n',
  );
  console.log(JSON.stringify({ artifact, error: error ?? null }, null, 2));
}
if (error) process.exitCode = 1;
