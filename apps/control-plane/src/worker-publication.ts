import type { WorkerMediaStatusResponse } from '@scorebug/protocol';
import type { WorkerObservations } from './worker-observations.js';
import type { RelayLifecycle } from './relay-lifecycle.js';
import { canonical } from './canonical-json.js';

/** Re-sample after private I/O; delayed evidence must never cross a reporting scope. */
export async function publicationStatus(
  gameId: string,
  observations: WorkerObservations,
  relay?: RelayLifecycle,
  monotonicNow: () => number = () => performance.now(),
): Promise<WorkerMediaStatusResponse> {
  const initial = observations.status(gameId);
  const before = observations.readScope(initial);
  if (!before || !relay) return initial;
  const started = monotonicNow();
  let found;
  try {
    found = await relay.publication(before);
  } catch {
    // Diagnostic availability never turns ordinary status into a control failure.
  }
  const latest = observations.status(gameId);
  const after = observations.readScope(latest);
  if (found && after && canonical(before) === canonical(after)) {
    latest.status.publication = found.publication;
    // Snapshot is generated during the authenticated relay GET; include all private
    // I/O and final status sampling. Native callers add their full request duration.
    const elapsed = monotonicNow() - started;
    const ageUpperBoundMs = Math.ceil(elapsed);
    if (
      found.receiverProbe &&
      Number.isFinite(started) &&
      started >= 0 &&
      elapsed >= 0 &&
      Number.isSafeInteger(ageUpperBoundMs)
    )
      latest.status.receiverProbe = { snapshot: found.receiverProbe, ageUpperBoundMs };
  }
  return latest;
}
