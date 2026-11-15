import { createServer } from 'node:http';
import { afterEach, expect, it } from 'vitest';
import { WorkerReporter } from '../src/worker-reporter.js';

const observation = {
  gameId: 'game',
  generation: 1,
  state: 'starting' as const,
  reason: null,
  attempt: 1,
  frame: null,
  outTimeUs: null,
  scoreRevision: 2,
};
type Reply = { status?: number; body: unknown; delay?: number; drop?: boolean };
function gate() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  return { promise, release };
}
// Deadline tests use budgets of hundreds of milliseconds: the steps meant to fit
// keep several hundred ms of headroom for slow, shared CI runners, and the steps
// meant to overrun still exceed the budget by a wide margin.
const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const close of cleanup.splice(0)) await close();
});
async function fixture(
  handler: (path: string, body: any) => Reply | Promise<Reply>,
  timeout = 1000,
) {
  const requests: { path: string; body: any; auth: string | undefined }[] = [];
  const server = createServer(async (req, res) => {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    requests.push({ path: req.url!, body, auth: req.headers.authorization });
    const result = await handler(req.url!, body);
    if (result.drop) {
      res.destroy();
      return;
    }
    if (result.delay) await new Promise((resolve) => setTimeout(resolve, result.delay));
    res.writeHead(result.status ?? 200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(result.body));
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  cleanup.push(
    () =>
      new Promise((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  );
  const url = `http://127.0.0.1:${(server.address() as { port: number }).port}/prefix`;
  return {
    requests,
    reporter: new WorkerReporter(url, 'private-token', 'mac', timeout, 'run-one'),
  };
}
it('registers once and sends ordered current observations without credentials in bodies', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions') ? { sessionId: 'session-one' } : { accepted: true },
  }));
  await f.reporter.report(() => observation);
  await f.reporter.report(() => ({ ...observation, scoreRevision: 3 }));
  expect(f.requests.map((r) => r.path)).toEqual([
    '/prefix/v1/worker/sessions',
    '/prefix/v1/worker/observations',
    '/prefix/v1/worker/observations',
  ]);
  expect(f.requests[0]!.body).toEqual({ workerId: 'mac', runId: 'run-one' });
  expect(f.requests[1]!.body).toEqual({
    workerId: 'mac',
    sessionId: 'session-one',
    sequence: 1,
    observation,
  });
  expect(f.requests[2]!.body.sequence).toBe(2);
  expect(f.requests.every((r) => r.auth === 'Bearer private-token')).toBe(true);
  expect(JSON.stringify(f.requests.map((r) => r.body))).not.toContain('private-token');
});
it('renews a missing server session after API restart without retrying a retired process', async () => {
  let registrations = 0;
  const f = await fixture((path, body) => ({
    body: path.endsWith('sessions')
      ? { sessionId: `session-${++registrations}` }
      : body.sessionId === 'session-1'
        ? { error: 'worker_session_unknown' }
        : { accepted: true },
    ...(path.endsWith('observations') && body.sessionId === 'session-1' ? { status: 409 } : {}),
  }));
  await f.reporter.report(() => observation);
  expect(registrations).toBe(2);
  expect(f.requests.at(-1)!.body.sessionId).toBe('session-2');
  const retired = await fixture((path) =>
    path.endsWith('sessions')
      ? { body: { sessionId: 'one' } }
      : { status: 409, body: { error: 'worker_session_retired' } },
  );
  await expect(retired.reporter.report(() => observation)).rejects.toThrow(
    'worker_report_rejected',
  );
  expect(retired.requests).toHaveLength(2);
});
it('samples only after gated registration and coalesces extra suppliers', async () => {
  const entered = gate();
  const registered = gate();
  const events: string[] = [];
  const f = await fixture(async (path) => {
    if (path.endsWith('sessions')) {
      events.push('register');
      entered.release();
      await registered.promise;
      events.push('marker');
      return { body: { sessionId: 'one', timingToken: 'marker-one' } };
    }
    events.push('send');
    return { body: { accepted: true, timingToken: 'marker-two' } };
  });
  const mutable = { ...observation };
  let samples = 0;
  const first = f.reporter.report(() => {
    samples++;
    events.push('sample');
    return mutable;
  });
  await entered.promise;
  expect(samples).toBe(0);
  mutable.scoreRevision = 99;
  const second = f.reporter.report(() => {
    throw new Error('coalesced supplier invoked');
  });
  expect(second).toBe(first);
  registered.release();
  await first;
  expect(samples).toBe(1);
  expect(events).toEqual(['register', 'marker', 'sample', 'send']);
  expect(f.requests[1]!.body.observation.scoreRevision).toBe(99);
  expect(f.requests[1]!.body.timingToken).toBe('marker-one');
  await f.reporter.report(() => observation);
  expect(f.requests[2]!.body.timingToken).toBe('marker-two');
});
it('bounds unavailable reporting and exposes only safe fixed errors', async () => {
  const slow = await fixture(() => ({ body: { sessionId: 'one' }, delay: 100 }), 20);
  await expect(slow.reporter.report(() => observation)).rejects.toThrow(
    'worker_report_unavailable',
  );
  const failed = await fixture(() => ({ status: 500, body: { error: 'PRIVATE_URL_OR_TOKEN' } }));
  await expect(failed.reporter.report(() => observation)).rejects.toThrow('worker_report_rejected');
  const invalid = await fixture(() => ({ body: { sessionId: 42 } }));
  await expect(invalid.reporter.report(() => observation)).rejects.toThrow(
    'invalid_worker_report_response',
  );
});
it('uses one total deadline for registration plus observation, not a fresh timeout per request', async () => {
  const f = await fixture(
    (path) => ({
      body: path.endsWith('sessions') ? { sessionId: 'one' } : { accepted: true },
      delay: 400,
    }),
    650,
  );
  await expect(f.reporter.report(() => observation)).rejects.toThrow('worker_report_unavailable');
  expect(f.requests).toHaveLength(2);
});
it('rejects credentialed or non-HTTP control URLs before making requests', () => {
  for (const url of [
    'file:///tmp',
    'http://user:password@localhost',
    'http://localhost/?token=x',
    'http://localhost/#secret',
  ])
    expect(() => new WorkerReporter(url, 'token', 'mac')).toThrow(
      'invalid_worker_report_configuration',
    );
});

