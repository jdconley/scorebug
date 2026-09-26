import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { expect, it } from 'vitest';
import { buildFfmpegArgs, startPipeline } from '../src/pipeline.js';
import { EncoderDiagnostics } from '../src/encoder-diagnostics.mjs';
import * as protocol from '@scorebug/protocol';
import { createLogger, type Logger } from '../src/logger.js';

it('executes the configured media binary instead of the one on PATH', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'scorebug-tool-'));
  try {
    const binary = join(dir, 'test-encoder');
    await writeFile(binary, '#!/bin/sh\nexit 0\n');
    await chmod(binary, 0o755);
    const pipeline = startPipeline(
      {
        gameId: 'qa',
        pullUrl: 'unused',
        publishUrl: 'unused',
        scoreFile: join(dir, 'score.txt'),
        nvenc: false,
        ffmpegPath: binary,
      },
      createLogger('error'),
    );
    expect(await pipeline.waitExit()).toEqual({ code: 0, signal: null });
    expect(protocol).toHaveProperty('DECODED_VIDEO_TRANSPORT_CLOCK', 'mpegts-pts-90k-v1');
    expect(pipeline.snapshotProcessingWindow?.()).toBeNull();
    expect(pipeline.snapshotDecoderDelivery?.()).toBeNull();
    expect(pipeline.snapshotDecodedVideo?.()).toMatchObject({
      clock: 'mpegts-pts-90k-v1',
      ended: true,
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

it('uses the selected font for the overlay', () => {
  const args = buildFfmpegArgs({
    gameId: 'qa',
    pullUrl: 'unused',
    publishUrl: 'unused',
    scoreFile: '/tmp/score.txt',
    nvenc: false,
    fontPath: '/custom/score.ttf',
  });
  expect(args[args.indexOf('-vf') + 1]).toContain('/custom/score.ttf');
  expect(args[args.indexOf('-vf') + 1]).not.toContain('/usr/share/fonts');
});

it('settles a missing binary without an unhandled error or a pending exit', async () => {
  const pipeline = startPipeline(
    {
      gameId: 'missing',
      pullUrl: 'unused',
      publishUrl: 'unused',
      scoreFile: '/tmp/score.txt',
      nvenc: false,
      ffmpegPath: '/definitely-not-an-installed-scorebug-encoder',
    },
    createLogger('error'),
  );
  expect(await boundedExit(pipeline)).toEqual({ code: null, signal: null });
  expect(pipeline.snapshotDecodedVideo?.().ended).toBe(true);
  pipeline.stop();
});

async function childFixture(body: string) {
  const dir = await mkdtemp(join(tmpdir(), 'scorebug-child-'));
  const binary = join(dir, 'encoder');
  const ready = join(dir, 'ready');
  await writeFile(
    binary,
    `#!${process.execPath}\n${body}\nrequire('node:fs').writeFileSync(${JSON.stringify(ready)}, String(process.pid));\n`,
  );
  await chmod(binary, 0o755);
  const records: Record<string, unknown>[] = [];
  const record = (message: string, meta?: Record<string, unknown>) =>
    records.push({ message, ...meta });
  const log: Logger = { debug: record, info: record, warn: record, error: record };
  return {
    dir,
    spec: {
      gameId: 'fixture',
      pullUrl: 'srt://user:PULL_PASSWORD@host:8890?passphrase=QUERY_SECRET',
      publishUrl: 'rtmps://host/live/STREAM_KEY',
      scoreFile: join(dir, 'score.txt'),
      nvenc: false,
      ffmpegPath: binary,
    },
    log,
    records,
    async ready() {
      await expect.poll(async () => readFile(ready, 'utf8')).toMatch(/^\d+$/);
    },
    async cleanup() {
      try {
        const pid = Number(await readFile(ready, 'utf8'));
        process.kill(pid, 'SIGKILL');
      } catch {
        /* The fixture may have already exited. */
      }
      await rm(dir, { recursive: true, force: true });
    },
  };
}

async function boundedExit(pipeline: ReturnType<typeof startPipeline>) {
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve('timed out'), 1000);
  });
  try {
    return await Promise.race([pipeline.waitExit(), timeout]);
  } finally {
    clearTimeout(timer!);
  }
}

