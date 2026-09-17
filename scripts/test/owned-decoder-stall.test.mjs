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

test('paused sample is bracketed while the owned decoder is stopped', async () => {
  const events = [],
    value = {
      context: { workerId: 'worker' },
      decoderCadence: { progress: { lastFreshPTS: 90000 } },
    };
  const result = await runOwnedDecoderStall({
    worker: { pid: 10, exitCode: null, signalCode: null },
    inventory: async () => tree,
    signalProcess: (_, sig) => events.push(sig),
    wait: async () => {},
    save: async () => {},
    observePaused: async () => {
      events.push('sample');
      return value;
    },
  });
  assert.deepEqual(events, ['SIGSTOP', 'sample', 'SIGCONT']);
  assert.deepEqual(result.pausedSample.value, value);
  assert(result.pausedSample.requestStartedAt >= result.pauseSentAt);
  assert(result.pausedSample.receivedAt >= result.pausedSample.requestStartedAt);
  assert(result.pausedSample.receivedAt <= result.resumeSentAt);
});

test('failed paused sample still resumes and joins the owned decoder', async () => {
  const events = [],
    saved = [];
  await assert.rejects(
    runOwnedDecoderStall({
      worker: { pid: 10, exitCode: null, signalCode: null },
      inventory: async () => tree,
      signalProcess: (_, sig) => events.push(sig),
      wait: async () => {},
      save: async (value) => saved.push(structuredClone(value)),
      observePaused: async () => {
        throw new Error('sample timed out');
      },
    }),
    /sample timed out/,
  );
  assert.deepEqual(events, ['SIGSTOP', 'SIGCONT']);
  assert.equal(saved.at(-1).closed, true);
  assert.equal(saved.at(-1).failed, true);
});

test('before-pause sample is bracketed before the signal and independent of paused sample', async () => {
  const events = [];
  const result = await runOwnedDecoderStall({
    worker: { pid: 10, exitCode: null, signalCode: null },
    inventory: async () => tree,
    signalProcess: (_, sig) => events.push(sig),
    wait: async () => {},
    save: async () => {},
    observeBeforePause: async () => {
      events.push('before');
      return { stage: 'before' };
    },
    observePaused: async () => {
      events.push('paused');
      return { stage: 'paused' };
    },
  });
  assert.deepEqual(events, ['before', 'SIGSTOP', 'paused', 'SIGCONT']);
  assert(result.beforePauseSample.requestStartedAt <= result.beforePauseSample.receivedAt);
  assert(result.beforePauseSample.receivedAt <= result.pauseSentAt);
  assert.equal(result.beforePauseSample.value.stage, 'before');
  assert.equal(result.pausedSample.value.stage, 'paused');
});

test('failed pre-pause sample sends no signal and marks joined failure', async () => {
  const events = [],
    saved = [];
  await assert.rejects(
    runOwnedDecoderStall({
      worker: { pid: 10, exitCode: null, signalCode: null },
      inventory: async () => tree,
      signalProcess: (_, sig) => events.push(sig),
      wait: async () => {},
      save: async (value) => saved.push(structuredClone(value)),
      observeBeforePause: async () => {
        throw new Error('before sample timed out');
      },
    }),
    /before sample timed out/,
  );
  assert.deepEqual(events, []);
  assert.equal(saved.at(-1).closed, true);
  assert.equal(saved.at(-1).failed, true);
});