it('copies nested decoder evidence immediately after sampling', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions') ? { sessionId: 'one' } : { accepted: true },
    delay: 20,
  }));
  const mutable = {
    ...observation,
    decodedVideo: {
      completed: {
        sequence: 1,
        durationMs: 5000 as const,
        ageMs: 100,
        firstPTS: 0,
        lastPTS: 447000,
        freshFrames: 150,
        duplicateFrames: 0,
        reorderedFrames: 0,
        valid: true,
      },
      invalidReason: null,
      ended: false,
    },
  };
  const pending = f.reporter.report(() => {
    queueMicrotask(() => {
      mutable.decodedVideo.completed.freshFrames = 999;
    });
    return mutable;
  });
  await pending;
  expect(f.requests[1]!.body.observation.decodedVideo.completed.freshFrames).toBe(150);
});

it('resamples after a replacement session marker and allocates a new sequence', async () => {
  let registrations = 0;
  let revision = 2;
  const samples: number[] = [];
  const f = await fixture((path) => {
    if (path.endsWith('sessions')) {
      registrations++;
      revision = registrations * 10;
      return {
        body: { sessionId: `session-${registrations}`, timingToken: `marker-${registrations}` },
      };
    }
    return registrations === 1
      ? { status: 409, body: { error: 'worker_session_unknown' } }
      : { body: { accepted: true, timingToken: 'marker-3' } };
  });
  await f.reporter.report(() => {
    samples.push(revision);
    return { ...observation, scoreRevision: revision };
  });
  expect(samples).toEqual([10, 20]);
  expect(f.requests.filter((r) => r.path.endsWith('observations')).map((r) => r.body)).toEqual([
    {
      workerId: 'mac',
      sessionId: 'session-1',
      timingToken: 'marker-1',
      sequence: 1,
      observation: { ...observation, scoreRevision: 10 },
    },
    {
      workerId: 'mac',
      sessionId: 'session-2',
      timingToken: 'marker-2',
      sequence: 2,
      observation: { ...observation, scoreRevision: 20 },
    },
  ]);
});

it('keeps the cached previous marker through consecutive lost acknowledgements', async () => {
  let reports = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? { body: { sessionId: 'one', timingToken: 'marker-1' } }
      : { body: { accepted: true, timingToken: 'marker-2' }, drop: ++reports <= 2 },
  );
  for (let i = 0; i < 2; i++)
    await expect(f.reporter.report(() => observation)).rejects.toThrow('worker_report_unavailable');
  await f.reporter.report(() => observation);
  await f.reporter.report(() => observation);
  expect(f.requests.slice(1).map((r) => r.body.timingToken)).toEqual([
    'marker-1',
    'marker-1',
    'marker-1',
    'marker-2',
  ]);
  expect(f.requests.slice(1).map((r) => r.body.sequence)).toEqual([1, 2, 3, 4]);
});

it('coalesces a reentrant supplier even with a cached session', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions') ? { sessionId: 'one' } : { accepted: true },
  }));
  await f.reporter.report(() => null);
  let nested: Promise<void> | undefined;
  let samples = 0;
  const outer = f.reporter.report(() => {
    samples++;
    nested = f.reporter.report(() => {
      samples++;
      return observation;
    });
    return observation;
  });
  await outer;
  expect(nested).toBe(outer);
  expect(samples).toBe(1);
  expect(f.requests).toHaveLength(2);
});

it('sends no observation for null samples including after replacement registration', async () => {
  let registrations = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? {
          body: { sessionId: `session-${++registrations}`, timingToken: `marker-${registrations}` },
        }
      : { status: 409, body: { error: 'worker_session_unknown' } },
  );
  await f.reporter.report(() => null);
  expect(f.requests).toHaveLength(1);
  let samples = 0;
  await f.reporter.report(() => (++samples === 1 ? observation : null));
  expect(samples).toBe(2);
  expect(f.requests.map((r) => r.path.split('/').at(-1))).toEqual([
    'sessions',
    'observations',
    'sessions',
  ]);
});

