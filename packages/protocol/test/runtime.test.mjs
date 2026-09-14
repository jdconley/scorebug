import assert from 'node:assert/strict';
import { test } from 'node:test';

test('compiled protocol exports load in plain Node without a TypeScript loader', async () => {
  const protocol = await import('@scorebug/protocol');
  assert.equal(protocol.WORKER_OBSERVATION_TTL_MS, 5000);
  assert.ok(protocol.WORKER_STATES.includes('producing_output'));
  await import('@scorebug/protocol/messages');
});
