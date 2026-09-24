import assert from 'node:assert/strict';
import test from 'node:test';
import { qualifyOwnedPauseSample } from '../native-deadline-decisions.mjs';
const { runRepeatedOwnedDecoderStalls: run } =
  await import('../repeated-owned-decoder-stall.mjs').catch((error) => {
    if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
    throw error;
  });
const id = (n) => `aaaaaaaa-aaaa-4aaa-8aaa-${String(n).padStart(12, '0')}`;
const scope = {
  recordingID: 'r',
  matchID: 'm',
  broadcastGeneration: 1,
  publishingAttemptID: id(1),
  appliedProfileRevision: '0',
};
const tree = [
  { pid: 10, ppid: 1, start: 'a', command: '/bin/node' },
  { pid: 11, ppid: 10, start: 'b', command: '/bin/node' },
  { pid: 12, ppid: 11, start: 'c', command: '/bin/ffmpeg' },
];
const claim = (campaign) => ({
  campaign,
  candidateID: id(Number(campaign) + 1),
  trialRevision: campaign === '1' ? '1' : '3',
  confirmedEventIndex: Number(campaign) * 20,
  readyEventIndex: Number(campaign) * 20 + 1,
});
const sample = (campaign, paused = false) => ({
  context: {
    gameId: 'm',
    generation: 1,
    workerId: 'worker',
    workerEpoch: id(4),
    attempt: 1,
    publication: {
      readerId: id(5),
      publisherId: id(6),
      publishingAttemptId: id(1),
      clock: { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '9000' },
    },
  },
  decoderCadence: {
    formatVersion: 1,
    scopeID: id(7),
    ended: false,
    invalidReason: null,
    progress: {
      lastFreshPTS: Number(campaign) * 90000,
      ageMs: paused ? 1810 : 10,
      stalled: paused,
    },
  },
  decoderCadenceAgeUpperBoundMs: 5,
  serverTime: '2040-01-01T00:00:00Z',
  expiresAt: '2040-01-01T00:00:05Z',
});
function fixture() {
  const events = [],
    saved = [],
    abort = new AbortController();
  let time = 100;
  const input = {
    worker: { pid: 10, exitCode: null, signalCode: null },
    signal: abort.signal,
    scope: structuredClone(scope),
    awaitReady: async (campaign) => {
      events.push(`ready${campaign}`);
      return claim(campaign);
    },
    observeBeforePause: async (campaign) => {
      events.push(`before${campaign}`);
      return sample(campaign);
    },
    observePaused: async (campaign) => {
      events.push(`paused${campaign}`);
      return sample(campaign, true);
    },
    inventory: async () => {
      events.push('inventory');
      return structuredClone(tree);
    },
    revalidate: async (known) => {
      events.push('revalidate');
      return structuredClone(known);
    },
    signalProcess: (pid, signal) => {
      events.push([pid, signal]);
    },
    wait: async (ms) => {
      events.push(ms);
      time += ms;
    },
    now: () => time++,
    save: async (value) => {
      saved.push(structuredClone(value));
    },
  };
  return { input, events, saved, abort };
}
test('exports the explicit repeated runner', () => assert.equal(typeof run, 'function'));
test('waits on each original confirmation with only two 1800ms pauses and joins each resume', async () => {
  const f = fixture(),
    result = await run(f.input);
  assert.deepEqual(f.events, [
    'ready1',
    'inventory',
    'before1',
    'revalidate',
    [12, 'SIGSTOP'],
    1800,
    'paused1',
    'inventory',
    [12, 'SIGCONT'],
    'ready2',
    'inventory',
    'before2',
    'revalidate',
    [12, 'SIGSTOP'],
    1800,
    'paused2',
    'inventory',
    [12, 'SIGCONT'],
  ]);
  assert.deepEqual(Object.keys(result).sort(), [
    'campaigns',
    'closed',
    'failed',
    'formatVersion',
    'mode',
    'scope',
  ]);
  assert.equal(result.formatVersion, 2);
  assert.equal(result.mode, 'repeated');
  assert.deepEqual(result.scope, scope);
  assert.equal(result.closed, true);
  assert.equal(result.failed, false);
  assert.equal(result.campaigns.length, 2);
  for (const [index, row] of result.campaigns.entries()) {
    for (const [key, value] of Object.entries(claim(String(index + 1))))
      assert.equal(row[key], value);
    assert.equal(row.closed, true);
    assert.equal(row.failed, false);
    assert(row.beforePauseSample.requestStartedAt <= row.beforePauseSample.receivedAt);
    assert(row.beforePauseSample.receivedAt <= row.pauseSentAt);
    assert(row.pausedSample.requestStartedAt >= row.pauseSentAt + 1800);
    assert(row.pausedSample.receivedAt <= row.resumeSentAt);
    assert.equal('delayBeforePauseMs' in row, false);
  }
  assert(result.campaigns[1].pauseSentAt > result.campaigns[0].resumeSentAt);
  assert.equal(f.saved[0].closed, false);
  assert.equal(f.saved[0].campaigns.length, 1);
  assert.equal(f.saved[0].campaigns[0].closed, false);
  assert.deepEqual(f.saved.at(-1), result);
});
for (const [label, mutate] of [
  [
    'missing scope',
    (f) => {
      f.input.scope = null;
    },
  ],
  [
    'noncanonical original source revision',
    (f) => {
      f.input.scope.appliedProfileRevision = '02';
    },
  ],
  [
    'invalid publication',
    (f) => {
      f.input.scope.publishingAttemptID = 'wrong';
    },
  ],
  [
    'invalid generation',
    (f) => {
      f.input.scope.broadcastGeneration = 0;
    },
  ],
  [
    'wrong campaign',
    (f) => {
      f.input.awaitReady = async () => ({ ...claim('1'), campaign: '2' });
    },
  ],
  [
    'wrong trial revision',
    (f) => {
      f.input.awaitReady = async () => ({ ...claim('1'), trialRevision: '3' });
    },
  ],
  [
    'invalid candidate',
    (f) => {
      f.input.awaitReady = async () => ({ ...claim('1'), candidateID: 'bad' });
    },
  ],
  [
    'negative confirmation',
    (f) => {
      f.input.awaitReady = async () => ({ ...claim('1'), confirmedEventIndex: -1 });
    },
  ],
  [
    'readiness before confirmation',
    (f) => {
      f.input.awaitReady = async () => ({ ...claim('1'), readyEventIndex: 19 });
    },
  ],
  [
    'confirmation outside bounded audit',
    (f) => {
      f.input.awaitReady = async () => ({
        ...claim('1'),
        confirmedEventIndex: 512,
        readyEventIndex: 512,
      });
    },
  ],
])
  test(`${label} saves failure without signaling`, async () => {
    const f = fixture();
    mutate(f);
    await assert.rejects(run(f.input));
    assert(!f.events.some(Array.isArray));
    assert.equal(f.saved.at(-1).failed, true);
    assert.equal(f.saved.at(-1).closed, true);
  });
