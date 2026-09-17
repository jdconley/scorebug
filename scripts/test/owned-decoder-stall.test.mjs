import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveDecoderIdentity, runOwnedDecoderStall } from '../owned-decoder-stall.mjs';
const tree = [
  { pid: 10, ppid: 1, start: 'a', command: '/bin/node' },
  { pid: 11, ppid: 10, start: 'b', command: '/bin/node' },
  { pid: 12, ppid: 11, start: 'c', command: '/bin/ffmpeg' },
];
test('selects exactly the decoder below the owned worker and guardian', () => {
  assert.equal(resolveDecoderIdentity(tree, 10).decoder.pid, 12);
  for (const rows of [
    tree.slice(0, 2),
    [...tree, { pid: 13, ppid: 11, start: 'd', command: '/bin/ffmpeg' }],
    tree.map((r) => (r.pid === 12 ? { ...r, ppid: 1 } : r)),
  ])
    assert.throws(() => resolveDecoderIdentity(rows, 10));
});
test('joins resume after cancellation while paused without signalling other children', async () => {
  const events = [];
  let sleeps = 0;
  const worker = { pid: 10, exitCode: null, signalCode: null };
  await assert.rejects(
    runOwnedDecoderStall({
      worker,
      inventory: async () => tree,
      signalProcess: (pid, sig) => events.push([pid, sig]),
      wait: async () => {
        if (++sleeps === 2) throw new Error('cancelled');
      },
      save: async () => {},
    }),
  );
  assert.deepEqual(events, [
    [12, 'SIGSTOP'],
    [12, 'SIGCONT'],
  ]);
});
test('changed process identity cannot receive a resume signal', async () => {
  const events = [];
  let reads = 0;
  await assert.rejects(
    runOwnedDecoderStall({
      worker: { pid: 10, exitCode: null, signalCode: null },
      inventory: async () =>
        ++reads === 1 ? tree : tree.map((r) => (r.pid === 12 ? { ...r, start: 'replacement' } : r)),
      signalProcess: (pid, sig) => events.push([pid, sig]),
      wait: async () => {},
      save: async () => {},
    }),
  );
  assert.deepEqual(events, [[12, 'SIGSTOP']]);
});
test('successful pause saves closed evidence and uses the bounded schedule', async () => {
  const waits = [],
    events = [],
    saved = [];
  const result = await runOwnedDecoderStall({
    worker: { pid: 10, exitCode: null, signalCode: null },
    inventory: async () => tree,
    signalProcess: (pid, sig) => events.push([pid, sig]),
    wait: async (ms) => waits.push(ms),
    save: async (e) => saved.push(structuredClone(e)),
  });
  assert.deepEqual(waits, [20000, 1800]);
  assert.deepEqual(events, [
    [12, 'SIGSTOP'],
    [12, 'SIGCONT'],
  ]);
  assert.equal(saved[0].closed, false);
  assert.equal(result.closed, true);
  assert.equal(result.failed, false);
  assert.notEqual(result.resumeSentAt, null);
});
test('cancellation before pause never signals a process', async () => {
  const events = [];
  await assert.rejects(
    runOwnedDecoderStall({
      worker: { pid: 10, exitCode: null, signalCode: null },
      inventory: async () => tree,
      signalProcess: (pid, sig) => events.push([pid, sig]),
      wait: async () => {
        throw new Error('cancelled');
      },
      save: async () => {},
    }),
  );
  assert.deepEqual(events, []);
});
test('failed evidence save still resumes the owned decoder', async () => {
  const events = [];
  let saves = 0;
  await assert.rejects(
    runOwnedDecoderStall({
      worker: { pid: 10, exitCode: null, signalCode: null },
      inventory: async () => tree,
      signalProcess: (pid, sig) => events.push([pid, sig]),
      wait: async () => {},
      save: async () => {
        if (++saves === 1) throw new Error('write failed');
      },
    }),
  );
  assert.deepEqual(events, [
    [12, 'SIGSTOP'],
    [12, 'SIGCONT'],
  ]);
});
