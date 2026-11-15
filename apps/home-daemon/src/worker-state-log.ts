import type { Logger } from './logger.js';
import type { WorkerState } from './supervisor.js';

export function createWorkerStateLogger(log: Pick<Logger, 'info'>): (state: WorkerState) => void {
  let previous:
    | readonly [
        WorkerState['state'],
        WorkerState['gameId'],
        WorkerState['generation'],
        WorkerState['reason'],
      ]
    | undefined;
  return (state) => {
    const snapshot = { ...state };
    const identity = [
      snapshot.state,
      snapshot.gameId,
      snapshot.generation,
      snapshot.reason,
    ] as const;
    const last = previous;
    if (last && identity.every((value, index) => value === last[index])) return;
    // Copy metadata separately from the retained primitive identity. A failed log
    // leaves the previous identity intact so the next report can retry it.
    log.info('worker_state', snapshot);
    previous = identity;
  };
}