for (const point of ['ready', 'before', 'revalidate', 'wait', 'paused']) {
  test(`abort during ${point} joins any owned pause and never starts the next campaign`, async () => {
    const f = fixture();
    const key = {
        ready: 'awaitReady',
        before: 'observeBeforePause',
        revalidate: 'revalidate',
        wait: 'wait',
        paused: 'observePaused',
      }[point],
      original = f.input[key];
    f.input[key] = async (...args) => {
      const value = await original(...args);
      f.abort.abort(new Error('abort fixture'));
      return value;
    };
    await assert.rejects(run(f.input), /abort fixture/);
    assert.deepEqual(
      f.events.filter(Array.isArray),
      ['wait', 'paused'].includes(point)
        ? [
            [12, 'SIGSTOP'],
            [12, 'SIGCONT'],
          ]
        : [],
    );
    assert(!f.events.includes('ready2'));
    assert.equal(f.saved.at(-1).closed, true);
    assert.equal(f.saved.at(-1).failed, true);
  });
}
for (const point of ['awaitReady', 'observeBeforePause', 'observePaused'])
  test(`${point} failure cannot begin another pause`, async () => {
    const f = fixture();
    f.input[point] = async () => {
      throw new Error('sample failed');
    };
    await assert.rejects(run(f.input), /sample failed/);
    assert.deepEqual(
      f.events.filter(Array.isArray),
      point === 'observePaused'
        ? [
            [12, 'SIGSTOP'],
            [12, 'SIGCONT'],
          ]
        : [],
    );
    assert.equal(f.saved.at(-1).failed, true);
    assert(!f.events.includes('ready2'));
  });
