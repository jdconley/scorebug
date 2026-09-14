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
      delay: 40,
    }),
    65,
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
    () => ({ body: { sessionId: 'one', timingToken: 'marker-1' }, delay: 80 }),
    20,
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
      30,
    );
    await f.reporter.report(() => null);
    await expect(
      f.reporter.report(() => {
        const end = performance.now() + 60;
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
        ? { body: { sessionId: `session-${++registrations}` }, delay: registrations === 1 ? 0 : 80 }
        : { status: 409, body: { error: 'worker_session_unknown' }, delay: 40 },
    90,
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
