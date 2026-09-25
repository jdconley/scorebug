import assert from 'node:assert/strict';
import test from 'node:test';
const implementation = await import('../capacity-clock-exchange.mjs').catch((e) => {
  if (e.code !== 'ERR_MODULE_NOT_FOUND') throw e;
  return {};
});
const scope = {
  recordingID: 'recording',
  matchID: 'match',
  broadcastGeneration: 1,
  publishingAttemptID: '11111111-1111-4111-8111-111111111111',
  appliedProfileRevision: '1',
};
const nonce = '22222222-2222-4222-8222-222222222222';
const reply = () => ({
  formatVersion: 1,
  scope: structuredClone(scope),
  sample: { sequence: 1, nonce, nativeAt: 900001 },
});
const options = () => ({
  scope,
  sequence: 1,
  nonce,
  signal: new AbortController().signal,
  now: () => 100,
  write: async () => {},
  read: async () => reply(),
  wait: async () => {},
});
const exchange = (options) => {
  assert.equal(typeof implementation.sampleCapacityClock, 'function');
  return implementation.sampleCapacityClock(options);
};
test('clock exchange writes owned nonce before accepting matching native reply', async () => {
  let time = 100,
    written;
  const r = await exchange({
    ...options(),
    now: () => time,
    write: async (x) => {
      written = structuredClone(x);
      time += 5;
    },
    read: async () => {
      assert(written);
      time += 15;
      return reply();
    },
  });
  assert.deepEqual(r, { requestAt: 100, responseAt: 120, request: written, response: reply() });
});
test('clock exchange polls absent/previous replies without renewing its deadline', async () => {
  let time = 100,
    reads = 0;
  const r = await exchange({
    ...options(),
    sequence: 2,
    now: () => time,
    wait: async (ms) => {
      time += ms;
    },
    read: async () =>
      ++reads === 1
        ? null
        : reads === 2
          ? {
              ...reply(),
              sample: { ...reply().sample, nonce: '33333333-3333-4333-8333-333333333333' },
            }
          : { ...reply(), sample: { sequence: 2, nonce, nativeAt: 900002 } },
  });
  assert.equal(r.responseAt, 120);
  assert.equal(reads, 3);
});
for (const [name, change] of Object.entries({
  'wrong nonce': (r) => (r.sample.nonce = '33333333-3333-4333-8333-333333333333'),
  'foreign scope': (r) => (r.scope.recordingID = 'other'),
  'future sequence': (r) => (r.sample.sequence = 2),
  'malformed sequence': (r) => (r.sample.sequence = '1'),
  'wrong version': (r) => (r.formatVersion = 2),
  'nonfinite native time': (r) => (r.sample.nativeAt = NaN),
  'extra reply field': (r) => (r.extra = true),
  'extra sample field': (r) => (r.sample.extra = true),
}))
  test(`clock exchange rejects ${name}`, async () => {
    const r = reply();
    change(r);
    await assert.rejects(exchange({ ...options(), read: async () => r }));
  });
test('clock exchange rejects late replies, clock regression and stationary-clock polling', async () => {
  let time = 100;
  await assert.rejects(
    exchange({
      ...options(),
      now: () => time,
      read: async () => {
        time += 251;
        return reply();
      },
    }),
  );
  time = 100;
  await assert.rejects(
    exchange({
      ...options(),
      now: () => time,
      write: async () => {
        time--;
      },
    }),
  );
  let reads = 0;
  await assert.rejects(
    exchange({
      ...options(),
      read: async () => {
        reads++;
        return null;
      },
    }),
  );
  assert.equal(reads, 64);
});
test('clock exchange joins ongoing I/O before reporting cancellation', async () => {
  const controller = new AbortController();
  let release,
    completed = false;
  const pending = exchange({
    ...options(),
    signal: controller.signal,
    write: () =>
      new Promise((resolve) => {
        release = () => {
          completed = true;
          resolve();
        };
      }),
  });
  controller.abort();
  release();
  await assert.rejects(pending);
  assert.equal(completed, true);
});

test('clock exchange rejects reuse of a nonce from an older reply', async () => {
  await assert.rejects(exchange({ ...options(), sequence: 2 }));
});
