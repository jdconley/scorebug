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
    stdio: [null, null, null, null, new PassThrough()],
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
