import { describe, expect, it, vi } from 'vitest';
import type { WorkerState } from '../src/supervisor.js';
import { createWorkerStateLogger } from '../src/worker-state-log.js';

describe('worker state logging', () => {
  it('logs the first state and suppresses thousands of identical reports', () => {
    const info = vi.fn();
    const onState = createWorkerStateLogger({ info });
    for (let i = 0; i < 2000; i++) onState({ state: 'idle' });
    expect(info.mock.calls).toEqual([['worker_state', { state: 'idle' }]]);
  });

  it('retains every state change and A-B-A transitions', () => {
    const info = vi.fn();
    const onState = createWorkerStateLogger({ info });
    const states: WorkerState['state'][] = [
      'idle',
      'starting',
      'producing_output',
      'stopping',
      'retrying',
      'failed',
      'closed',
      'idle',
      'starting',
      'idle',
    ];
    for (const state of states) {
      onState({ state });
      onState({ state });
    }
    expect(info.mock.calls).toEqual(states.map((state) => ['worker_state', { state }]));
  });

  it('retains scope and reason changes, including optional-field removal', () => {
    const info = vi.fn();
    const onState = createWorkerStateLogger({ info });
    const states: WorkerState[] = [
      { state: 'retrying' },
      { state: 'retrying', gameId: 'a' },
      { state: 'retrying', gameId: 'b' },
      { state: 'retrying', gameId: 'b', generation: 1 },
      { state: 'retrying', gameId: 'b', generation: 2 },
      { state: 'retrying', gameId: 'b', generation: 2, reason: 'retry_delay' },
      { state: 'retrying', gameId: 'b', generation: 2, reason: 'retry_budget' },
      { state: 'retrying', gameId: 'b', generation: 2 },
      { state: 'retrying', gameId: 'b' },
      { state: 'retrying' },
    ];
    for (const state of states) {
      onState(state);
      onState({ ...state });
    }
    expect(info.mock.calls).toEqual(states.map((state) => ['worker_state', state]));
  });

  it('copies caller values and ignores property insertion order', () => {
    const info = vi.fn();
    const onState = createWorkerStateLogger({ info });
    const state: WorkerState = {
      state: 'retrying',
      gameId: 'a',
      generation: 1,
      reason: 'retry_delay',
    };
    onState(state);
    state.generation = 2;
    onState({ reason: 'retry_delay', generation: 1, gameId: 'a', state: 'retrying' });
    expect(info).toHaveBeenCalledTimes(1);
    onState(state);
    expect(info.mock.calls).toEqual([
      ['worker_state', { state: 'retrying', gameId: 'a', generation: 1, reason: 'retry_delay' }],
      ['worker_state', { state: 'retrying', gameId: 'a', generation: 2, reason: 'retry_delay' }],
    ]);
  });

  it('keeps identity independent of mutations by the logging callback', () => {
    const info = vi.fn((_message: string, state: Record<string, unknown> | undefined) => {
      if (state) state.generation = 99;
    });
    const onState = createWorkerStateLogger({ info });
    const state: WorkerState = { state: 'starting', gameId: 'a', generation: 1 };
    onState(state);
    onState({ ...state });
    expect(info).toHaveBeenCalledTimes(1);
    expect(state.generation).toBe(1);
  });

  it('retries a failed log without forgetting the last successfully logged identity', () => {
    const info = vi.fn();
    const onState = createWorkerStateLogger({ info });
    onState({ state: 'idle' });
    info.mockImplementationOnce(() => {
      throw new Error('log unavailable');
    });
    expect(() => onState({ state: 'starting' })).toThrow('log unavailable');
    onState({ state: 'idle' });
    expect(info).toHaveBeenCalledTimes(2);
    onState({ state: 'starting' });
    onState({ state: 'starting' });
    expect(info.mock.calls).toEqual([
      ['worker_state', { state: 'idle' }],
      ['worker_state', { state: 'starting' }],
      ['worker_state', { state: 'starting' }],
    ]);
  });

  it('retries the first state if its first log fails', () => {
    const info = vi.fn().mockImplementationOnce(() => {
      throw new Error('log unavailable');
    });
    const onState = createWorkerStateLogger({ info });
    expect(() => onState({ state: 'idle' })).toThrow('log unavailable');
    onState({ state: 'idle' });
    onState({ state: 'idle' });
    expect(info).toHaveBeenCalledTimes(2);
  });
});