for (const pid of [10, 11, 12]) {
  test(`replaced ${pid} after awaited sample receives no SIGSTOP`, async () => {
    const f = fixture();
    f.input.revalidate = async (identity) => {
      const value = structuredClone(identity);
      Object.values(value).find((row) => row.pid === pid).start = 'replacement';
      return value;
    };
    await assert.rejects(run(f.input), /identity/);
    assert.deepEqual(f.events.filter(Array.isArray), []);
  });
  test(`replaced ${pid} between campaigns cannot be adopted`, async () => {
    const f = fixture(),
      read = f.input.inventory;
    f.input.inventory = async () =>
      (await read()).map((row) =>
        f.events.includes('ready2') && row.pid === pid ? { ...row, start: 'replacement' } : row,
      );
    await assert.rejects(run(f.input), /identity/);
    assert.deepEqual(f.events.filter(Array.isArray), [
      [12, 'SIGSTOP'],
      [12, 'SIGCONT'],
    ]);
    assert.equal(f.saved.at(-1).campaigns[0].failed, false);
  });
  test(`replaced ${pid} during pause is never resumed`, async () => {
    const f = fixture(),
      read = f.input.inventory;
    f.input.inventory = async () =>
      (await read()).map((row) =>
        f.events.includes('paused1') && row.pid === pid ? { ...row, start: 'replacement' } : row,
      );
    await assert.rejects(run(f.input), /identity/);
    assert.deepEqual(f.events.filter(Array.isArray), [[12, 'SIGSTOP']]);
    assert.equal(f.saved.at(-1).campaigns[0].resumeSentAt, null);
  });
}
for (const [label, mutate] of [
  [
    'publication',
    (s) => {
      s.context.publication.publishingAttemptId = id(9);
    },
  ],
  [
    'match',
    (s) => {
      s.context.gameId = 'other';
    },
  ],
  [
    'generation',
    (s) => {
      s.context.generation++;
    },
  ],
  [
    'worker',
    (s) => {
      s.context.workerId = 'other';
    },
  ],
  [
    'worker epoch',
    (s) => {
      s.context.workerEpoch = id(9);
    },
  ],
  [
    'reader',
    (s) => {
      s.context.publication.readerId = id(9);
    },
  ],
  [
    'decoder scope',
    (s) => {
      s.decoderCadence.scopeID = id(9);
    },
  ],
  [
    'stale progress',
    (s) => {
      s.decoderCadence.progress.lastFreshPTS = 90000;
    },
  ],
])
  test(`second before sample changed ${label} cannot signal`, async () => {
    const f = fixture();
    f.input.observeBeforePause = async (campaign) => {
      const value = sample(campaign);
      if (campaign === '2') mutate(value);
      return value;
    };
    await assert.rejects(run(f.input));
    assert.deepEqual(f.events.filter(Array.isArray), [
      [12, 'SIGSTOP'],
      [12, 'SIGCONT'],
    ]);
    assert.equal(f.saved.at(-1).failed, true);
  });