it('sanitizes supplier errors and allows the next report to recover', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions') ? { sessionId: 'one' } : { accepted: true },
  }));
  await expect(
    f.reporter.report(() => {
      throw new Error('PRIVATE_URL_OR_TOKEN');
    }),
  ).rejects.toThrow(/^worker_report_unavailable$/);
  expect(f.requests).toHaveLength(1);
  await f.reporter.report(() => observation);
  expect(f.requests[1]!.body.sequence).toBe(1);
});

it('normalizes a second missing session error without further retries', async () => {
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? { body: { sessionId: 'one' } }
      : { status: 409, body: { error: 'worker_session_unknown' } },
  );
  await expect(f.reporter.report(() => observation)).rejects.toThrow(/^worker_report_rejected$/);
  expect(f.requests).toHaveLength(4);
  expect(f.requests[3]!.body.sequence).toBe(2);
});

it('clears the old timing token when replacement registration is legacy', async () => {
  let registrations = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? {
          body:
            ++registrations === 1
              ? { sessionId: 'one', timingToken: 'marker-1' }
              : { sessionId: 'two' },
        }
      : registrations === 1
        ? { status: 409, body: { error: 'worker_session_unknown' } }
        : { body: { accepted: true } },
  );
  await f.reporter.report(() => observation);
  expect(f.requests[1]!.body.timingToken).toBe('marker-1');
  expect(f.requests[3]!.body).not.toHaveProperty('timingToken');
});

it.each([42, null, '', 'bad token', 'x'.repeat(129)])(
  'rejects invalid registration timing tokens: %s',
  async (timingToken) => {
    const f = await fixture(() => ({ body: { sessionId: 'one', timingToken } }));
    await expect(f.reporter.report(() => observation)).rejects.toThrow(
      'invalid_worker_report_response',
    );
    expect(f.requests).toHaveLength(1);
  },
);

it('rejects invalid acknowledgement tokens without replacing the cached marker', async () => {
  let reports = 0;
  const f = await fixture((path) => ({
    body: path.endsWith('sessions')
      ? { sessionId: 'one', timingToken: 'marker-1' }
      : { accepted: true, timingToken: ++reports === 1 ? 'bad token' : 'marker-2' },
  }));
  await expect(f.reporter.report(() => observation)).rejects.toThrow(
    'invalid_worker_report_response',
  );
  await f.reporter.report(() => observation);
  expect(f.requests[2]!.body.timingToken).toBe('marker-1');
});

it('does not sample when registration exceeds the deadline', async () => {
  let samples = 0;
  const f = await fixture(
    () => ({ body: { sessionId: 'one', timingToken: 'marker-1' }, delay: 800 }),
    200,
  );
  await expect(
    f.reporter.report(() => {
      samples++;
      return observation;
    }),
  ).rejects.toThrow('worker_report_unavailable');
  expect(samples).toBe(0);
  expect(f.requests).toHaveLength(1);
});

it.each([false, true])(
  'does not POST after a synchronous supplier blocks past the deadline (null=%s)',
  async (idle) => {
    const f = await fixture(
      (path) => ({ body: path.endsWith('sessions') ? { sessionId: 'one' } : { accepted: true } }),
      300,
    );
    await f.reporter.report(() => null);
    await expect(
      f.reporter.report(() => {
        const end = performance.now() + 600;
        while (performance.now() < end) {
          /* synchronous decoder work */
        }
        return idle ? null : observation;
      }),
    ).rejects.toThrow('worker_report_unavailable');
    expect(f.requests).toHaveLength(1);
  },
);

it('uses the original deadline for replacement registration and resampling', async () => {
  let registrations = 0;
  let samples = 0;
  const f = await fixture(
    (path) =>
      path.endsWith('sessions')
        ? {
            body: { sessionId: `session-${++registrations}` },
            delay: registrations === 1 ? 0 : 800,
          }
        : { status: 409, body: { error: 'worker_session_unknown' }, delay: 400 },
    900,
  );
  await expect(
    f.reporter.report(() => {
      samples++;
      return observation;
    }),
  ).rejects.toThrow('worker_report_unavailable');
  expect(samples).toBe(1);
  expect(f.requests).toHaveLength(3);
});

it('refuses sequence exhaustion without wrapping or sending unsafe numbers', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions') ? { sessionId: 'one' } : { accepted: true },
  }));
  // Set the lifetime counter near its boundary without issuing quadrillions of requests.
  (f.reporter as unknown as { sequence: number }).sequence = Number.MAX_SAFE_INTEGER - 1;
  await f.reporter.report(() => observation);
  expect(f.requests[1]!.body.sequence).toBe(Number.MAX_SAFE_INTEGER);
  await expect(f.reporter.report(() => observation)).rejects.toThrow(/^worker_report_unavailable$/);
  expect(f.requests).toHaveLength(2);
});

