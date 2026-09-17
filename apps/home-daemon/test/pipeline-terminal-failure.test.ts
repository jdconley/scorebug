import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { expect, it, vi } from 'vitest';
const { fork } = vi.hoisted(() => ({ fork: vi.fn() }));
vi.mock('node:child_process', () => ({ fork }));
import { startPipeline } from '../src/pipeline.js';

const spec = {
  gameId: 'game',
  pullUrl: 'SECRET',
  publishUrl: 'SECRET',
  scoreFile: '/tmp/score.txt',
  nvenc: false,
};
const log = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() };

it('emits one unknown terminal on a synchronous guardian spawn failure', async () => {
  fork.mockImplementationOnce(() => {
    throw new Error('SECRET');
  });
  const terminal = vi.fn();
  const pipeline = startPipeline(spec, log, { onTerminal: terminal });
  expect(await pipeline.waitExit()).toEqual({ code: null, signal: null });
  expect(terminal).toHaveBeenCalledExactlyOnceWith({
    decoderCadence: expect.objectContaining({
      ended: true,
      progress: null,
      oneSecond: null,
      twoSeconds: null,
    }),
    telemetryEOF: false,
    encoderExit: null,
    outputProgress: null,
    decodedVideo: {
      acceptedFrames: 0,
      freshFrames: 0,
      duplicateFrames: 0,
      reorderedFrames: 0,
      firstPTS: null,
      lastPTS: null,
      highestPTS: null,
      timeBase: '1/90000',
      invalidReason: null,
      ended: true,
    },
  });
});

it('waits for close after a guardian pre-spawn error and contains throwing terminal/log observers', async () => {
  const child = Object.assign(new EventEmitter(), {
    pid: undefined,
    connected: false,
    stdout: new PassThrough(),
    stdio: [null, null, null, null, new PassThrough(), new PassThrough()],
  });
  fork.mockReturnValueOnce(child);
  const terminal = vi.fn(() => {
    throw new Error('SECRET');
  });
  const pipeline = startPipeline(
    spec,
    {
      ...log,
      warn: () => {
        throw new Error('LOGGER_SECRET');
      },
    },
    { onTerminal: terminal },
  );
  let resolved = false;
  void pipeline.waitExit().then(() => {
    resolved = true;
  });
  child.emit('error', new Error('SECRET'));
  await Promise.resolve();
  expect(terminal).not.toHaveBeenCalled();
  expect(resolved).toBe(false);
  child.stdio[4]!.emit('end');
  expect(() => child.emit('close', -2, null)).not.toThrow();
  expect(await pipeline.waitExit()).toEqual({ code: null, signal: null });
  expect(terminal).toHaveBeenCalledTimes(1);
  expect(terminal.mock.calls[0]![0]).toMatchObject({ telemetryEOF: true, encoderExit: null });
  child.emit('close');
  expect(terminal).toHaveBeenCalledTimes(1);
});

it('seals the cadence owner on pre-spawn failure without manufacturing a stall', async () => {
  fork.mockImplementationOnce(() => {
    throw new Error('spawn');
  });
  const pipeline = startPipeline(spec, log);
  await pipeline.waitExit();
  expect(pipeline.snapshotDecoderCadence?.()).toMatchObject({
    ended: true,
    progress: null,
    oneSecond: null,
    twoSeconds: null,
  });
});

it('samples one-second stalls from the real dedicated pipe and joins its final snapshot', async () => {
  let now = 100;
  const pipe = new PassThrough();
  const child = Object.assign(new EventEmitter(), {
    pid: 1,
    connected: true,
    send: vi.fn(),
    stdout: new PassThrough(),
    stdio: [null, null, null, null, pipe, new PassThrough()],
    exitCode: null,
    signalCode: null,
  });
  fork.mockReturnValueOnce(child);
  const terminal = vi.fn();
  const pipeline = startPipeline(spec, log, { monotonicNow: () => now, onTerminal: terminal });
  pipe.write('frame:0 pts:0 pts_time:0\nscorebug.source=1\n');
  now = 1100;
  const live = pipeline.snapshotDecoderCadence?.();
  expect(live).toMatchObject({
    ended: false,
    progress: { lastFreshPTS: 0, ageMs: 1000, stalled: true },
    oneSecond: { freshFrames: 1 },
  });
  pipe.end();
  child.emit('message', { event: 'exit', code: 0, signal: null });
  child.emit('close', 0, null);
  expect(await pipeline.waitExit()).toEqual({ code: 0, signal: null });
  const final = pipeline.snapshotDecoderCadence?.();
  expect(final).toMatchObject({ ended: true, progress: { stalled: false } });
  expect(final?.scopeID).toBe(live?.scopeID);
  expect(terminal.mock.calls[0]?.[0]?.decoderCadence).toEqual(final);
});