it('escalates an ignored TERM to KILL and keeps repeated stop calls idempotent', async () => {
  const fixture = await childFixture(
    `process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);`,
  );
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, { stopTimeoutMs: 50 });
    await fixture.ready();
    pipeline.stop();
    pipeline.stop();
    expect(await boundedExit(pipeline)).toEqual({ code: null, signal: 'SIGKILL' });
    pipeline.stop();
    expect(fixture.records.filter((entry) => entry.message === 'ffmpeg_sigterm')).toHaveLength(1);
    expect(fixture.records.filter((entry) => entry.message === 'ffmpeg_sigkill')).toHaveLength(1);
    expect(fixture.records.filter((entry) => entry.message === 'ffmpeg_exited')).toHaveLength(1);
  } finally {
    await fixture.cleanup();
  }
});

it('reaps an encoder that ignores TERM after its worker is killed abruptly', async () => {
  const fixture = await childFixture(`
    require('node:fs').writeSync(3, 'frame:0 pts:0 pts_time:0\\nscorebug.source=1\\n');
    process.on('SIGTERM', () => require('node:fs').writeFileSync(__filename + '.term', 'received'));
    setInterval(() => {}, 1000);
  `);
  const workerPath = join(fixture.dir, 'worker.mjs');
  await writeFile(
    workerPath,
    `
    import { startPipeline } from ${JSON.stringify(new URL('../src/pipeline.ts', import.meta.url).href)};
    const noop = () => {};
    startPipeline(${JSON.stringify(fixture.spec)}, { debug: noop, info: noop, warn: noop, error: noop }, { stopTimeoutMs: 50 });
    setInterval(() => {}, 1000);
  `,
  );
  const worker = spawn(process.execPath, ['--import', import.meta.resolve('tsx'), workerPath], {
    stdio: 'ignore',
  });
  const exited = new Promise((resolve) => worker.once('exit', resolve));
  try {
    await fixture.ready();
    const pid = Number(await readFile(join(fixture.dir, 'ready'), 'utf8'));
    worker.kill('SIGKILL');
    await exited;
    await expect
      .poll(async () => readFile(fixture.spec.ffmpegPath + '.term', 'utf8'), { timeout: 1500 })
      .toBe('received');
    await expect
      .poll(
        () => {
          try {
            process.kill(pid, 0);
            return true;
          } catch {
            return false;
          }
        },
        { timeout: 1500 },
      )
      .toBe(false);
  } finally {
    worker.kill('SIGKILL');
    await fixture.cleanup();
  }
});

it('honors stop before the guardian has spawned its encoder', async () => {
  const fixture = await childFixture('setInterval(() => {}, 1000);');
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, { stopTimeoutMs: 50 });
    pipeline.stop();
    pipeline.stop();
    expect(await boundedExit(pipeline)).toMatchObject({ code: null, signal: 'SIGTERM' });
    expect(fixture.records.filter((entry) => entry.message === 'ffmpeg_exited')).toHaveLength(1);
  } finally {
    await fixture.cleanup();
  }
});

it('does not report encoder exit when only its guardian has been killed', async () => {
  const fixture = await childFixture(`
    require('node:fs').writeFileSync(__filename + '.guardian', String(process.ppid));
    setInterval(() => {}, 1000);
  `);
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log);
    await fixture.ready();
    const guardianPid = Number(await readFile(fixture.spec.ffmpegPath + '.guardian', 'utf8'));
    const encoderPid = Number(await readFile(join(fixture.dir, 'ready'), 'utf8'));
    expect(guardianPid).not.toBe(process.pid);
    process.kill(guardianPid, 'SIGKILL');
    expect(await boundedExit(pipeline)).toBe('timed out');
    expect(() => process.kill(encoderPid, 0)).not.toThrow();
    expect(fixture.records.some((entry) => entry.message === 'ffmpeg_exited')).toBe(false);
    pipeline.stop();
  } finally {
    await fixture.cleanup();
  }
});

it('returns the encoder failure code rather than the guardian success code', async () => {
  const fixture = await childFixture('process.exitCode = 23;');
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log);
    expect(await boundedExit(pipeline)).toEqual({ code: 23, signal: null });
  } finally {
    await fixture.cleanup();
  }
});

it('cancels escalation when TERM exits gracefully and ignores stop after exit', async () => {
  const fixture = await childFixture(
    `process.on('SIGTERM', () => process.exit(0)); setInterval(() => {}, 1000);`,
  );
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, { stopTimeoutMs: 50 });
    await fixture.ready();
    pipeline.stop();
    expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
    pipeline.stop();
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(fixture.records.filter((entry) => entry.message === 'ffmpeg_sigkill')).toHaveLength(0);
    expect(fixture.records.filter((entry) => entry.message === 'ffmpeg_sigterm')).toHaveLength(1);
  } finally {
    await fixture.cleanup();
  }
});