const transportClock = 'mpegts-pts-90k-v1';
it.each([
  [undefined, transportClock, undefined],
  ['future-clock-v2', transportClock, undefined],
  [transportClock, 'future-clock-v2', undefined],
  ['future-clock-v2', 'future-clock-v2', undefined],
  [transportClock, undefined, undefined],
  [transportClock, transportClock, transportClock],
])(
  'negotiates advertised %s and supplied %s as %s without changing the supplier',
  async (advertised, supplied, expected) => {
    const f = await fixture((path) => ({
      body: path.endsWith('sessions')
        ? { sessionId: 'one', timingToken: 'marker-1', decodedVideoClock: advertised }
        : { accepted: true, timingToken: 'marker-2', decodedVideoClock: 'ignored-ack-clock' },
    }));
    const mutable = {
      ...observation,
      decodedVideo: {
        completed: null,
        invalidReason: null,
        ended: false,
        ...(supplied === undefined ? {} : { clock: supplied }),
      },
    };
    const original = structuredClone(mutable);
    await f.reporter.report(() => mutable);
    await f.reporter.report(() => mutable);
    expect(mutable).toEqual(original);
    for (const [index, request] of f.requests.slice(1).entries()) {
      const decodedVideo = {
        completed: null,
        invalidReason: null,
        ended: false,
        ...(expected === undefined ? {} : { clock: expected }),
      };
      expect(request.body).toEqual({
        workerId: 'mac',
        sessionId: 'one',
        timingToken: index === 0 ? 'marker-1' : 'marker-2',
        sequence: index + 1,
        observation: { ...observation, decodedVideo },
      });
    }
  },
);

it.each([
  [transportClock, undefined],
  [undefined, transportClock],
  [transportClock, 'future-clock-v2'],
])('re-evaluates clock support after restart from %s to %s', async (first, second) => {
  let registrations = 0;
  let samples = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? {
          body: {
            sessionId: `session-${++registrations}`,
            decodedVideoClock: registrations === 1 ? first : second,
            timingToken: `marker-${registrations}`,
          },
        }
      : registrations === 1
        ? { status: 409, body: { error: 'worker_session_unknown' } }
        : { body: { accepted: true, timingToken: 'marker-3' } },
  );
  await f.reporter.report(() => {
    samples++;
    return {
      ...observation,
      decodedVideo: { completed: null, invalidReason: null, ended: false, clock: transportClock },
    };
  });
  await f.reporter.report(() => ({
    ...observation,
    decodedVideo: { completed: null, invalidReason: null, ended: false, clock: transportClock },
  }));
  expect(samples).toBe(2);
  const posts = f.requests
    .filter((request) => request.path.endsWith('observations'))
    .map((request) => request.body);
  expect(posts.map((body) => body.observation.decodedVideo.clock)).toEqual([
    first === transportClock ? transportClock : undefined,
    second === transportClock ? transportClock : undefined,
    second === transportClock ? transportClock : undefined,
  ]);
  expect(posts.map((body) => body.timingToken)).toEqual(['marker-1', 'marker-2', 'marker-3']);
  expect(posts.map((body) => body.sequence)).toEqual([1, 2, 3]);
  expect(posts.every((body) => !Object.hasOwn(body, 'decodedVideoClock'))).toBe(true);
});

it.each([null, 42, true, {}])(
  'rejects non-string advertised clock %j',
  async (decodedVideoClock) => {
    const f = await fixture(() => ({ body: { sessionId: 'one', decodedVideoClock } }));
    await expect(f.reporter.report(() => observation)).rejects.toThrow(
      'invalid_worker_report_response',
    );
    expect(f.requests).toHaveLength(1);
  },
);

const readIdentityConvention = 'srt-read-query-v1';
const readId = 'abcdef01-2345-4678-9abc-0123456789ab';
it.each([
  [undefined, readId, undefined],
  ['srt-read-query-v2', readId, undefined],
  [readIdentityConvention, readId, readId],
  [
    readIdentityConvention,
    'abcdef01-2345-0678-1abc-0123456789ab',
    'abcdef01-2345-0678-1abc-0123456789ab',
  ],
  [readIdentityConvention, `${readId}\n`, undefined],
  [readIdentityConvention, readId.toUpperCase(), undefined],
  [readIdentityConvention, 'not-a-uuid', undefined],
  [readIdentityConvention, ` ${readId}`, undefined],
  [readIdentityConvention, undefined, undefined],
])(
  'negotiates private read identity %s / %s only at request top level',
  async (advertised, supplied, expected) => {
    const f = await fixture((path) => ({
      body: path.endsWith('sessions')
        ? { sessionId: 'one', timingToken: 'marker-1', pipelineReadIdentity: advertised }
        : { accepted: true, timingToken: 'marker-2', pipelineReadIdentity: 'ignored' },
    }));
    const mutable = { ...observation, pipelineReadId: supplied };
    const original = structuredClone(mutable);
    await f.reporter.report(() => mutable);
    await f.reporter.report(() => mutable);
    expect(mutable).toEqual(original);
    for (const [index, request] of f.requests.slice(1).entries()) {
      expect(request.body).toEqual({
        workerId: 'mac',
        sessionId: 'one',
        timingToken: index === 0 ? 'marker-1' : 'marker-2',
        sequence: index + 1,
        observation,
        ...(expected === undefined ? {} : { pipelineReadId: expected }),
      });
    }
  },
);

