import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveDecoderIdentity, runOwnedDecoderStall } from '../owned-decoder-stall.mjs';
const { revalidateDecoderIdentity } = await import('../owned-decoder-stall.mjs');
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
  await assert.rejects(
    runOwnedDecoderStall({
      worker: { pid: 10, exitCode: null, signalCode: null },
      inventory: async () =>
        events.length === 0
          ? tree
          : tree.map((r) => (r.pid === 12 ? { ...r, start: 'replacement' } : r)),
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
  assert.equal(result.delayBeforePauseMs, 20000);
  assert.equal(saved[0].delayBeforePauseMs, 20000);
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

test('measured recovery records the 70-second schedule with before and paused observations', async () => {
  const events = [],
    saved = [];
  const result = await runOwnedDecoderStall({
    worker: { pid: 10, exitCode: null, signalCode: null },
    delayBeforePauseMs: 70000,
    inventory: async () => tree,
    signalProcess: (pid, sig) => events.push([pid, sig]),
    wait: async (ms) => events.push(ms),
    save: async (value) => saved.push(structuredClone(value)),
    observeBeforePause: async () => {
      events.push('before');
      return { stage: 'before' };
    },
    observePaused: async () => {
      events.push('paused');
      return { stage: 'paused' };
    },
  });
  assert.deepEqual(events, [70000, 'before', [12, 'SIGSTOP'], 1800, 'paused', [12, 'SIGCONT']]);
  assert(saved.every((value) => value.delayBeforePauseMs === 70000));
  assert.equal(result.closed, true);
  assert.equal(result.failed, false);
  assert(result.beforePauseSample.receivedAt <= result.pauseSentAt);
  assert(result.pausedSample.requestStartedAt >= result.pauseSentAt);
  assert(result.pausedSample.receivedAt <= result.resumeSentAt);
});

test('unapproved fault schedules fail before waiting or signalling', async () => {
  for (const delayBeforePauseMs of [
    null,
    0,
    1800,
    19999,
    20001,
    69999,
    70001,
    '70000',
    NaN,
    Infinity,
  ]) {
    const events = [];
    await assert.rejects(
      runOwnedDecoderStall({
        worker: { pid: 10, exitCode: null, signalCode: null },
        delayBeforePauseMs,
        inventory: async () => {
          events.push('inventory');
          return tree;
        },
        signalProcess: (pid, sig) => events.push([pid, sig]),
        wait: async (ms) => events.push(ms),
        save: async () => {},
      }),
      /schedule/,
    );
    assert.deepEqual(events, []);
  }
});

test('70-second schedule joins cancellation before and during pause', async () => {
  for (const cancelAt of [1, 2]) {
    const events = [],
      waits = [],
      saved = [];
    await assert.rejects(
      runOwnedDecoderStall({
        worker: { pid: 10, exitCode: null, signalCode: null },
        delayBeforePauseMs: 70000,
        inventory: async () => tree,
        signalProcess: (pid, sig) => events.push([pid, sig]),
        wait: async (ms) => {
          waits.push(ms);
          if (waits.length === cancelAt) throw new Error('cancelled');
        },
        save: async (value) => saved.push(structuredClone(value)),
      }),
      /cancelled/,
    );
    assert.deepEqual(waits, cancelAt === 1 ? [70000] : [70000, 1800]);
    assert.deepEqual(
      events,
      cancelAt === 1
        ? []
        : [
            [12, 'SIGSTOP'],
            [12, 'SIGCONT'],
          ],
    );
    assert.equal(saved.at(-1).closed, true);
    assert.equal(saved.at(-1).failed, true);
    assert.equal(saved.at(-1).delayBeforePauseMs, 70000);
  }
});

test('70-second schedule refuses to resume a replaced decoder, guardian, or worker', async () => {
  for (const replacedPID of [10, 11, 12]) {
    const events = [],
      waits = [],
      saved = [];
    await assert.rejects(
      runOwnedDecoderStall({
        worker: { pid: 10, exitCode: null, signalCode: null },
        delayBeforePauseMs: 70000,
        inventory: async () =>
          events.length === 0
            ? tree
            : tree.map((row) => (row.pid === replacedPID ? { ...row, start: 'replacement' } : row)),
        signalProcess: (pid, sig) => events.push([pid, sig]),
        wait: async (ms) => waits.push(ms),
        save: async (value) => saved.push(structuredClone(value)),
      }),
      /identity changed/,
    );
    assert.deepEqual(waits, [70000, 1800]);
    assert.deepEqual(events, [[12, 'SIGSTOP']]);
    assert.equal(saved.at(-1).closed, true);
    assert.equal(saved.at(-1).failed, true);
  }
});

test('replacement during before-pause sampling sends no signal to the stale identity', async () => {
  for (const replacedPID of [10, 11, 12]) {
    const events = [],
      saved = [];
    let sampled = false;
    await assert.rejects(
      runOwnedDecoderStall({
        worker: { pid: 10, exitCode: null, signalCode: null },
        delayBeforePauseMs: 70000,
        inventory: async () =>
          sampled
            ? tree.map((row) => (row.pid === replacedPID ? { ...row, start: 'replacement' } : row))
            : tree,
        observeBeforePause: async () => {
          sampled = true;
          return { stage: 'before' };
        },
        signalProcess: (pid, sig) => events.push([pid, sig]),
        wait: async () => {},
        save: async (value) => saved.push(structuredClone(value)),
      }),
      /identity changed/,
    );
    assert.deepEqual(events, []);
    assert.equal(saved.at(-1).closed, true);
    assert.equal(saved.at(-1).failed, true);
    assert.equal(saved.at(-1).pauseSentAt, null);
    assert.equal(saved.at(-1).resumeSentAt, null);
  }
});

test('cancellation during before-pause sampling sends no pause signal', async () => {
  const controller = new AbortController(),
    events = [],
    saved = [];
  await assert.rejects(
    runOwnedDecoderStall({
      worker: { pid: 10, exitCode: null, signalCode: null },
      delayBeforePauseMs: 70000,
      signal: controller.signal,
      inventory: async () => tree,
      observeBeforePause: async () => {
        controller.abort(new Error('cancelled during sample'));
        return { stage: 'before' };
      },
      signalProcess: (pid, sig) => events.push([pid, sig]),
      wait: async () => {},
      save: async (value) => saved.push(structuredClone(value)),
    }),
    /cancelled during sample/,
  );
  assert.deepEqual(events, []);
  assert.equal(saved.at(-1).closed, true);
  assert.equal(saved.at(-1).failed, true);
  assert.equal(saved.at(-1).pauseSentAt, null);
});

const psTree = tree.map((row) => ({ ...row, start: 'Thu Sep 17 10:00:00 2026' }));
const psOutput = (rows) =>
  rows.map((row) => `${row.pid} ${row.ppid} ${row.start} ${row.command}`).join('\n') + '\n';

test('scoped identity revalidation queries only known PIDs and excludes process arguments', async () => {
  assert.equal(typeof revalidateDecoderIdentity, 'function');
  const identity = resolveDecoderIdentity(psTree, 10),
    calls = [];
  const result = await revalidateDecoderIdentity(identity, {
    execute: async (...args) => {
      calls.push(args);
      return { stdout: psOutput([...psTree].reverse()) };
    },
  });
  assert.deepEqual(result, identity);
  assert.deepEqual(calls, [
    [
      '/bin/ps',
      ['-p', '10,11,12', '-o', 'pid=,ppid=,lstart=,comm='],
      { timeout: 1500, maxBuffer: 65536 },
    ],
  ]);
});

test('pre-pause scoped revalidation replaces discovery without changing resume inventory', async () => {
  const events = [],
    identity = resolveDecoderIdentity(tree, 10);
  await runOwnedDecoderStall({
    worker: { pid: 10, exitCode: null, signalCode: null },
    inventory: async () => {
      events.push('inventory');
      return tree;
    },
    observeBeforePause: async () => {
      events.push('sample');
      return {};
    },
    revalidate: async (known) => {
      events.push('revalidate');
      assert.deepEqual(known, identity);
      return structuredClone(identity);
    },
    signalProcess: (pid, sig) => events.push([pid, sig]),
    wait: async () => {},
    save: async () => {},
  });
  assert.deepEqual(events, [
    'inventory',
    'sample',
    'revalidate',
    [12, 'SIGSTOP'],
    'inventory',
    [12, 'SIGCONT'],
  ]);
});

test('missing or changed scoped identity rows never receive a pause signal', async () => {
  assert.equal(typeof revalidateDecoderIdentity, 'function');
  for (const pid of [10, 11, 12]) {
    for (const mutation of ['missing', 'start', 'ppid', 'command', 'pid']) {
      const rows =
        mutation === 'missing'
          ? psTree.filter((row) => row.pid !== pid)
          : psTree.map((row) =>
              row.pid !== pid
                ? row
                : {
                    ...row,
                    [mutation]: {
                      start: 'Thu Sep 17 10:00:01 2026',
                      ppid: 99,
                      command: '/other/' + row.command.split('/').at(-1),
                      pid: 99,
                    }[mutation],
                  },
            );
      const events = [],
        saved = [];
      await assert.rejects(
        runOwnedDecoderStall({
          worker: { pid: 10, exitCode: null, signalCode: null },
          inventory: async () => psTree,
          revalidate: (identity) =>
            revalidateDecoderIdentity(identity, {
              execute: async () => ({ stdout: psOutput(rows) }),
            }),
          signalProcess: (pid, sig) => events.push([pid, sig]),
          wait: async () => {},
          save: async (value) => saved.push(structuredClone(value)),
        }),
      );
      assert.deepEqual(events, [], `${pid} ${mutation}`);
      assert.equal(saved.at(-1).failed, true);
      assert.equal(saved.at(-1).pauseSentAt, null);
    }
  }
});

test('cancellation during scoped revalidation sends no pause signal', async () => {
  const controller = new AbortController(),
    events = [];
  await assert.rejects(
    runOwnedDecoderStall({
      worker: { pid: 10, exitCode: null, signalCode: null },
      signal: controller.signal,
      inventory: async () => tree,
      revalidate: async (identity) => {
        controller.abort(new Error('cancelled during revalidation'));
        return identity;
      },
      signalProcess: (pid, sig) => events.push([pid, sig]),
      wait: async () => {},
      save: async () => {},
    }),
    /cancelled during revalidation/,
  );
  assert.deepEqual(events, []);
});
