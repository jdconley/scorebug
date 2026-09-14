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
const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const close of cleanup.splice(0)) await close();
});
async function fixture(
  handler: (path: string, body: any) => { status?: number; body: unknown; delay?: number },
  timeout = 1000,
) {
  const requests: { path: string; body: any; auth: string | undefined }[] = [];
  const server = createServer(async (req, res) => {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const body = JSON.parse(raw);
    requests.push({ path: req.url!, body, auth: req.headers.authorization });
    const result = handler(req.url!, body);
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
  await f.reporter.report(observation);
  await f.reporter.report({ ...observation, scoreRevision: 3 });
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
  await f.reporter.report(observation);
  expect(registrations).toBe(2);
  expect(f.requests.at(-1)!.body.sessionId).toBe('session-2');
  const retired = await fixture((path) =>
    path.endsWith('sessions')
      ? { body: { sessionId: 'one' } }
      : { status: 409, body: { error: 'worker_session_retired' } },
  );
  await expect(retired.reporter.report(observation)).rejects.toThrow('worker_report_rejected');
  expect(retired.requests).toHaveLength(2);
});
it('coalesces simultaneous calls and copies observations before async registration', async () => {
  const f = await fixture((path) => ({
    body: path.endsWith('sessions') ? { sessionId: 'one' } : { accepted: true },
    delay: 20,
  }));
  const mutable = { ...observation };
  const first = f.reporter.report(mutable);
  mutable.scoreRevision = 99;
  const second = f.reporter.report(observation);
  await Promise.all([first, second]);
  expect(f.requests).toHaveLength(2);
  expect(f.requests[1]!.body.observation.scoreRevision).toBe(2);
});
it('bounds unavailable reporting and exposes only safe fixed errors', async () => {
  const slow = await fixture(() => ({ body: { sessionId: 'one' }, delay: 100 }), 20);
  await expect(slow.reporter.report(observation)).rejects.toThrow('worker_report_unavailable');
  const failed = await fixture(() => ({ status: 500, body: { error: 'PRIVATE_URL_OR_TOKEN' } }));
  await expect(failed.reporter.report(observation)).rejects.toThrow('worker_report_rejected');
  const invalid = await fixture(() => ({ body: { sessionId: 42 } }));
  await expect(invalid.reporter.report(observation)).rejects.toThrow(
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
  await expect(f.reporter.report(observation)).rejects.toThrow('worker_report_unavailable');
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