it.each([
  [readIdentityConvention, undefined],
  [undefined, readIdentityConvention],
])('renegotiates read identity after API recovery from %s to %s', async (first, second) => {
  let registrations = 0;
  let samples = 0;
  const nextReadId = 'abcdef01-2345-4678-9abc-0123456789ac';
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? {
          body: {
            sessionId: `session-${++registrations}`,
            pipelineReadIdentity: registrations === 1 ? first : second,
          },
        }
      : registrations === 1
        ? { status: 409, body: { error: 'worker_session_unknown' } }
        : { body: { accepted: true } },
  );
  await f.reporter.report(() => ({
    ...observation,
    pipelineReadId: ++samples === 1 ? readId : nextReadId,
  }));
  const posts = f.requests.filter((r) => r.path.endsWith('observations'));
  expect(posts.map((r) => r.body.pipelineReadId)).toEqual([
    first === readIdentityConvention ? readId : undefined,
    second === readIdentityConvention ? nextReadId : undefined,
  ]);
  expect(posts.every((r) => !Object.hasOwn(r.body.observation, 'pipelineReadId'))).toBe(true);
  expect(samples).toBe(2);
});

it.each([undefined, 'future', 'source-processing-v1', 'source-processing-v2'])(
  'negotiates processing extension %s without changing the source snapshot',
  async (version) => {
    const supported = {
      sessionId: 'one',
      decodedVideoClock: 'mpegts-pts-90k-v1',
      pipelineReadIdentity: 'srt-read-query-v1',
      workerProcessing: version,
    };
    const f = await fixture((path) => ({
      body: path.endsWith('sessions') ? supported : { accepted: true },
    }));
    const sampled: any = {
      ...observation,
      pipelineReadId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      decodedVideo: {
        clock: 'mpegts-pts-90k-v1',
        completed: null,
        invalidReason: null,
        ended: false,
      },
      processing: { scopeID: 'test-only', interval: { intentionalFrameCapOmissions: 0 } },
    };
    await f.reporter.report(() => sampled);
    const actual = f.requests.at(-1)!.body.observation;
    expect(actual.processing).toEqual(
      version === 'source-processing-v1' ? { scopeID: 'test-only', interval: {} } : undefined,
    );
    expect(sampled.processing).toEqual({
      scopeID: 'test-only',
      interval: { intentionalFrameCapOmissions: 0 },
    });
  },
);
it.each(['clock', 'readIdentity', 'readId'])(
  'omits processing when %s negotiation is unavailable',
  async (missing) => {
    const supported: any = {
      sessionId: 'one',
      decodedVideoClock: 'mpegts-pts-90k-v1',
      pipelineReadIdentity: 'srt-read-query-v1',
      workerProcessing: 'source-processing-v1',
    };
    if (missing === 'clock') delete supported.decodedVideoClock;
    if (missing === 'readIdentity') delete supported.pipelineReadIdentity;
    const f = await fixture((path) => ({
      body: path.endsWith('sessions') ? supported : { accepted: true },
    }));
    await f.reporter.report(
      () =>
        ({
          ...observation,
          ...(missing === 'readId'
            ? {}
            : { pipelineReadId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }),
          processing: { scopeID: 'test-only', interval: {} },
        }) as any,
    );
    expect(f.requests.at(-1)!.body.observation).not.toHaveProperty('processing');
  },
);

it('renegotiates processing on session renewal and omits it after capability downgrade', async () => {
  let registrations = 0,
    samples = 0;
  const f = await fixture((path, body) =>
    path.endsWith('sessions')
      ? {
          body: {
            sessionId: `s${++registrations}`,
            decodedVideoClock: 'mpegts-pts-90k-v1',
            pipelineReadIdentity: 'srt-read-query-v1',
            ...(registrations === 1 ? { workerProcessing: 'source-processing-v1' } : {}),
          },
        }
      : body.sessionId === 's1'
        ? { status: 409, body: { error: 'worker_session_unknown' } }
        : { body: { accepted: true } },
  );
  await f.reporter.report(
    () =>
      ({
        ...observation,
        scoreRevision: ++samples,
        pipelineReadId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        decodedVideo: {
          clock: 'mpegts-pts-90k-v1',
          completed: null,
          invalidReason: null,
          ended: false,
        },
        processing: { scopeID: 'test-only', interval: {} },
      }) as any,
  );
  const reports = f.requests.filter((r) => r.path.endsWith('observations'));
  expect(reports[0]!.body.observation).toHaveProperty('processing');
  expect(reports[1]!.body.observation).not.toHaveProperty('processing');
  expect(reports[1]!.body.observation.scoreRevision).toBe(2);
});