test('paused sample changed publication still joins resume and fails', async () => {
  const f = fixture();
  f.input.observePaused = async (campaign) => {
    const value = sample(campaign, true);
    value.context.publication.readerId = id(9);
    return value;
  };
  await assert.rejects(run(f.input));
  assert.deepEqual(f.events.filter(Array.isArray), [
    [12, 'SIGSTOP'],
    [12, 'SIGCONT'],
  ]);
  assert.equal(f.saved.at(-1).failed, true);
});
test('failed evidence save still resumes and preserves terminal failed evidence', async () => {
  const f = fixture(),
    save = f.input.save;
  let calls = 0;
  f.input.save = async (evidence) => {
    await save(evidence);
    if (++calls === 1) throw new Error('write failed');
  };
  await assert.rejects(run(f.input), /write failed/);
  assert.deepEqual(f.events.filter(Array.isArray), [
    [12, 'SIGSTOP'],
    [12, 'SIGCONT'],
  ]);
  assert.equal(f.saved.at(-1).failed, true);
  assert.equal(f.saved.at(-1).campaigns[0].closed, true);
});
test('second claim cannot reuse candidate or earlier readiness history', async () => {
  for (const change of [{ candidateID: id(2) }, { confirmedEventIndex: 21, readyEventIndex: 22 }]) {
    const f = fixture();
    f.input.awaitReady = async (campaign) =>
      campaign === '1'
        ? { ...claim(campaign), readyEventIndex: 22 }
        : { ...claim(campaign), ...change };
    await assert.rejects(run(f.input));
    assert.deepEqual(f.events.filter(Array.isArray), [
      [12, 'SIGSTOP'],
      [12, 'SIGCONT'],
    ]);
  }
});
test('claim, sample, scope and save callback mutations cannot rewrite captured evidence', async () => {
  const f = fixture(),
    firstClaim = claim('1'),
    firstSample = sample('1');
  f.input.awaitReady = async (campaign) => (campaign === '1' ? firstClaim : claim(campaign));
  f.input.observeBeforePause = async (campaign) => {
    firstClaim.candidateID = id(9);
    f.input.scope.matchID = 'mutated';
    return campaign === '1' ? firstSample : sample(campaign);
  };
  f.input.observePaused = async (campaign) => {
    firstSample.context.workerId = 'mutated';
    return sample(campaign, true);
  };
  const save = f.input.save;
  f.input.save = async (value) => {
    await save(value);
    value.scope.matchID = 'write mutation';
    value.campaigns.length = 0;
  };
  const result = await run(f.input);
  assert.equal(result.scope.matchID, 'm');
  assert.equal(result.campaigns[0].candidateID, id(2));
  assert.equal(result.campaigns[0].beforePauseSample.value.context.workerId, 'worker');
});
test('live readiness is rechecked after sampling and before scoped identity revalidation', async () => {
  const f = fixture();
  f.input.validateReady = async (value) => {
    f.events.push(`validate${value.campaign}`);
  };
  await run(f.input);
  for (const campaign of ['1', '2']) {
    const at = f.events.indexOf(`before${campaign}`);
    assert.deepEqual(f.events.slice(at, at + 4), [
      `before${campaign}`,
      `validate${campaign}`,
      'revalidate',
      [12, 'SIGSTOP'],
    ]);
  }
});
for (const campaign of ['1', '2'])
  test(`invalidated campaign ${campaign} checkpoint cannot pause`, async () => {
    const f = fixture();
    f.input.validateReady = async (value) => {
      if (value.campaign === campaign) throw new Error('readiness invalidated');
    };
    await assert.rejects(run(f.input), /readiness invalidated/);
    assert.deepEqual(
      f.events.filter(Array.isArray),
      campaign === '1'
        ? []
        : [
            [12, 'SIGSTOP'],
            [12, 'SIGCONT'],
          ],
    );
    assert.equal(f.saved.at(-1).failed, true);
  });
test('abort during readiness revalidation cannot pause', async () => {
  const f = fixture();
  f.input.validateReady = async () => {
    f.abort.abort(new Error('readiness aborted'));
  };
  await assert.rejects(run(f.input), /readiness aborted/);
  assert.deepEqual(f.events.filter(Array.isArray), []);
});
test('terminal save failure is retried as failed evidence and cannot return success', async () => {
  const f = fixture(),
    save = f.input.save;
  let failed = false;
  f.input.save = async (value) => {
    if (value.closed && !failed) {
      failed = true;
      throw new Error('terminal write failed');
    }
    await save(value);
  };
  await assert.rejects(run(f.input), /terminal write failed/);
  assert.equal(f.saved.at(-1).closed, true);
  assert.equal(f.saved.at(-1).failed, true);
  assert.equal(f.saved.at(-1).campaigns.length, 2);
  assert(f.saved.at(-1).campaigns.every((row) => row.closed && row.resumeSentAt !== null));
});
test('second readiness cannot start while first resume identity check is pending', async () => {
  const f = fixture(),
    read = f.input.inventory;
  let release, entered;
  const ready = new Promise((resolve) => {
    entered = resolve;
  });
  const blocked = new Promise((resolve) => {
    release = resolve;
  });
  f.input.inventory = async () => {
    if (f.events.includes('paused1') && !f.events.includes('ready2')) {
      entered();
      await blocked;
    }
    return read();
  };
  const pending = run(f.input);
  await ready;
  assert(!f.events.includes('ready2'));
  assert.deepEqual(f.events.filter(Array.isArray), [[12, 'SIGSTOP']]);
  release();
  const result = await pending;
  assert.equal(result.closed, true);
  assert.equal(result.failed, false);
});
for (const campaign of ['1', '2'])
  test(`abort during campaign ${campaign} resume still resumes and fails terminally`, async () => {
    const f = fixture(),
      read = f.input.inventory;
    f.input.inventory = async () => {
      const rows = await read();
      if (f.events.includes(`paused${campaign}`)) f.abort.abort(new Error('abort while resuming'));
      return rows;
    };
    await assert.rejects(run(f.input), /abort while resuming/);
    assert.deepEqual(
      f.events.filter(Array.isArray),
      Array.from({ length: Number(campaign) }, () => [
        [12, 'SIGSTOP'],
        [12, 'SIGCONT'],
      ]).flat(),
    );
    assert.equal(f.saved.at(-1).failed, true);
    assert.equal(f.saved.at(-1).campaigns.at(-1).failed, true);
  });
