import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { WorkerSupervisor, type WorkerInput, type WorkerState } from '../src/supervisor.js';
import type { PipelineHandle, PipelineProgress } from '../src/pipeline.js';

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}
const input = (overrides: Partial<WorkerInput> = {}): WorkerInput => ({
  gameId: 'game',
  generation: 1,
  scoreRevision: 1,
  overlay: 'ONE',
  readUrl: 'rtsp://relay/game',
  sourceReady: true,
  outputId: 'local',
  ...overrides,
});
function rig(options: Record<string, unknown> = {}) {
  let current: WorkerInput | null = input();
  const events: string[] = [];
  const states: WorkerState[] = [];
  const children: {
    handle: PipelineHandle;
    progress: (p: PipelineProgress) => void;
    exit: () => void;
    stops: number;
  }[] = [];
  const load = vi.fn(async () => current);
  const writeScore = vi.fn(async (_path: string, text: string) => {
    events.push(`write:${text}`);
  });
  const start = vi.fn((next: WorkerInput, progress: (p: PipelineProgress) => void) => {
    events.push(`start:${next.generation}`);
    const exit = deferred<{ code: number | null; signal: NodeJS.Signals | null }>();
    const child = {
      handle: undefined as unknown as PipelineHandle,
      progress,
      exit: () => exit.resolve({ code: 0, signal: null }),
      stops: 0,
    };
    child.handle = {
      spec: {} as PipelineHandle['spec'],
      stop: () => {
        child.stops++;
      },
      waitExit: () => exit.promise,
    };
    children.push(child);
    return child.handle;
  });
  const supervisor = new WorkerSupervisor({
    load,
    writeScore,
    start,
    outputId: 'local',
    scoreFile: '/unused/score',
    now: () => Date.now(),
    onState: (state) => states.push(state),
    ...options,
  });
  return {
    supervisor,
    events,
    states,
    children,
    load,
    writeScore,
    start,
    set: (next: WorkerInput | null) => {
      current = next;
    },
  };
}
async function flush() {
  for (let i = 0; i < 10; i++) await Promise.resolve();
}
beforeEach(() => {
  vi.useFakeTimers();
  vi.setSystemTime(0);
});
afterEach(() => {
  vi.useRealTimers();
});