it('negotiates cadence only with exact capability, transport clock and private read identity', async () => {
  for (const mode of ['current', 'legacy', 'wrong', 'no-read', 'no-clock']) {
    const f = await fixture((path) => ({
      body: path.endsWith('sessions')
        ? {
            sessionId: 'cadence-session',
            pipelineReadIdentity: 'srt-read-query-v1',
            decodedVideoClock: mode === 'no-clock' ? undefined : 'mpegts-pts-90k-v1',
            decoderCadence:
              mode === 'legacy' ? undefined : mode === 'wrong' ? 'future-v2' : 'decoder-cadence-v1',
          }
        : { accepted: true },
    }));
    const decoderCadence = {
      formatVersion: 1 as const,
      scopeID: '11111111-1111-4111-8111-111111111111',
      oneSecond: null,
      twoSeconds: null,
      progress: null,
      invalidReason: null,
      ended: false,
    };
    await f.reporter.report(() => ({
      ...observation,
      ...(mode === 'no-read' ? {} : { pipelineReadId: '22222222-2222-4222-8222-222222222222' }),
      decodedVideo: {
        clock: 'mpegts-pts-90k-v1',
        completed: null,
        invalidReason: null,
        ended: false,
      },
      decoderCadence,
    }));
    expect(f.requests[1]!.body.observation.decoderCadence).toEqual(
      mode === 'current' ? decoderCadence : undefined,
    );
  }
});

const deliveryFull = (n: number) => ({
  formatVersion: 1 as const,
  scopeID: '11111111-1111-4111-8111-111111111111',
  sampledAtMs: n * 40 + 10,
  coverageAtMs: 0,
  afterOrdinal: 0,
  lastOrdinal: n,
  arrivals: Array.from({ length: n }, (_, i) => [i * 3000, (i + 1) * 40] as [number, number]),
  invalidReason: null,
  ended: false,
});
const deliveryObservation = (n: number) => ({
  ...observation,
  pipelineReadId: '22222222-2222-4222-8222-222222222222',
  decodedVideo: { clock: 'mpegts-pts-90k-v1', completed: null, invalidReason: null, ended: false },
  decoderDelivery: deliveryFull(n),
});
it('sends only newly acknowledged arrivals and safely resends after a lost acknowledgement', async () => {
  let reports = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? {
          body: {
            sessionId: 'delivery-session',
            pipelineReadIdentity: 'srt-read-query-v1',
            decodedVideoClock: 'mpegts-pts-90k-v1',
            decoderDelivery: 'decoder-delivery-delta-v1',
          },
        }
      : { body: { accepted: true }, ...(++reports === 2 ? { drop: true } : {}) },
  );
  await f.reporter.report(() => deliveryObservation(3));
  await expect(f.reporter.report(() => deliveryObservation(6))).rejects.toThrow();
  await f.reporter.report(() => deliveryObservation(9));
  const packets = f.requests
    .filter((r) => r.path.endsWith('observations'))
    .map((r) => r.body.observation.decoderDelivery);
  expect(packets.map((p) => [p.afterOrdinal, p.arrivals.length])).toEqual([
    [0, 3],
    [3, 3],
    [3, 6],
  ]);
});
it.each(['legacy', 'wrong', 'no-read', 'no-clock'])(
  'omits unnegotiated delivery extension: %s',
  async (mode) => {
    const f = await fixture((path) => ({
      body: path.endsWith('sessions')
        ? {
            sessionId: 'delivery-session',
            pipelineReadIdentity: 'srt-read-query-v1',
            decodedVideoClock: mode === 'no-clock' ? undefined : 'mpegts-pts-90k-v1',
            decoderDelivery:
              mode === 'legacy'
                ? undefined
                : mode === 'wrong'
                  ? 'future'
                  : 'decoder-delivery-delta-v1',
          }
        : { accepted: true },
    }));
    const sample: any = deliveryObservation(3);
    if (mode === 'no-read') delete sample.pipelineReadId;
    await f.reporter.report(() => sample);
    expect(f.requests.at(-1)!.body.observation).not.toHaveProperty('decoderDelivery');
    expect(sample.decoderDelivery).toBeDefined();
  },
);
it('renegotiates delivery and resets cursor after API restart', async () => {
  let registrations = 0,
    reports = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? {
          body: {
            sessionId: `s${++registrations}`,
            pipelineReadIdentity: 'srt-read-query-v1',
            decodedVideoClock: 'mpegts-pts-90k-v1',
            decoderDelivery: 'decoder-delivery-delta-v1',
          },
        }
      : ++reports === 2
        ? { status: 409, body: { error: 'worker_session_unknown' } }
        : { body: { accepted: true } },
  );
  await f.reporter.report(() => deliveryObservation(3));
  await f.reporter.report(() => deliveryObservation(6));
  expect(
    f.requests
      .filter((r) => r.path.endsWith('observations'))
      .map((r) => r.body.observation.decoderDelivery.afterOrdinal),
  ).toEqual([0, 3, 0]);
});