it('settles synchronous spawn rejection without exposing error text', async () => {
  const fixture = await childFixture('');
  try {
    fixture.spec.ffmpegPath = 'private-secret\u0000invalid';
    const pipeline = startPipeline(fixture.spec, fixture.log);
    expect(await boundedExit(pipeline)).toEqual({ code: null, signal: null });
    pipeline.stop();
    expect(JSON.stringify(fixture.records)).not.toContain('private-secret');
    expect(fixture.records.filter((entry) => entry.message === 'ffmpeg_exited')).toHaveLength(1);
  } finally {
    await fixture.cleanup();
  }
});

it('never logs arbitrary encoder stdout, stderr, URL credentials or stream keys', async () => {
  const fixture = await childFixture(`
    process.stdout.write('arbitrary stdout\\n' + process.argv.join(' '));
    process.stderr.write('arbitrary stderr\\n' + process.argv.join(' '));
  `);
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log);
    expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
    const logs = JSON.stringify(fixture.records);
    for (const secret of [
      'arbitrary stdout',
      'arbitrary stderr',
      fixture.spec.pullUrl,
      fixture.spec.publishUrl,
      'PULL_PASSWORD',
      'QUERY_SECRET',
      'STREAM_KEY',
    ]) {
      expect(logs).not.toContain(secret);
    }
  } finally {
    await fixture.cleanup();
  }
});

it.each([-1, NaN, Infinity, 60_001, 0.5])(
  'rejects an invalid shutdown grace period %s before spawning',
  async (stopTimeoutMs) => {
    const fixture = await childFixture('');
    try {
      expect(() => startPipeline(fixture.spec, fixture.log, { stopTimeoutMs })).toThrow(RangeError);
      expect(fixture.records).toEqual([]);
    } finally {
      await fixture.cleanup();
    }
  },
);

it('accepts complete monotonic output counters across chunks without fabricating liveness', async () => {
  const chunks = [
    'frame=0\nout_time_us=0\nprogress=continue\nfra',
    'me=   3\r\nout_time_us=100\r\nspeed=1.0x\r\nprogress=continue\r\n',
    'frame=3\nout_time_us=100\nprogress=continue\n', // duplicate
    'frame=2\nout_time_us=200\nprogress=continue\n', // regressing frame
    'frame=4\nout_time_us=90\nprogress=continue\n', // regressing timestamp
    'frame=4\nout_time_us=100\nprogress=continue\n',
    'frame=4\nout_time_us=200\nprogress=end\n',
    'frame=99\nout_time_us=999\n', // incomplete record
  ];
  const fixture = await childFixture(`
    const chunks = ${JSON.stringify(chunks)};
    const timer = setInterval(() => {
      process.stdout.write(chunks.shift());
      if (!chunks.length) clearInterval(timer);
    }, 5);
  `);
  const updates: unknown[] = [];
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      onProgress: (update) => updates.push(update),
    });
    expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
    expect(updates).toEqual([
      { frame: 0, outTimeUs: 0 },
      { frame: 3, outTimeUs: 100 },
      { frame: 4, outTimeUs: 100 },
      { frame: 4, outTimeUs: 200 },
    ]);
  } finally {
    await fixture.cleanup();
  }
});

it('rejects malformed and oversized progress records and recovers at record boundaries', async () => {
  const invalidRecords = [
    'frame=-1\nout_time_us=1',
    'frame=1.5\nout_time_us=1',
    'frame=1e2\nout_time_us=1',
    'frame=Infinity\nout_time_us=1',
    'frame=9007199254740992\nout_time_us=1',
    'frame=1\nout_time_us=N/A',
    'frame=1\nout_time_us=-1',
    'frame=1\nout_time_us=9007199254740992',
    'frame=1',
    'out_time_us=1',
    'frame=broken\nframe=1\nout_time_us=1',
    'frame=1\nframe=2\nout_time_us=1',
    'frame=1\nout_time_us=1\nout_time_us=2',
    'frame=1\nout_time_us=1\n' + 'x'.repeat(65_536),
  ];
  const output =
    invalidRecords.map((record) => record + '\nprogress=continue\n').join('') +
    'frame=9\nout_time_us=9\nprogress=invalid\n' +
    'frame=10\nout_time_us=10\nprogress=end\n';
  const fixture = await childFixture(`process.stdout.write(${JSON.stringify(output)});`);
  const updates: unknown[] = [];
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      onProgress: (update) => updates.push(update),
    });
    expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
    expect(updates).toEqual([{ frame: 10, outTimeUs: 10 }]);
  } finally {
    await fixture.cleanup();
  }
});