describe('WorkerSupervisor', () => {
  it('stops reporting the previous assignment when control returns idle', async () => {
    const r = rig();
    await r.supervisor.tick();
    r.set(null);
    const tick = r.supervisor.tick();
    await flush();
    r.children[0]!.exit();
    await tick;
    expect(r.supervisor.observation()).toBeNull();
  });
  it('exposes a credential-free observation of the actual encoder attempt and written score', async () => {
    const r = rig();
    expect(r.supervisor.observation()).toBeNull();
    await r.supervisor.tick();
    expect(r.supervisor.observation()).toEqual({
      gameId: 'game',
      generation: 1,
      state: 'starting',
      reason: null,
      attempt: 1,
      frame: null,
      outTimeUs: null,
      scoreRevision: 1,
    });
    r.children[0]!.progress({ frame: 12, outTimeUs: 400000 });
    const reported = r.supervisor.observation()!;
    expect(reported.state).toBe('producing_output');
    expect(reported.frame).toBe(12);
    expect(JSON.stringify(reported)).not.toContain('relay');
    reported.frame = 999;
    expect(r.supervisor.observation()!.frame).toBe(12);
    r.children[0]!.exit();
    await flush();
    expect(r.supervisor.observation()).toMatchObject({
      state: 'retrying',
      attempt: 1,
      frame: null,
    });
    await vi.advanceTimersByTimeAsync(1000);
    await r.supervisor.tick();
    r.children[1]!.progress({ frame: 1, outTimeUs: 33000 });
    expect(r.supervisor.observation()).toMatchObject({
      state: 'producing_output',
      attempt: 2,
      frame: 1,
    });
  });
  it('does not report a score revision before the overlay write completes', async () => {
    const r = rig();
    await r.supervisor.tick();
    const written = deferred<void>();
    r.writeScore.mockImplementationOnce(() => written.promise);
    r.set(input({ scoreRevision: 2, overlay: 'TWO' }));
    const tick = r.supervisor.tick();
    await flush();
    expect(r.supervisor.observation()!.scoreRevision).toBe(1);
    written.resolve();
    await tick;
    expect(r.supervisor.observation()!.scoreRevision).toBe(2);
  });
  it('writes initial overlay before spawn and reports output only with positive frame and time', async () => {
    const r = rig();
    await r.supervisor.tick();
    expect(r.events).toEqual(['write:ONE', 'start:1']);
    expect(r.states.at(-1)?.state).toBe('starting');
    r.children[0]!.progress({ frame: 0, outTimeUs: 1 });
    expect(r.states.at(-1)?.state).toBe('starting');
    r.children[0]!.progress({ frame: 1, outTimeUs: 1 });
    expect(r.states.at(-1)?.state).toBe('producing_output');
  });
  it('updates a newer score without restart and refuses revision rollback across a restart', async () => {
    const r = rig();
    await r.supervisor.tick();
    r.set(input({ scoreRevision: 3, overlay: 'THREE' }));
    await r.supervisor.tick();
    r.set(input({ scoreRevision: 2, overlay: 'TWO' }));
    await r.supervisor.tick();
    expect(r.events).toEqual(['write:ONE', 'start:1', 'write:THREE']);
    r.children[0]!.exit();
    await flush();
    await vi.advanceTimersByTimeAsync(1000);
    await r.supervisor.tick();
    expect(r.events).toEqual(['write:ONE', 'start:1', 'write:THREE', 'write:THREE', 'start:1']);
  });
  it.each([
    ['null', null],
    ['game', input({ gameId: 'other' })],
    ['generation', input({ generation: 2 })],
    ['read URL', input({ readUrl: 'rtsp://other' })],
  ])('awaits actual old exit before replacing %s', async (_name, next) => {
    const r = rig();
    await r.supervisor.tick();
    r.set(next);
    const pending = r.supervisor.tick();
    await flush();
    expect(r.children[0]!.stops).toBe(next ? 1 : 0);
    expect(r.start).toHaveBeenCalledTimes(1);
    r.children[0]!.exit();
    await pending;
    expect(r.start).toHaveBeenCalledTimes(next ? 2 : 1);
    r.children[0]!.progress({ frame: 100, outTimeUs: 100 });
    expect(r.states.at(-1)?.state).not.toBe('producing_output');
  });
  it('fails closed on output mismatch and waits for a missing source', async () => {
    const r = rig();
    r.set(input({ outputId: 'other' }));
    await r.supervisor.tick();
    expect(r.start).not.toHaveBeenCalled();
    expect(r.states.at(-1)?.state).toBe('failed');
    r.set(input({ sourceReady: false }));
    await r.supervisor.tick();
    expect(r.start).not.toHaveBeenCalled();
    expect(r.states.at(-1)?.state).toBe('waiting_source');
    r.set(input());
    await r.supervisor.tick();
    expect(r.start).toHaveBeenCalledTimes(1);
  });
  it('coalesces ticks and stops at the control deadline while a load remains pending', async () => {
    const r = rig({ progressTimeoutMs: 20000 });
    await r.supervisor.tick();
    const load = deferred<WorkerInput | null>();
    r.load.mockImplementation(() => load.promise);
    const pending = r.supervisor.tick();
    void r.supervisor.tick();
    await flush();
    expect(r.load).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(5000);
    expect(r.children[0]!.stops).toBe(1);
    expect(r.states.at(-1)?.reason).toBe('control_timeout');
    r.children[0]!.exit();
    load.resolve(input());
    await pending;
  });
  it('does not extend the control lease on failed loads', async () => {
    const r = rig({ progressTimeoutMs: 20000 });
    await r.supervisor.tick();
    await vi.advanceTimersByTimeAsync(4000);
    r.load.mockRejectedValue(new Error('secret credential'));
    await r.supervisor.tick();
    await vi.advanceTimersByTimeAsync(1000);
    expect(r.children[0]!.stops).toBe(1);
    expect(JSON.stringify(r.states)).not.toContain('secret');
  });
  it.each([false, true])(
    'restores active status after control recovery (output=%s)',
    async (producing) => {
      const r = rig();
      await r.supervisor.tick();
      if (producing) r.children[0]!.progress({ frame: 1, outTimeUs: 1 });
      r.load.mockRejectedValueOnce(new Error('unavailable'));
      await r.supervisor.tick();
      expect(r.states.at(-1)?.reason).toBe('control_unavailable');
      await r.supervisor.tick();
      expect(r.states.at(-1)?.state).toBe(producing ? 'producing_output' : 'starting');
      expect(r.states.at(-1)?.reason).toBeUndefined();
      expect(r.start).toHaveBeenCalledTimes(1);
    },
  );
  it('preserves score revision and overlay when returning to an earlier assignment', async () => {
    const r = rig();
    r.set(input({ scoreRevision: 3, overlay: 'A THREE' }));
    await r.supervisor.tick();
    r.set(input({ gameId: 'other', scoreRevision: 1, overlay: 'B ONE' }));
    const toOther = r.supervisor.tick();
    await flush();
    r.children[0]!.exit();
    await toOther;
    r.set(input({ scoreRevision: 2, overlay: 'A TWO' }));
    const back = r.supervisor.tick();
    await flush();
    r.children[1]!.exit();
    await back;
    expect(r.events).toEqual([
      'write:A THREE',
      'start:1',
      'write:B ONE',
      'start:1',
      'write:A THREE',
      'start:1',
    ]);
    expect(r.start.mock.calls.at(-1)?.[0].scoreRevision).toBe(3);
    r.set(input({ generation: 2, scoreRevision: 1, overlay: 'NEW GENERATION' }));
    const newGeneration = r.supervisor.tick();
    await flush();
    r.children[2]!.exit();
    await newGeneration;
    expect(r.events.at(-2)).toBe('write:NEW GENERATION');
  });
  it('times out missing first output even with zero-frame progress records', async () => {
    const r = rig({ controlTimeoutMs: 20000 });
    await r.supervisor.tick();
    await vi.advanceTimersByTimeAsync(9000);
    r.children[0]!.progress({ frame: 0, outTimeUs: 100 });
    await vi.advanceTimersByTimeAsync(1000);
    expect(r.children[0]!.stops).toBe(1);
    expect(r.states.at(-1)?.reason).toBe('output_timeout');
  });
  it('does not let duplicate or regressing progress postpone an output stall', async () => {
    const r = rig({ controlTimeoutMs: 30000 });
    await r.supervisor.tick();
    r.children[0]!.progress({ frame: 2, outTimeUs: 2 });
    await vi.advanceTimersByTimeAsync(9000);
    r.children[0]!.progress({ frame: 2, outTimeUs: 2 });
    r.children[0]!.progress({ frame: 1, outTimeUs: 3 });
    await vi.advanceTimersByTimeAsync(1000);
    expect(r.children[0]!.stops).toBe(1);
  });
  it('limits retries, spaces attempts, recovers after the window and resets on generation change', async () => {
    const r = rig();
    r.start.mockImplementation(() => {
      throw new Error('secret');
    });
    await r.supervisor.tick();
    await r.supervisor.tick();
    expect(r.start).toHaveBeenCalledTimes(1);
    for (let i = 0; i < 4; i++) {
      await vi.advanceTimersByTimeAsync(1000);
      await r.supervisor.tick();
    }
    expect(r.start).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(56000);
    await r.supervisor.tick();
    expect(r.start).toHaveBeenCalledTimes(4);
    r.set(input({ generation: 2 }));
    await r.supervisor.tick();
    expect(r.start).toHaveBeenCalledTimes(5);
    expect(JSON.stringify(r.states)).not.toContain('secret');
  });
  it('holds score changes for scoreDelayMs and applies them in order', async () => {
    const r = rig({ scoreDelayMs: 1100 });
    await r.supervisor.tick();
    r.set(input({ scoreRevision: 2, overlay: 'TWO' }));
    await r.supervisor.tick();
    await vi.advanceTimersByTimeAsync(500);
    r.set(input({ scoreRevision: 3, overlay: 'THREE' }));
    await r.supervisor.tick();
    await r.supervisor.tick();
    expect(r.events).toEqual(['write:ONE', 'start:1']);
    expect(r.supervisor.observation()!.scoreRevision).toBe(1);
    await vi.advanceTimersByTimeAsync(600);
    expect(r.events).toEqual(['write:ONE', 'start:1', 'write:TWO']);
    expect(r.supervisor.observation()!.scoreRevision).toBe(2);
    await vi.advanceTimersByTimeAsync(500);
    expect(r.events).toEqual(['write:ONE', 'start:1', 'write:TWO', 'write:THREE']);
    expect(r.supervisor.observation()!.scoreRevision).toBe(3);
  });
  it('drops delayed scores of a pipeline that stopped; the restart writes the latest', async () => {
    const r = rig({ scoreDelayMs: 1100 });
    await r.supervisor.tick();
    r.set(input({ scoreRevision: 2, overlay: 'TWO' }));
    await r.supervisor.tick();
    r.children[0]!.exit();
    await flush();
    await vi.advanceTimersByTimeAsync(1100);
    await r.supervisor.tick();
    expect(r.events).toEqual(['write:ONE', 'start:1', 'write:TWO', 'start:1']);
  });
  it('gives back the retry of an attempt that ran past retryFreeAfterMs', async () => {
    const r = rig({ retryFreeAfterMs: 3000, maxAttempts: 2 });
    await r.supervisor.tick();
    for (let i = 0; i < 4; i++) {
      await vi.advanceTimersByTimeAsync(4000);
      r.children.at(-1)!.exit();
      await flush();
      await r.supervisor.tick();
    }
    expect(r.start).toHaveBeenCalledTimes(5);
    // Quick exits still count: two in the window and the worker waits.
    for (let i = 0; i < 3; i++) {
      r.children.at(-1)!.exit();
      await flush();
      await vi.advanceTimersByTimeAsync(1000);
      await r.supervisor.tick();
    }
    expect(r.start).toHaveBeenCalledTimes(6);
    expect(r.states.at(-1)).toMatchObject({ state: 'retrying', reason: 'retry_budget' });
  });
  it('preserves each assignment retry budget when assignments alternate', async () => {
    const r = rig();
    r.start.mockImplementation(() => {
      throw new Error('failed');
    });
    for (let i = 0; i < 3; i++) {
      r.set(input());
      await r.supervisor.tick();
      r.set(input({ gameId: 'other' }));
      await r.supervisor.tick();
      await vi.advanceTimersByTimeAsync(1000);
    }
    expect(r.start).toHaveBeenCalledTimes(6);
    r.set(input());
    await r.supervisor.tick();
    expect(r.start).toHaveBeenCalledTimes(6);
  });
  it('stops an active output on mismatched destination without replacing it', async () => {
    const r = rig();
    await r.supervisor.tick();
    r.set(input({ outputId: 'other' }));
    const tick = r.supervisor.tick();
    await flush();
    expect(r.children[0]!.stops).toBe(1);
    expect(r.start).toHaveBeenCalledTimes(1);
    r.children[0]!.exit();
    await tick;
    expect(r.states.at(-1)?.reason).toBe('output_mismatch');
  });
  it('requires a new control read when exit or initial score write outlasts the lease', async () => {
    const r = rig();
    const write = deferred<void>();
    r.writeScore.mockImplementation(() => write.promise);
    const tick = r.supervisor.tick();
    await flush();
    await vi.advanceTimersByTimeAsync(5000);
    write.resolve();
    await tick;
    expect(r.start).not.toHaveBeenCalled();
    expect(r.states.at(-1)?.reason).toBe('control_timeout');
  });
  it('does not spawn after an initial write failure, and retries the latest overlay', async () => {
    const r = rig();
    r.writeScore.mockRejectedValueOnce(new Error('secret'));
    await r.supervisor.tick();
    expect(r.start).not.toHaveBeenCalled();
    expect(r.states.at(-1)?.reason).toBe('score_write_failed');
    r.set(input({ scoreRevision: 2, overlay: 'TWO' }));
    await vi.advanceTimersByTimeAsync(1000);
    await r.supervisor.tick();
    expect(r.events).toEqual(['write:TWO', 'start:1']);
  });
  it('stops output on a score update failure', async () => {
    const r = rig();
    await r.supervisor.tick();
    r.writeScore.mockRejectedValueOnce(new Error('secret'));
    r.set(input({ scoreRevision: 2 }));
    const pending = r.supervisor.tick();
    await flush();
    expect(r.children[0]!.stops).toBe(1);
    r.children[0]!.exit();
    await pending;
    expect(r.states.some((s) => s.reason === 'score_write_failed')).toBe(true);
  });
  it('close blocks a late load from spawning without waiting for that load', async () => {
    const r = rig();
    const load = deferred<WorkerInput | null>();
    r.load.mockImplementation(() => load.promise);
    const pending = r.supervisor.tick();
    await flush();
    await r.supervisor.close();
    load.resolve(input());
    await pending;
    expect(r.start).not.toHaveBeenCalled();
    expect(r.states.at(-1)?.state).toBe('closed');
    expect(vi.getTimerCount()).toBe(0);
  });
  it('close blocks a late write from spawning and awaits a running child exit', async () => {
    const r = rig();
    await r.supervisor.tick();
    let completed = false;
    const closing = r.supervisor.close().then(() => {
      completed = true;
    });
    await flush();
    expect(completed).toBe(false);
    expect(r.children[0]!.stops).toBe(1);
    r.children[0]!.exit();
    await closing;
    expect(vi.getTimerCount()).toBe(0);
    const other = rig();
    const write = deferred<void>();
    other.writeScore.mockImplementation(() => write.promise);
    const ticking = other.supervisor.tick();
    await flush();
    await other.supervisor.close();
    write.resolve();
    await ticking;
    expect(other.start).not.toHaveBeenCalled();
  });
  it('state observer exceptions cannot break supervision', async () => {
    const r = rig({
      onState: () => {
        throw new Error('observer');
      },
    });
    await expect(r.supervisor.tick()).resolves.toBeUndefined();
    expect(r.start).toHaveBeenCalledTimes(1);
  });
});

