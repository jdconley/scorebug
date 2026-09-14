import { copyFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { PassThrough } from 'node:stream';
import { test } from 'node:test';
import { NativeWorkerEvidence, observeNativeWorkerEvidence } from '../native-worker-evidence.mjs';

const scope = { gameId: '53b19343-199a-4b50-8ab5-c0abc97b8d64', generation: 1, pipelineOrdinal: 1 };
const terminal = {
  msg: 'worker_pipeline_terminal',
  ...scope,
  decodedVideo: {
    acceptedFrames: 3,
    freshFrames: 2,
    duplicateFrames: 1,
    reorderedFrames: 0,
    firstPTS: -3000,
    lastPTS: 0,
    highestPTS: 0,
    timeBase: '1/90000',
    invalidReason: null,
    ended: true,
  },
  telemetryEOF: true,
  encoderExit: { code: 255, signal: null },
  outputProgress: { frame: 2, outTimeUs: 33333 },
};
const push = (collector, event) => collector.push(Buffer.from(JSON.stringify(event) + '\n'));

test('retains scoped terminal evidence and removes unknown fields at every level', () => {
  const collector = new NativeWorkerEvidence();
  push(collector, {
    ...terminal,
    password: 'SECRET',
    decodedVideo: { ...terminal.decodedVideo, url: 'SECRET' },
    encoderExit: { ...terminal.encoderExit, error: 'SECRET' },
  });
  push(collector, {
    msg: 'worker_state',
    state: 'stopping',
    reason: 'source_unavailable',
    ...scope,
    token: 'SECRET',
  });
  push(collector, { msg: 'unrecognized', raw: 'SECRET' });
  collector.end();
  const result = collector.snapshot();
  assert.equal(result.events.length, 2);
  assert.deepEqual(result.events[0], { sequence: 1, ...terminal });
  assert.equal(result.events[1].reason, 'source_unavailable');
  assert.equal(result.events[1].pipelineOrdinal, undefined);
  assert.equal(result.discardedLines, 1);
  assert.ok(!JSON.stringify(result).includes('SECRET'));
});

test('bounds lines and events, records invalid/incomplete evidence and freezes on end', () => {
  const collector = new NativeWorkerEvidence();
  collector.push(Buffer.from('SECRET'.repeat(2000) + '\n'));
  collector.push(Buffer.from('{bad SECRET}\n'));
  push(collector, { ...terminal, generation: 0 });
  for (let i = 0; i < 260; i++) push(collector, terminal);
  collector.push(Buffer.from('unfinished SECRET'));
  collector.end();
  const result = collector.snapshot();
  assert.equal(result.events.length, 256);
  assert.equal(result.omittedEvents, 4);
  assert.equal(result.oversizedLines, 1);
  assert.equal(result.invalidLines, 2);
  assert.equal(result.incompleteLine, true);
  push(collector, terminal);
  assert.deepEqual(collector.snapshot(), result);
  result.events.length = 0;
  assert.equal(collector.snapshot().events.length, 256);
  assert.ok(!JSON.stringify(collector.snapshot()).includes('SECRET'));
});

test('rejects contradictory counters and unknown values but preserves explicit invalid diagnostics', () => {
  const collector = new NativeWorkerEvidence();
  push(collector, { ...terminal, decodedVideo: { ...terminal.decodedVideo, acceptedFrames: 4 } });
  push(collector, { ...terminal, encoderExit: { code: null, signal: 'SECRET' } });
  push(collector, {
    ...terminal,
    decodedVideo: { ...terminal.decodedVideo, invalidReason: 'incomplete' },
    encoderExit: null,
    telemetryEOF: false,
  });
  collector.end();
  assert.equal(collector.snapshot().invalidLines, 2);
  assert.equal(collector.snapshot().events[0].encoderExit, null);
  assert.equal(collector.snapshot().events[0].decodedVideo.invalidReason, 'incomplete');
});

test('owned observation saves once after actual close including final stdout and spawn errors', async () => {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.kill = (signal) => {
    child.emit('sent-signal', signal);
    return true;
  };
  let saves = 0,
    saved;
  const observer = observeNativeWorkerEvidence(child, async (value) => {
    saves++;
    saved = value;
  });
  const saving = observer.save();
  assert.equal(saves, 0);
  observer.signal('SIGTERM');
  child.emit('error', new Error('SECRET'));
  child.stdout.end(JSON.stringify(terminal) + '\n');
  await new Promise((resolve) => child.stdout.once('end', resolve));
  assert.equal(saves, 0, 'stdout EOF is not worker close');
  child.emit('close', 0, null);
  await Promise.all([saving, observer.save(), observer.closed]);
  assert.equal(saves, 1);
  assert.deepEqual(saved.workerExit, { code: 0, signal: null });
  assert.equal(saved.workerError, true);
  assert.equal(saved.stdoutEnded, true);
  assert.deepEqual(saved.fixtureSignals, ['SIGTERM']);
  assert.equal(saved.events[0].msg, 'worker_pipeline_terminal');
  assert.ok(!JSON.stringify(saved).includes('SECRET'));
});

test('failed evidence persistence is memoized and incomplete stdout stays explicit', async () => {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  let attempts = 0;
  const observer = observeNativeWorkerEvidence(child, async () => {
    attempts++;
    throw new Error('disk');
  });
  child.stdout.write('partial');
  child.emit('close', null, 'SIGKILL');
  await assert.rejects(observer.save(), /disk/);
  await assert.rejects(observer.save(), /disk/);
  assert.equal(attempts, 1);
});

test(
  'real worker close preserves final buffered stdout before saving',
  { timeout: 5000 },
  async () => {
    let saved;
    const validChild = spawn(
      process.execPath,
      ['-e', 'process.stdout.write(process.argv[1]);', JSON.stringify(terminal) + '\n'],
      {
        stdio: ['ignore', 'pipe', 'ignore'],
      },
    );
    const validObserver = observeNativeWorkerEvidence(validChild, async (value) => {
      saved = value;
    });
    await validObserver.save();
    assert.equal(saved.workerExit.code, 0);
    assert.equal(saved.events.length, 1);
    assert.equal(saved.events[0].decodedVideo.acceptedFrames, 3);
  },
);

test('signal names must be scalar strings and cannot be coerced from JSON containers', () => {
  const collector = new NativeWorkerEvidence();
  for (const signal of [['SIGTERM'], { toString: 'SIGTERM' }])
    push(collector, { ...terminal, encoderExit: { code: null, signal } });
  collector.end();
  assert.equal(collector.snapshot().invalidLines, 2);
  assert.equal(collector.snapshot().events.length, 0);
});

test('collector loads before the native runner builds workspace packages', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'scorebug-evidence-import-'));
  try {
    const module = join(directory, 'collector.mjs');
    await copyFile(new URL('../native-worker-evidence.mjs', import.meta.url), module);
    const loaded = await import(pathToFileURL(module).href);
    assert.equal(new loaded.NativeWorkerEvidence().snapshot().events.length, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