it('keeps supervising when a progress observer throws and does not log its error', async () => {
  const fixture = await childFixture(
    `process.stdout.write('frame=1\\nout_time_us=1\\nprogress=end\\n');`,
  );
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      onProgress: () => {
        throw new Error('OBSERVER_SECRET');
      },
    });
    expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
    expect(JSON.stringify(fixture.records)).not.toContain('OBSERVER_SECRET');
    expect(fixture.records).toContainEqual({
      message: 'ffmpeg_progress_callback_failed',
      gameId: 'fixture',
    });
  } finally {
    await fixture.cleanup();
  }
});

it('routes dedicated telemetry independently of progress and drains the terminal record before exit', async () => {
  const fixture = await childFixture(`
    process.stdout.write('frame=9\\nout_time_us=9\\nprogress=end\\n');
    require('node:fs').writeSync(3, 'frame:0 pts:9000 pts_time:0.1\\nscorebug.source=1\\n');
    process.stderr.write('SECRET_DIAGNOSTIC');
    setTimeout(() => {}, 500);
  `);
  let time = 0;
  const progress: unknown[] = [];
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      monotonicNow: () => time,
      onProgress: (value) => progress.push(value),
    });
    await expect.poll(() => pipeline.snapshotDecoderCadence?.().progress?.lastFreshPTS).toBe(9000);
    time = 5000;
    expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
    expect(progress).toEqual([{ frame: 9, outTimeUs: 9 }]);
    expect(pipeline.snapshotDecodedVideo?.()).toMatchObject({
      ended: true,
      invalidReason: null,
      completed: { freshFrames: 1, firstPTS: 9000, lastPTS: 9000 },
      clock: 'mpegts-pts-90k-v1',
    });
    expect(JSON.stringify(fixture.records)).not.toContain('SECRET_DIAGNOSTIC');
  } finally {
    await fixture.cleanup();
  }
});

it('drains large malformed telemetry with no observer and seals its invalid terminal evidence', async () => {
  const fixture = await childFixture(
    `require('node:fs').writeSync(3, 'PRIVATE_URL'.repeat(100000));`,
  );
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log);
    expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
    expect(pipeline.snapshotDecodedVideo?.()).toMatchObject({
      ended: true,
      invalidReason: 'oversized',
      completed: null,
    });
    expect(JSON.stringify(fixture.records)).not.toContain('PRIVATE_URL');
  } finally {
    await fixture.cleanup();
  }
});

it('emits one terminal after late pipe data and before actual exit resolves, retaining a partial decoder window', async () => {
  const tail =
    "setTimeout(() => { require('node:fs').writeSync(3, 'frame:0 pts:9000 pts_time:0.1\\nscorebug.source=1\\n'); process.stdout.write('frame=7\\nout_time_us=900\\nprogress=end\\nframe=99\\nout_time_us=999\\n'); }, 75);";
  const fixture = await childFixture(`
    require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(tail)}], { stdio: ['ignore', 1, 'ignore', 3] }).unref();
    process.exitCode = 23;
  `);
  const terminal: unknown[] = [];
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      monotonicNow: () => 0,
      onTerminal: (value) => terminal.push(value),
    });
    expect(await boundedExit(pipeline)).toEqual({ code: 23, signal: null });
    const emptyDiagnostics = new EncoderDiagnostics();
    emptyDiagnostics.end();
    expect(terminal).toEqual([
      {
        diagnostics: emptyDiagnostics.snapshot(),
        decoderCadence: expect.objectContaining({
          ended: true,
          progress: { lastFreshPTS: 9000, ageMs: 0, stalled: false },
        }),
        telemetryEOF: true,
        encoderExit: { code: 23, signal: null },
        outputProgress: { frame: 7, outTimeUs: 900 },
        decodedVideo: {
          acceptedFrames: 1,
          freshFrames: 1,
          duplicateFrames: 0,
          reorderedFrames: 0,
          firstPTS: 9000,
          lastPTS: 9000,
          highestPTS: 9000,
          timeBase: '1/90000',
          invalidReason: null,
          ended: true,
        },
      },
    ]);
    expect(pipeline.snapshotDecodedVideo?.().completed).toBeNull();
    pipeline.stop();
    await pipeline.waitExit();
    expect(terminal).toHaveLength(1);
  } finally {
    await fixture.cleanup();
  }
});