const sampleTiming = 'worker-sample-timing-v1';
it('obtains fresh timing before sampling each report and coalesces during the challenge', async () => {
  const events: string[] = [];
  let challenges = 0;
  const f = await fixture(async (path) => {
    if (path.endsWith('sessions'))
      return { body: { sessionId: 'one', sampleTiming, timingToken: 'legacy' } };
    if (path.endsWith('sample-timing')) {
      events.push('challenge');
      await new Promise((resolve) => setTimeout(resolve, 20));
      events.push('issued');
      return { body: { timingToken: `fresh-${++challenges}` } };
    }
    events.push('report');
    return { body: { accepted: true, timingToken: 'cached-ack' } };
  });
  const sample = () => {
    events.push('sample');
    return observation;
  };
  const first = f.reporter.report(sample);
  expect(
    f.reporter.report(() => {
      throw new Error('must coalesce');
    }),
  ).toBe(first);
  await first;
  await f.reporter.report(sample);
  expect(events).toEqual([
    'challenge',
    'issued',
    'sample',
    'report',
    'challenge',
    'issued',
    'sample',
    'report',
  ]);
  expect(
    f.requests.filter((r) => r.path.endsWith('observations')).map((r) => r.body.timingToken),
  ).toEqual(['fresh-1', 'fresh-2']);
  expect(f.requests.filter((r) => r.path.endsWith('sample-timing')).map((r) => r.body)).toEqual([
    { workerId: 'mac', sessionId: 'one' },
    { workerId: 'mac', sessionId: 'one' },
  ]);
  expect(f.requests.every((r) => r.auth === 'Bearer private-token')).toBe(true);
});
it('omits proof when the negotiated timing endpoint cannot issue a token', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions')
      ? { sessionId: 'one', sampleTiming, timingToken: 'cached' }
      : path.endsWith('sample-timing')
        ? {}
        : { accepted: true, timingToken: 'cached-ack' },
  }));
  await f.reporter.report(() => observation);
  await f.reporter.report(() => observation);
  const reports = f.requests.filter((r) => r.path.endsWith('observations'));
  expect(reports).toHaveLength(2);
  expect(reports.every((r) => !Object.hasOwn(r.body, 'timingToken'))).toBe(true);
});
it.each(['http', 'malformed', 'transport'])(
  'never samples or falls back to cached proof after a %s challenge failure',
  async (mode) => {
    let samples = 0;
    const f = await fixture((path) =>
      path.endsWith('sessions')
        ? { body: { sessionId: 'one', sampleTiming, timingToken: 'cached' } }
        : path.endsWith('sample-timing')
          ? mode === 'http'
            ? { status: 503, body: { error: 'unavailable' } }
            : mode === 'transport'
              ? { body: {}, drop: true }
              : { body: { timingToken: 42 } }
          : { body: { accepted: true } },
    );
    await expect(
      f.reporter.report(() => {
        samples++;
        return observation;
      }),
    ).rejects.toThrow();
    expect(samples).toBe(0);
    expect(f.requests.some((r) => r.path.endsWith('observations'))).toBe(false);
  },
);
it('recovers an unknown session at challenge time before sampling and resets delivery cursor', async () => {
  let registrations = 0,
    challenges = 0,
    samples = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? {
          body: {
            sessionId: `s${++registrations}`,
            sampleTiming,
            pipelineReadIdentity: 'srt-read-query-v1',
            decodedVideoClock: transportClock,
            decoderDelivery: 'decoder-delivery-delta-v1',
          },
        }
      : path.endsWith('sample-timing')
        ? ++challenges === 2
          ? { status: 409, body: { error: 'worker_session_unknown' } }
          : { body: { timingToken: `fresh-${challenges}` } }
        : { body: { accepted: true } },
  );
  await f.reporter.report(() => {
    samples++;
    return deliveryObservation(3);
  });
  await f.reporter.report(() => {
    samples++;
    return deliveryObservation(6);
  });
  expect(registrations).toBe(2);
  expect(samples).toBe(2);
  expect(
    f.requests
      .filter((r) => r.path.endsWith('observations'))
      .map((r) => [r.body.sessionId, r.body.observation.decoderDelivery.afterOrdinal]),
  ).toEqual([
    ['s1', 0],
    ['s2', 0],
  ]);
});
it.each(['worker_session_unknown', 'worker_session_retired'])(
  'bounds challenge recovery for %s without sampling',
  async (error) => {
    let registrations = 0,
      samples = 0;
    const f = await fixture((path) =>
      path.endsWith('sessions')
        ? { body: { sessionId: `s${++registrations}`, sampleTiming } }
        : path.endsWith('sample-timing')
          ? { status: 409, body: { error } }
          : { body: { accepted: true } },
    );
    await expect(
      f.reporter.report(() => {
        samples++;
        return observation;
      }),
    ).rejects.toThrow('worker_report_rejected');
    expect(registrations).toBe(error === 'worker_session_unknown' ? 2 : 1);
    expect(samples).toBe(0);
  },
);
it('includes registration and fresh challenge in a single deadline', async () => {
  let samples = 0;
  const f = await fixture(
    (path) =>
      path.endsWith('sessions')
        ? { body: { sessionId: 'one', sampleTiming }, delay: 400 }
        : path.endsWith('sample-timing')
          ? { body: { timingToken: 'fresh' }, delay: 900 }
          : { body: { accepted: true } },
    1000,
  );
  await expect(
    f.reporter.report(() => {
      samples++;
      return observation;
    }),
  ).rejects.toThrow('worker_report_unavailable');
  expect(samples).toBe(0);
  expect(f.requests.map((r) => r.path.split('/').at(-1))).toEqual(['sessions', 'sample-timing']);
});
it.each([undefined, 'future-version'])(
  'preserves legacy timing for capability %s',
  async (sampleTiming) => {
    const f = await fixture((path) => ({
      body: path.endsWith('sessions')
        ? { sessionId: 'one', sampleTiming, timingToken: 'legacy' }
        : { accepted: true, timingToken: 'legacy-next' },
    }));
    await f.reporter.report(() => observation);
    await f.reporter.report(() => observation);
    expect(f.requests.slice(1).map((r) => r.body.timingToken)).toEqual(['legacy', 'legacy-next']);
  },
);

