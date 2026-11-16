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
    url,
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
      return { body: { sessionId: 'one' } };
    }
    events.push('send');
    return { body: { accepted: true } };
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
          body: { sessionId: `session-${++registrations}` },
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

it('does not sample when registration exceeds the deadline', async () => {
  let samples = 0;
  const f = await fixture(() => ({ body: { sessionId: 'one' }, delay: 800 }), 200);
  await expect(
    f.reporter.report(() => {
      samples++;
      return observation;
    }),
  ).rejects.toThrow('worker_report_unavailable');
  expect(samples).toBe(0);
  expect(f.requests).toHaveLength(1);
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
it('attaches the configured output profile to every observation', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions') ? { sessionId: 'session-one' } : { accepted: true },
  }));
  const output = { width: 1920, height: 1080, fps: 30, bitrateKbps: 6000 };
  const reporter = new WorkerReporter(f.url, 'private-token', 'mac', 1000, 'run-one', output);
  const sample = { ...observation };
  await reporter.report(() => sample);
  expect(f.requests[1]!.body.observation).toEqual({ ...observation, output });
  expect(sample).not.toHaveProperty('output');
});

it('registers its OUTPUT_ID so the API can default a broadcast to it', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions') ? { sessionId: 'session-one' } : { accepted: true },
  }));
  const reporter = new WorkerReporter(
    f.url,
    'private-token',
    'mac',
    1000,
    'run-one',
    undefined,
    'local-sink',
  );
  await reporter.report(() => null);
  expect(f.requests[0]!.body).toEqual({
    workerId: 'mac',
    runId: 'run-one',
    outputId: 'local-sink',
  });
  expect(
    () => new WorkerReporter(f.url, 'private-token', 'mac', 1000, 'run', undefined, 'bad id'),
  ).toThrow('invalid_worker_report_configuration');
});