it('contains terminal observer exceptions and handles encoder spawn failure', async () => {
  const fixture = await childFixture('');
  let calls = 0;
  try {
    fixture.spec.ffmpegPath += '-missing';
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      onTerminal: (value) => {
        calls++;
        expect(value).toMatchObject({
          encoderExit: { code: null, signal: null },
          telemetryEOF: true,
          outputProgress: null,
          decodedVideo: { ended: true, acceptedFrames: 0 },
        });
        throw new Error('TERMINAL_SECRET');
      },
    });
    expect(await boundedExit(pipeline)).toEqual({ code: null, signal: null });
    expect(calls).toBe(1);
    expect(JSON.stringify(fixture.records)).not.toContain('TERMINAL_SECRET');
  } finally {
    await fixture.cleanup();
  }
});

it('reports unknown encoder status after guardian loss and pipe closure while waitExit stays fail closed', async () => {
  const fixture = await childFixture(
    "require('node:fs').writeFileSync(__filename + '.guardian', String(process.ppid)); setInterval(() => {}, 1000);",
  );
  const terminal: unknown[] = [];
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      onTerminal: (value) => terminal.push(value),
    });
    await fixture.ready();
    process.kill(Number(await readFile(fixture.spec.ffmpegPath + '.guardian', 'utf8')), 'SIGKILL');
    process.kill(Number(await readFile(join(fixture.dir, 'ready'), 'utf8')), 'SIGKILL');
    await expect.poll(() => terminal.length).toBe(1);
    expect(terminal[0]).toMatchObject({
      encoderExit: null,
      telemetryEOF: true,
      decodedVideo: { ended: true },
    });
    expect(await boundedExit(pipeline)).toBe('timed out');
  } finally {
    await fixture.cleanup();
  }
});

it.each(['complete', 'malformed', 'truncated'])(
  'drains isolated encoder timing through the guardian: %s',
  async (mode) => {
    const timing =
      mode === 'complete'
        ? 'pre 0 1/30 0\npost 0 1/30 0\npre 1 1/30 1\npost 1 1/30 1\n'
        : mode === 'malformed'
          ? 'SECRET invalid\n'
          : 'pre 0 1/30 0';
    const fixture = await childFixture(
      `require('node:fs').writeSync(3,'frame:0 pts:0 pts_time:0\\nscorebug.source=1\\n');require('node:fs').writeSync(4,${JSON.stringify(timing)});`,
    );
    const terminal: unknown[] = [];
    try {
      const pipeline = startPipeline(fixture.spec, fixture.log, {
        encoderTiming: true,
        onTerminal: (value) => terminal.push(value),
      });
      expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
      const snapshot = pipeline.snapshotEncoderTiming?.();
      expect(snapshot?.ended).toBe(true);
      expect(pipeline.snapshotDecodedVideo?.()).toMatchObject({ ended: true, invalidReason: null });
      if (mode === 'complete')
        expect(snapshot).toMatchObject({
          submittedFrames: 2,
          completedFrames: 2,
          pendingFrames: 0,
          invalidReason: null,
        });
      else expect(snapshot?.invalidReason).toBe(mode === 'malformed' ? 'framing' : 'incomplete');
      expect(terminal).toHaveLength(1);
      expect(terminal[0]).toMatchObject({
        encoderTiming: snapshot,
        decodedVideo: { acceptedFrames: 1, invalidReason: null },
      });
      expect(JSON.stringify(fixture.records)).not.toContain('SECRET');
      expect(pipeline.snapshotEncoderTiming?.()).toEqual(snapshot);
    } finally {
      await fixture.cleanup();
    }
  },
);
it('joins encoder timing EOF on stop and keeps pending frames historical', async () => {
  const fixture = await childFixture(
    "require('node:fs').writeSync(4,'pre 0 1/30 0\\n');setInterval(()=>{},1000);",
  );
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, { encoderTiming: true });
    await fixture.ready();
    await expect.poll(() => pipeline.snapshotEncoderTiming?.()?.pendingFrames).toBe(1);
    pipeline.stop();
    await boundedExit(pipeline);
    const snapshot = pipeline.snapshotEncoderTiming?.();
    expect(snapshot).toMatchObject({
      pendingFrames: 1,
      completedFrames: 0,
      ended: true,
      invalidReason: null,
    });
    expect(pipeline.snapshotEncoderTiming?.()).toEqual(snapshot);
  } finally {
    await fixture.cleanup();
  }
});
it('returns no encoder timing evidence when disabled', async () => {
  const fixture = await childFixture('');
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log);
    await boundedExit(pipeline);
    expect(pipeline.snapshotEncoderTiming?.()).toBeNull();
  } finally {
    await fixture.cleanup();
  }
});