it('shares one recovery budget across challenge and observation session failures', async () => {
  let registrations = 0,
    challenges = 0,
    samples = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? { body: { sessionId: `s${++registrations}`, sampleTiming } }
      : path.endsWith('sample-timing') && ++challenges > 1
        ? { body: { timingToken: 'fresh' } }
        : { status: 409, body: { error: 'worker_session_unknown' } },
  );
  await expect(
    f.reporter.report(() => {
      samples++;
      return observation;
    }),
  ).rejects.toThrow('worker_report_rejected');
  expect(registrations).toBe(2);
  expect(samples).toBe(1);
  expect(f.requests.map((r) => r.path.split('/').at(-1))).toEqual([
    'sessions',
    'sample-timing',
    'sessions',
    'sample-timing',
    'observations',
  ]);
});
it('re-challenges and resamples after an observation loses its session', async () => {
  let registrations = 0,
    challenges = 0,
    samples = 0;
  const f = await fixture((path) =>
    path.endsWith('sessions')
      ? { body: { sessionId: `s${++registrations}`, sampleTiming } }
      : path.endsWith('sample-timing')
        ? { body: { timingToken: `fresh-${++challenges}` } }
        : registrations === 1
          ? { status: 409, body: { error: 'worker_session_unknown' } }
          : { body: { accepted: true } },
  );
  await f.reporter.report(() => ({ ...observation, scoreRevision: ++samples }));
  expect(samples).toBe(2);
  expect(
    f.requests
      .filter((r) => r.path.endsWith('observations'))
      .map((r) => [r.body.sessionId, r.body.timingToken, r.body.observation.scoreRevision]),
  ).toEqual([
    ['s1', 'fresh-1', 1],
    ['s2', 'fresh-2', 2],
  ]);
});
it('keeps the original deadline through challenge session recovery', async () => {
  let registrations = 0,
    samples = 0;
  const f = await fixture(
    (path) =>
      path.endsWith('sessions')
        ? {
            body: { sessionId: `s${++registrations}`, sampleTiming },
            delay: registrations === 1 ? 0 : 900,
          }
        : path.endsWith('sample-timing')
          ? { status: 409, body: { error: 'worker_session_unknown' }, delay: 400 }
          : { body: { accepted: true } },
    1000,
  );
  await expect(
    f.reporter.report(() => {
      samples++;
      return observation;
    }),
  ).rejects.toThrow('worker_report_unavailable');
  expect(samples).toBe(0);
  expect(registrations).toBe(2);
});

it.each([undefined, 'future', 'tokenbucket-90k-v1'])(
  'negotiates cap attribution independently of the legacy processing protocol: %s',
  async (version) => {
    const f = await fixture((path) => ({
      body: path.endsWith('sessions')
        ? {
            sessionId: 'one',
            decodedVideoClock: 'mpegts-pts-90k-v1',
            pipelineReadIdentity: 'srt-read-query-v1',
            workerProcessing: 'source-processing-v1',
            workerFrameCapOmissions: version,
          }
        : { accepted: true },
    }));
    const sampled: any = {
      ...observation,
      pipelineReadId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      decodedVideo: {
        clock: 'mpegts-pts-90k-v1',
        completed: null,
        invalidReason: null,
        ended: false,
      },
      processing: { scopeID: 'test-only', interval: { intentionalFrameCapOmissions: 1 } },
    };
    await f.reporter.report(() => sampled);
    expect(f.requests.at(-1)!.body.observation.processing).toEqual(
      version === 'tokenbucket-90k-v1'
        ? sampled.processing
        : { scopeID: 'test-only', interval: {} },
    );
    expect(sampled.processing.interval.intentionalFrameCapOmissions).toBe(1);
  },
);