it('drains an existing stream on withdrawal without signaling before natural EOF', async () => {
  const r = rig();
  await r.supervisor.tick();
  r.set(null);
  const tick = r.supervisor.tick();
  await flush();
  expect(r.children[0]!.stops).toBe(0);
  expect(r.supervisor.observation()).toMatchObject({
    state: 'stopping',
    reason: 'assignment_changed',
  });
  await vi.advanceTimersByTimeAsync(2000);
  expect(r.children[0]!.stops).toBe(0);
  r.children[0]!.exit();
  await tick;
  expect(r.supervisor.observation()).toBeNull();
  await vi.advanceTimersByTimeAsync(20000);
  expect(r.children[0]!.stops).toBe(0);
});

it('bounds withdrawal drain and lets shutdown interrupt it immediately', async () => {
  for (const shutdown of [false, true]) {
    const r = rig({ drainTimeoutMs: 1000 });
    await r.supervisor.tick();
    r.set(null);
    const tick = r.supervisor.tick();
    await flush();
    expect(r.children[0]!.stops).toBe(0);
    const close = shutdown ? r.supervisor.close() : undefined;
    if (!shutdown) await vi.advanceTimersByTimeAsync(1000);
    expect(r.children[0]!.stops).toBe(1);
    r.children[0]!.exit();
    await tick;
    await close;
    expect(r.supervisor.observation()).not.toMatchObject({ state: 'producing_output' });
  }
});
