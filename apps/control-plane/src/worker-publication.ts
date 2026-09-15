import type { WorkerMediaStatusResponse } from '@scorebug/protocol';
import type { WorkerObservations } from './worker-observations.js';
import type { RelayLifecycle } from './relay-lifecycle.js';
import { canonical } from './canonical-json.js';

/** Re-sample after private I/O; delayed evidence must never cross a reporting scope. */
export async function publicationStatus(
  gameId: string,
  observations: WorkerObservations,
  relay?: RelayLifecycle,
): Promise<WorkerMediaStatusResponse> {
  const initial = observations.status(gameId);
  const before = observations.readScope(initial);
  if (!before || !relay) return initial;
  let publication;
  try {
    publication = await relay.publication(before);
  } catch {
    // Diagnostic availability never turns ordinary status into a control failure.
  }
  const latest = observations.status(gameId);
  const after = observations.readScope(latest);
  if (publication && after && canonical(before) === canonical(after))
    latest.status.publication = publication;
  return latest;
}
