import { expect, it, vi } from 'vitest';
import * as diagnostics from '../src/worker-terminal.js';
import type { Logger } from '../src/logger.js';

const fixture = () => {
  const records: unknown[] = [];
  const append = (msg: string, meta?: Record<string, unknown>) => records.push({ msg, ...meta });
  const log: Logger = { debug: append, info: append, warn: append, error: append };
  return { log, records };
};

it.each([undefined, '', '0', 'true', '01', '1 ', ' 1'])(
  'requires the exact diagnostic flag (%s)',
  (flag) => {
    const { log, records } = fixture();
    const factory = diagnostics.createWorkerTerminalDiagnostics(log, flag);
    const scope = factory.scope({ gameId: 'game', generation: 5 });
    expect(factory.enabled).toBe(false);
    expect(scope.log).toBe(log);
    expect(scope.onTerminal).toBeUndefined();
    expect(records).toEqual([]);
  },
);

it('assigns worker-local ordinals across retries and scopes pipeline events and terminal', () => {
  const { log, records } = fixture();
  const factory = diagnostics.createWorkerTerminalDiagnostics(log, '1');
  for (const generation of [5, 5, 6]) {
    const scope = factory.scope({ gameId: 'game', generation });
    scope.log.info('ffmpeg_spawning', { gameId: 'wrong', nvenc: false });
    scope.onTerminal?.({
      telemetryEOF: true,
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
  }
  expect(factory.enabled).toBe(true);
  expect(records).toHaveLength(6);
  for (let i = 0; i < 3; i++) {
    expect(records[2 * i]).toMatchObject({
      msg: 'ffmpeg_spawning',
      gameId: 'game',
      generation: i === 2 ? 6 : 5,
      pipelineOrdinal: i + 1,
    });
    expect(records[2 * i + 1]).toMatchObject({
      msg: 'worker_pipeline_terminal',
      gameId: 'game',
      generation: i === 2 ? 6 : 5,
      pipelineOrdinal: i + 1,
      encoderExit: null,
    });
  }
});

it('joins diagnostic stdout flush and bounds a stalled callback', async () => {
  vi.useFakeTimers();
  try {
    let callback: (() => void) | undefined;
    let resolved = false;
    const output = {
      write: (_: string, cb: () => void) => {
        callback = cb;
        return true;
      },
    };
    const flushed = diagnostics.flushWorkerDiagnostics(output).then(() => {
      resolved = true;
    });
    await Promise.resolve();
    expect(resolved).toBe(false);
    callback?.();
    await flushed;
    expect(resolved).toBe(true);
    const stalled = diagnostics.flushWorkerDiagnostics({ write: () => true });
    await vi.advanceTimersByTimeAsync(250);
    await stalled;
    expect(vi.getTimerCount()).toBe(0);
  } finally {
    vi.useRealTimers();
  }
});

it('routes diagnostic warnings and errors through the real logger stdout channel only when enabled', async () => {
  const { createLogger } = await import('../src/logger.js');
  const info = vi.spyOn(console, 'info').mockImplementation(() => {});
  const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
  const error = vi.spyOn(console, 'error').mockImplementation(() => {});
  try {
    const log = createLogger('info');
    const enabled = diagnostics
      .createWorkerTerminalDiagnostics(log, '1')
      .scope({ gameId: 'game', generation: 2 });
    enabled.log.warn('ffmpeg_terminal_callback_failed');
    enabled.log.error('ffmpeg_guardian_lost');
    expect(info.mock.calls.map(([line]) => JSON.parse(line))).toEqual([
      expect.objectContaining({
        msg: 'ffmpeg_terminal_callback_failed',
        gameId: 'game',
        generation: 2,
        pipelineOrdinal: 1,
      }),
      expect.objectContaining({
        msg: 'ffmpeg_guardian_lost',
        gameId: 'game',
        generation: 2,
        pipelineOrdinal: 1,
      }),
    ]);
    expect(warn).not.toHaveBeenCalled();
    expect(error).not.toHaveBeenCalled();
    const disabled = diagnostics
      .createWorkerTerminalDiagnostics(log, undefined)
      .scope({ gameId: 'game', generation: 2 });
    disabled.log.warn('ffmpeg_terminal_callback_failed');
    disabled.log.error('ffmpeg_guardian_lost');
    expect(info).toHaveBeenCalledTimes(2);
    expect(warn).toHaveBeenCalledTimes(1);
    expect(error).toHaveBeenCalledTimes(1);
  } finally {
    vi.restoreAllMocks();
  }
});
