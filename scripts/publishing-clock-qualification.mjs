import assert from 'node:assert/strict';
import { validatePublishingClockDescriptor } from './publishing-clock-evidence.mjs';

/** Closed native app fixture evidence, not a remote delivery or loss estimate.
 * expectedScope comes from the separately qualified capture/encode observation.
 * App publishing begins after capture, so its chosen origin must not be guessed
 * from the recording start or the first frame decoded by a late-joining worker.
 */
export function qualifyPublishingClockObservation({ snapshot, expectedScope }) {
  assert.ok(expectedScope && typeof expectedScope === 'object' && !Array.isArray(expectedScope));
  assert.deepEqual(snapshot.scope, expectedScope, 'Enclosing clock scope mismatch');
  assert.equal(snapshot.isClosed, true, 'Enclosing observation must be closed');
  const observed = snapshot.publishingClockObservation;
  assert.ok(
    observed && typeof observed === 'object' && !Array.isArray(observed),
    'Missing app publishing clock',
  );
  assert.deepEqual(
    Object.keys(observed).sort(),
    [
      'scope',
      'isClosed',
      'sourceOrigin',
      'publishingGeneration',
      'timescale',
      'presentationLead',
      'wireModulus',
    ].sort(),
    'Publishing clock schema mismatch',
  );
  assert.equal(observed.isClosed, true, 'Publishing clock must be historical after joined stop');
  assert.deepEqual(observed.scope, expectedScope, 'Publishing clock scope mismatch');
  const { scope, isClosed, ...descriptor } = observed;
  const validated = validatePublishingClockDescriptor(descriptor);
  assert.deepEqual(
    Object.keys(validated.sourceOrigin).sort(),
    ['value', 'timescale', 'epoch', 'flags'].sort(),
    'Clock origin schema mismatch',
  );
  return { scope: structuredClone(scope), isClosed, ...validated };
}