it.each(['valid', 'malformed'])(
  'retains scoped decoder/encoder histories through real child pipes: %s',
  async (mode) => {
    const decoded =
      mode === 'valid'
        ? 'frame:0 pts:0 pts_time:0\nscorebug.source=1\nframe:1 pts:3000 pts_time:0\nscorebug.source=1\n'
        : 'BAD SECRET\n';
    const encoded = 'pre 0 1/30 0\npre 1 1/30 1\npost 0 1/30 0\npost 1 1/30 1\n';
    const fixture = await childFixture(
      `require('node:fs').writeSync(3,${JSON.stringify(decoded)});require('node:fs').writeSync(4,${JSON.stringify(encoded)});`,
    );
    const terminal: unknown[] = [];
    try {
      const pipeline = startPipeline(fixture.spec, fixture.log, {
        encoderTiming: true,
        onTerminal: (value) => terminal.push(value),
      });
      expect(await boundedExit(pipeline)).toEqual({ code: 0, signal: null });
      const processing = pipeline.snapshotProcessing?.();
      expect(pipeline.snapshotProcessingWindow?.()).toBeNull();
      expect(processing).toBeTruthy();
      expect(processing?.decoded.scopeID).toBe(processing?.encoded.scopeID);
      expect(processing?.decoded.ended).toBe(true);
      expect(processing?.encoded.ended).toBe(true);
      expect(processing?.encoded.invalidReason).toBeNull();
      if (mode === 'valid')
        expect(processing?.decoded).toMatchObject({ acceptedFrames: 2, invalidReason: null });
      else expect(processing?.decoded.invalidReason).not.toBeNull();
      expect(terminal).toHaveLength(1);
      expect(terminal[0]).toMatchObject({ decodedFrameHistory: processing?.decoded });
      expect(JSON.stringify(fixture.records)).not.toContain('SECRET');
    } finally {
      await fixture.cleanup();
    }
  },
);

it('joins sanitized terminal stderr before reporting actual encoder exit', async () => {
  const fixture = await childFixture(`
    require('node:fs').writeSync(2, 'Error during demuxing: Input/output error\\n');
    process.on('beforeExit', () => require('node:fs').writeSync(2, 'Error opening output rtmp://SECRET\\n'));
    process.exitCode = 17;
  `);
  const terminals: unknown[] = [];
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      onTerminal: (value) => terminals.push(value),
    });
    expect(await boundedExit(pipeline)).toEqual({ code: 17, signal: null });
    expect(terminals).toHaveLength(1);
    expect(terminals[0]).toMatchObject({
      encoderExit: { code: 17, signal: null },
      diagnostics: { ended: true, counts: { inputReadError: 1, ioError: 1, outputOpenError: 1 } },
    });
    expect(JSON.stringify([terminals, fixture.records])).not.toMatch(
      /SECRET|PULL_PASSWORD|QUERY_SECRET|STREAM_KEY/,
    );
  } finally {
    await fixture.cleanup();
  }
});

