import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import * as implementation from '../direct-rtmp-recorder.mjs';

async function fixture(t, overrides = {}) {
  const artifact = await mkdtemp(join(tmpdir(), 'direct-recorder-'));
  t.after(() => rm(artifact, { recursive: true, force: true }));
  const child = new EventEmitter();
  child.stderr = new EventEmitter();
  child.pid = 4242;
  const kills = [];
  child.kill = (signal) => {
    kills.push(signal);
    queueMicrotask(() => child.emit('close', null, signal));
    return true;
  };
  const calls = [];
  const options = {
    spawn: (file, args, options) => {
      calls.push({ file, args, options });
      return child;
    },
    execFile: async (file, args, options) => {
      calls.push({ file, args, options });
      return { stdout: 'p4242\nn127.0.0.1:19359\n' };
    },
    startupMs: 500,
    finishMs: 100,
    killMs: 20,
    pollMs: 2,
    ...overrides,
  };
  return {
    artifact,
    child,
    kills,
    calls,
    start: (packetTiming = false) =>
      implementation.startDirectRTMPRecorder(
        { artifact, ffmpeg: '/resolved/ffmpeg', port: 19359, packetTiming },
        options,
      ),
    recording: () => writeFile(join(artifact, 'sink-recordings/direct.mp4'), 'media'),
    manifest: async () =>
      JSON.parse(await readFile(join(artifact, 'direct-rtmp-recorder.json'), 'utf8')),
  };
}

test('exports the recorder lifecycle API', () => {
  assert.equal(typeof implementation.startDirectRTMPRecorder, 'function');
});

test('optional timestamp diagnostics drain stderr and persist only bounded numeric evidence on close', async (t) => {
  const f = await fixture(t);
  const recorder = await f.start(true);
  assert.ok(f.calls[0].args.includes('-debug_ts'));
  assert.ok(f.calls[0].args.includes('-nostats'));
  assert.deepEqual(f.calls[0].options.stdio, ['ignore', 'ignore', 'pipe']);
  f.child.stderr.emit(
    'data',
    Buffer.from(
      'secret-publish-url\n[vist#0:0/h264 @ 0xabc] demuxer -> ist_index:0:0 type:video pkt_pts:429 pkt_pts_time:0.429 pkt_dts:429 pkt_dts_time:0.429 duration:33\n',
    ),
  );
  await f.recording();
  f.child.emit('close', 0, null);
  await recorder.finish();
  const raw = await readFile(join(f.artifact, 'direct-rtmp-packet-timing.json'), 'utf8');
  assert.doesNotMatch(raw, /secret/);
  const timing = JSON.parse(raw);
  assert.equal(timing.demux.video.first[0].ptsSeconds, '0.429');
  assert.equal(timing.recognized, false);
});

test('timestamp evidence cannot overwrite an earlier artifact', async (t) => {
  const f = await fixture(t);
  const path = join(f.artifact, 'direct-rtmp-packet-timing.json');
  await writeFile(path, 'previous');
  await assert.rejects(f.start(true), /refuses to overwrite/);
  assert.equal(f.calls.length, 0);
  assert.equal(await readFile(path, 'utf8'), 'previous');
});

test('readiness observes only the owned PID and exact loopback listener without connecting', async (t) => {
  const f = await fixture(t);
  const recorder = await f.start();
  assert.equal(recorder.url, 'rtmp://127.0.0.1:19359/live/fixture');
  assert.deepEqual(f.calls[0], {
    file: '/resolved/ffmpeg',
    args: [
      '-nostdin',
      '-n',
      '-listen',
      '1',
      '-i',
      recorder.url,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0',
      '-c',
      'copy',
      '-movflags',
      '+frag_keyframe+empty_moov+delay_moov',
      '-f',
      'mp4',
      join(f.artifact, 'sink-recordings/direct.mp4'),
    ],
    options: { stdio: 'ignore' },
  });
  assert.equal(f.calls[1].file, 'lsof');
  assert.deepEqual(f.calls[1].args, [
    '-nP',
    '-a',
    '-p',
    '4242',
    '-iTCP:19359',
    '-sTCP:LISTEN',
    '-Fn',
  ]);
  assert.ok(f.calls[1].options.timeout > 0 && f.calls[1].options.timeout <= 250);
  await recorder.stop();
  assert.deepEqual(await f.manifest(), {
    formatVersion: 1,
    readinessObserved: true,
    actualCode: null,
    actualSignal: 'SIGTERM',
    terminationRequested: true,
    recordingRelativePath: 'sink-recordings/direct.mp4',
  });
});

test('natural close before finish is retained and repeat calls join', async (t) => {
  const f = await fixture(t);
  const recorder = await f.start();
  await f.recording();
  f.child.emit('close', 0, null);
  const first = recorder.finish();
  assert.equal(recorder.finish(), first);
  assert.equal(await first, join(f.artifact, 'sink-recordings/direct.mp4'));
  const cleanup = recorder.stop();
  assert.equal(recorder.stop(), cleanup);
  await cleanup;
  assert.deepEqual(f.kills, []);
  assert.equal((await f.manifest()).actualCode, 0);
});