test('abort during terminal save cannot return successful evidence', async () => {
  const f = fixture(),
    save = f.input.save;
  f.input.save = async (value) => {
    await save(value);
    if (value.closed) f.abort.abort(new Error('abort during terminal save'));
  };
  await assert.rejects(run(f.input), /abort during terminal save/);
  assert.equal(f.saved.at(-1).failed, true);
});
test('abort during active save resumes without spending the pause budget', async () => {
  const f = fixture(),
    save = f.input.save;
  f.input.save = async (value) => {
    await save(value);
    if (!value.closed) f.abort.abort(new Error('abort after save'));
  };
  await assert.rejects(run(f.input), /abort after save/);
  assert.deepEqual(f.events.filter(Array.isArray), [
    [12, 'SIGSTOP'],
    [12, 'SIGCONT'],
  ]);
  assert(!f.events.includes(1800));
});

test('both emitted raw sample pairs satisfy the existing owned-pause clock and identity gate', async () => {
  const f = fixture(),
    result = await run(f.input);
  for (const row of result.campaigns) {
    qualifyOwnedPauseSample(row, row.beforePauseSample.value.context, {
      decoderScopeID: row.pausedSample.value.decoderCadence.scopeID,
      lastStalledPTS: String(row.pausedSample.value.decoderCadence.progress.lastFreshPTS),
    });
  }
});

test('uppercase native attempt scope joins lowercase worker publication without rewriting raw scope', async () => {
  const f = fixture();
  f.input.scope.publishingAttemptID = f.input.scope.publishingAttemptID.toUpperCase();
  assert.notEqual(
    f.input.scope.publishingAttemptID,
    sample('1').context.publication.publishingAttemptId,
  );
  const originalScope = structuredClone(f.input.scope);
  const result = await run(f.input);
  assert.deepEqual(result.scope, originalScope);
  assert.deepEqual(f.saved.at(-1).scope, originalScope);
  assert.equal(
    result.campaigns[0].beforePauseSample.value.context.publication.publishingAttemptId,
    originalScope.publishingAttemptID.toLowerCase(),
  );
});

test('uppercase native scope still rejects a foreign lowercase worker publication before signaling', async () => {
  const f = fixture();
  f.input.scope.publishingAttemptID = id(9).toUpperCase();
  await assert.rejects(run(f.input), /scope/);
  assert.deepEqual(f.events.filter(Array.isArray), []);
  assert.equal(f.saved.at(-1).closed, true);
  assert.equal(f.saved.at(-1).failed, true);
  assert.equal(f.saved.at(-1).scope.publishingAttemptID, id(9).toUpperCase());
});

test('original native source revision one remains distinct from controller trial revisions one and three', async () => {
  const f = fixture();
  f.input.scope.appliedProfileRevision = '1';
  const result = await run(f.input);
  assert.equal(result.scope.appliedProfileRevision, '1');
  assert.deepEqual(
    result.campaigns.map((row) => row.trialRevision),
    ['1', '3'],
  );
  assert(f.saved.every((value) => value.scope.appliedProfileRevision === '1'));
});

test('original source revision is a canonical UInt64 string', async () => {
  for (const value of ['-1', '1.0', ' 1', '', 1, '18446744073709551616']) {
    const f = fixture();
    f.input.scope.appliedProfileRevision = value;
    await assert.rejects(run(f.input), /scope/);
    assert.deepEqual(f.events.filter(Array.isArray), []);
  }
  const f = fixture();
  f.input.scope.appliedProfileRevision = '18446744073709551615';
  assert.equal((await run(f.input)).scope.appliedProfileRevision, '18446744073709551615');
});
