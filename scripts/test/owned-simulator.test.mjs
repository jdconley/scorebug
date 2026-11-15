import test from 'node:test';
import assert from 'node:assert/strict';
import { createOwnedSimulator } from '../owned-simulator.mjs';

test('reconciles a committed simulator after create aborts, deleting only its exact owned name', async () => {
  const calls = [],
    failure = new Error('aborted after server commit');
  const run = async (binary, args, label, options) => {
    calls.push({ binary, args, label, options });
    if (args[1] === 'create') throw failure;
    if (args[1] === 'list')
      return JSON.stringify({
        devices: {
          runtime: [
            { name: 'owned-unique', udid: '00000000-0000-4000-8000-000000000001' },
            { name: 'owned-unique-other', udid: '00000000-0000-4000-8000-000000000002' },
          ],
        },
      });
    return '';
  };
  await assert.rejects(createOwnedSimulator(run, 'owned-unique', 'runtime'), (e) => e === failure);
  assert.deepEqual(
    calls.map((c) => c.args[1]),
    ['create', 'list', 'delete'],
  );
  assert.equal(calls.at(-1).args[2], '00000000-0000-4000-8000-000000000001');
  assert.ok(calls.every((c) => c.options.cleanup === true));
});
test('successful create returns owned ID without reconciliation', async () => {
  let count = 0;
  const id = '00000000-0000-4000-8000-000000000001';
  assert.equal(
    await createOwnedSimulator(
      async () => {
        count++;
        return id;
      },
      'owned',
      'runtime',
    ),
    id,
  );
  assert.equal(count, 1);
});