test('finish waits for natural EOF and manifest persistence', async (t) => {
  const f = await fixture(t);
  const recorder = await f.start();
  await f.recording();
  let done = false;
  const finishing = recorder.finish().then(() => {
    done = true;
  });
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(done, false);
  f.child.emit('close', 0, null);
  await finishing;
  assert.equal((await f.manifest()).terminationRequested, false);
});

for (const [name, code, signal, content] of [
  ['nonzero exit', 1, null, 'media'],
  ['signal exit', null, 'SIGTERM', 'media'],
  ['empty recording', 0, null, ''],
  ['missing recording', 0, null, null],
]) {
  test(`finish rejects ${name}`, async (t) => {
    const f = await fixture(t);
    const recorder = await f.start();
    if (content !== null) await writeFile(join(f.artifact, 'sink-recordings/direct.mp4'), content);
    f.child.emit('close', code, signal);
    await assert.rejects(recorder.finish(), /direct RTMP recorder/i);
    await recorder.stop();
    assert.equal((await f.manifest()).actualCode, code);
  });
}

test('startup rejects an early child exit and persists its actual outcome', async (t) => {
  const f = await fixture(t, {
    execFile: async () => {
      f.child.emit('close', 7, null);
      return { stdout: '' };
    },
  });
  await assert.rejects(f.start(), /direct RTMP recorder/i);
  assert.equal((await f.manifest()).actualCode, 7);
  assert.deepEqual(f.kills, []);
});

test('spawn errors are sanitized and joined through actual close', async (t) => {
  const f = await fixture(t, {
    spawn: () => {
      queueMicrotask(() => {
        f.child.emit('error', new Error('secret credential'));
        f.child.emit('close', -2, null);
      });
      return f.child;
    },
  });
  await assert.rejects(f.start(), (error) => !error.message.includes('secret'));
  assert.equal((await f.manifest()).actualCode, -2);
  assert.ok(!JSON.stringify(await f.manifest()).includes('secret'));
});

test('startup rejects wildcard or foreign listener and cleans up on its absolute deadline', async (t) => {
  const f = await fixture(t, {
    execFile: async () => ({ stdout: 'p4242\nn*:19359\np3333\nn127.0.0.1:19359\n' }),
    startupMs: 20,
  });
  await assert.rejects(f.start(), { message: 'Direct RTMP recorder readiness deadline expired' });
  assert.deepEqual(f.kills, ['SIGTERM']);
  assert.equal((await f.manifest()).readinessObserved, false);
});

test('cancellation reaps a real readiness probe that ignores TERM', async (t) => {
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const execute = promisify(execFile);
  let probeChild;
  let probeClosed;
  let ready = false;
  let timer;
  const f = await fixture(t, {
    startupMs: 2_000,
    execFile: (_file, _args, options) => {
      const pending = execute(
        process.execPath,
        [
          '-e',
          `
        process.on('SIGTERM', () => {});
        process.stdout.write('ready\\n');
        setInterval(() => {}, 1000);
      `,
        ],
        options,
      );
      probeChild = pending.child;
      probeClosed = new Promise((resolve) => probeChild.once('close', resolve));
      probeChild.stdout.once('data', () => {
        ready = true;
        f.child.emit('close', 1, null);
      });
      return pending;
    },
  });
  const starting = f.start().then(
    () => 'unexpected success',
    (error) => error.message,
  );
  try {
    const result = await Promise.race([
      starting,
      new Promise((resolve) => {
        timer = setTimeout(() => resolve('probe still pending'), 1_000);
      }),
    ]);
    assert.equal(ready, true);
    assert.equal(result, 'Direct RTMP recorder exited before readiness');
    assert.equal(probeChild.signalCode, 'SIGKILL');
  } finally {
    clearTimeout(timer);
    if (probeChild?.exitCode === null && probeChild.signalCode === null) probeChild.kill('SIGKILL');
    await probeClosed;
    await starting;
  }
});

test('a stuck readiness probe cannot exceed the startup budget', async (t) => {
  let probeJoined = false;
  let now = 0;
  const f = await fixture(t, {
    // Filesystem setup must not consume this test's deliberately tiny probe budget.
    now: () => now,
    execFile: (_file, _args, { signal }) =>
      new Promise((resolve) => {
        signal.addEventListener(
          'abort',
          () => {
            now = 15;
            probeJoined = true;
            resolve({ stdout: '' });
          },
          { once: true },
        );
      }),
    startupMs: 15,
  });
  await assert.rejects(f.start(), /direct RTMP recorder/i);
  assert.deepEqual(f.kills, ['SIGTERM']);
  assert.equal(probeJoined, true);
});

test('startup budget consumed before probing still cleans up the recorder', async (t) => {
  let clockReads = 0;
  let probes = 0;
  const f = await fixture(t, {
    now: () => (clockReads++ === 0 ? 0 : 15),
    startupMs: 15,
    execFile: async () => {
      probes++;
      return { stdout: '' };
    },
  });
  await assert.rejects(f.start(), /readiness deadline expired/);
  assert.equal(probes, 0);
  assert.deepEqual(f.kills, ['SIGTERM']);
  assert.equal((await f.manifest()).terminationRequested, true);
});