it.each([false, true])(
  'bounds stderr drain after encoder exit with packet timing=%s',
  async (packetTiming) => {
    const fixture = await childFixture(`
    const child = require('node:child_process').spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
      stdio: ['ignore', 'ignore', 'inherit'],
    });
    require('node:fs').writeFileSync(__filename + '.descendant', String(child.pid));
    child.unref();
    process.exitCode = 19;
  `);
    const terminals: unknown[] = [];
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      packetTiming,
      decodedGeometry: true,
      onTerminal: (value) => terminals.push(value),
    });
    try {
      await fixture.ready();
      // Stop after leader exit must not leave completion dependent on inherited stderr.
      await new Promise((resolve) => setTimeout(resolve, 100));
      pipeline.stop();
      expect(await boundedExit(pipeline)).toEqual({ code: 19, signal: null });
      expect(terminals).toHaveLength(1);
      expect(terminals[0]).toMatchObject({
        diagnostics: { ended: true, drainTimedOut: true, pipeError: false },
        decodedGeometry: { ended: true, invalidReason: 'drain_timeout' },
      });
      if (packetTiming)
        expect(terminals[0]).toMatchObject({
          packetTiming: { ended: true, drainTimedOut: true, pipeError: false },
        });
      else expect(terminals[0]).not.toHaveProperty('packetTiming');
    } finally {
      const pid = Number(await readFile(fixture.spec.ffmpegPath + '.descendant', 'utf8'));
      try {
        process.kill(pid, 'SIGKILL');
      } catch {}
      await pipeline.waitExit();
      await fixture.cleanup();
    }
  },
);

it('optional decoder delivery timeline closes even when native spawning fails', async () => {
  const pipeline = startPipeline(
    {
      gameId: 'delivery-failure',
      pullUrl: 'unused',
      publishUrl: 'unused',
      scoreFile: '/tmp/score.txt',
      nvenc: false,
      ffmpegPath: '/definitely-not-an-installed-scorebug-encoder',
    },
    createLogger('error'),
    { deliveryTimeline: true },
  );
  await boundedExit(pipeline);
  expect(pipeline.snapshotDecoderDelivery?.()).toMatchObject({
    formatVersion: 1,
    ended: true,
    arrivals: [],
    lastOrdinal: 0,
  });
});

it('joins bounded packet timing through real guardian stderr without leaking raw input', async () => {
  const packet =
    '[aist#0:1/aac @ 0xabc] [info] demuxer -> ist_index:0:1 type:audio pkt_pts:10919 pkt_pts_time:0.121322 pkt_dts:10919 pkt_dts_time:0.121322 duration:1024 duration_time:0.0213333\n';
  const fixture = await childFixture(
    `require('node:fs').writeSync(2, ${JSON.stringify('SECRET rtmp://host/key\n' + packet)}); process.exitCode=23;`,
  );
  const terminals: any[] = [];
  try {
    const pipeline = startPipeline(fixture.spec, fixture.log, {
      packetTiming: true,
      onTerminal: (value: unknown) => terminals.push(value),
    } as any);
    expect(await boundedExit(pipeline)).toEqual({ code: 23, signal: null });
    expect(terminals).toHaveLength(1);
    expect(terminals[0].packetTiming).toMatchObject({
      ended: true,
      diagnosticOnly: true,
      pipeError: false,
      drainTimedOut: false,
      demux: { audio: { packetCount: 1, first: [{ pts: '10919', ptsSeconds: '0.121322' }] } },
    });
    expect(JSON.stringify([terminals, fixture.records])).not.toContain('SECRET');
  } finally {
    await fixture.cleanup();
  }
});

it.each([false, true])(
  'joins geometry through owned guardian stderr only when terminal enabled=%s',
  async (enabled) => {
    const text =
      '[showinfo@scorebug_geometry @ 0xabc] [info] config in time_base: 1/90000, frame_rate: 30/1\n[showinfo@scorebug_geometry @ 0xabc] [info] n:0 pts:0 pts_time:0 duration:3000 duration_time:0.0333333 fmt:yuv420p cl:left sar:1/1 s:1280x720 i:P iskey:1 type:I\nSECRET_URL\n';
    const fixture = await childFixture(
      `require('node:fs').writeSync(2, ${JSON.stringify(text)}); process.exitCode=23;`,
    );
    try {
      const terminals: any[] = [];
      const pipeline = startPipeline(fixture.spec, fixture.log, {
        decodedGeometry: true,
        ...(enabled ? { onTerminal: (value: any) => terminals.push(value) } : {}),
      } as any);
      expect(await boundedExit(pipeline)).toEqual({ code: 23, signal: null });
      if (enabled)
        expect(terminals[0].decodedGeometry).toMatchObject({
          ended: true,
          invalidReason: null,
          observedFrames: 1,
          runs: [{ width: 1280, height: 720, frames: 1 }],
        });
      else expect(terminals).toEqual([]);
      expect(JSON.stringify(terminals)).not.toContain('SECRET');
    } finally {
      await fixture.cleanup();
    }
  },
);