test('finish deadline is a failure even if termination causes a zero exit', async (t) => {
  const f = await fixture(t, { finishMs: 15 });
  const recorder = await f.start();
  await f.recording();
  f.child.kill = (signal) => {
    f.kills.push(signal);
    queueMicrotask(() => f.child.emit('close', 0, null));
    return true;
  };
  await assert.rejects(recorder.finish(), /direct RTMP recorder/i);
  assert.deepEqual(f.kills, ['SIGTERM']);
  assert.equal((await f.manifest()).terminationRequested, true);
});

test('stop joins TERM then KILL and writes only after actual close', async (t) => {
  const f = await fixture(t);
  const recorder = await f.start();
  f.child.kill = (signal) => {
    f.kills.push(signal);
    if (signal === 'SIGKILL') setTimeout(() => f.child.emit('close', null, 'SIGKILL'), 5);
    return true;
  };
  const stopping = recorder.stop();
  assert.equal(recorder.stop(), stopping);
  await assert.rejects(f.manifest(), { code: 'ENOENT' });
  await stopping;
  assert.deepEqual(f.kills, ['SIGTERM', 'SIGKILL']);
  assert.equal((await f.manifest()).actualSignal, 'SIGKILL');
});

test('late readiness cannot turn an already closed process into a ready recorder', async (t) => {
  const f = await fixture(t, {
    execFile: async () => {
      f.child.emit('close', 0, null);
      return { stdout: 'p4242\nn127.0.0.1:19359\n' };
    },
  });
  await assert.rejects(f.start(), /direct RTMP recorder/i);
  assert.equal((await f.manifest()).readinessObserved, false);
});

test('a synchronous spawn failure exposes no raw error', async (t) => {
  const f = await fixture(t, {
    spawn: () => {
      throw new Error('secret credential');
    },
  });
  await assert.rejects(f.start(), { message: 'Direct RTMP recorder failed to spawn' });
});

test('existing output is never replaced or followed by another child', async (t) => {
  const f = await fixture(t);
  const first = await f.start();
  await f.recording();
  f.child.emit('close', 0, null);
  await first.finish();
  await assert.rejects(f.start(), /refuses to overwrite/);
  assert.equal(f.calls.filter(({ file }) => file === '/resolved/ffmpeg').length, 1);
  assert.equal(await readFile(join(f.artifact, 'sink-recordings/direct.mp4'), 'utf8'), 'media');
});

test('manifest persistence failures propagate through finish and stop', async (t) => {
  const f = await fixture(t);
  const recorder = await f.start();
  await writeFile(join(f.artifact, 'direct-rtmp-recorder.json'), 'existing');
  await f.recording();
  f.child.emit('close', 0, null);
  await assert.rejects(recorder.finish(), /persist its manifest/);
  await assert.rejects(recorder.stop(), /persist its manifest/);
  assert.equal(await readFile(join(f.artifact, 'direct-rtmp-recorder.json'), 'utf8'), 'existing');
});

test('a real failed spawn is joined and recorded without exposing its path', async (t) => {
  const { spawn } = await import('node:child_process');
  const f = await fixture(t, { spawn });
  await assert.rejects(f.start(), /direct RTMP recorder/i);
  assert.equal((await f.manifest()).actualCode, -2);
});

test('stop reaps a real child that ignores TERM before resolving', async (t) => {
  const { spawn } = await import('node:child_process');
  let realChild;
  const signals = [];
  const f = await fixture(t, {
    startupMs: 1_000,
    spawn: () => {
      realChild = spawn(
        process.execPath,
        [
          '-e',
          `
        process.on('SIGTERM', () => {});
        require('node:fs').writeFileSync(${JSON.stringify(join(f.artifact, 'child-ready'))}, '');
        setInterval(() => {}, 1000);
      `,
        ],
        { stdio: 'ignore' },
      );
      const kill = realChild.kill.bind(realChild);
      realChild.kill = (signal) => {
        signals.push(signal);
        return kill(signal);
      };
      return realChild;
    },
    execFile: async () => {
      const ready = await readFile(join(f.artifact, 'child-ready')).then(
        () => true,
        () => false,
      );
      return { stdout: ready ? `p${realChild.pid}\nn127.0.0.1:19359\n` : '' };
    },
  });
  t.after(() => {
    if (realChild.exitCode === null && realChild.signalCode === null) realChild.kill('SIGKILL');
  });
  const recorder = await f.start();
  await recorder.stop();
  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL']);
  assert.equal(realChild.signalCode, 'SIGKILL');
  assert.equal((await f.manifest()).actualSignal, 'SIGKILL');
});

for (const port of [0, -1, 65536, 1935.5, '1935']) {
  test(`rejects invalid port ${JSON.stringify(port)} before spawning`, async () => {
    await assert.rejects(
      implementation.startDirectRTMPRecorder(
        { artifact: '/unused', ffmpeg: '/unused', port },
        {
          spawn: () => assert.fail('must not spawn'),
        },
      ),
      /invalid port/,
    );
  });
}
