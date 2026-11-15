import { createServer } from 'node:http';
import { afterEach, expect, it } from 'vitest';
import { WorkerClient } from '../src/worker-client.js';

const selection = {
  workerId: 'mac',
  outputId: 'local-sink',
  captureDeviceId: 'phone',
  recordingId: 'archive',
};
const broadcast = { desired: 'running', generation: 1, selection };
const snapshot = () => ({
  assignment: {
    match: {
      id: 'match',
      revision: 1,
      status: 'active',
      teams: {
        home: { name: 'Home', shortName: 'H', color: '#123456' },
        away: { name: 'Away', shortName: 'A', color: '#654321' },
      },
      score: { home: 0, away: 0, set: 1, homeSets: 0, awaySets: 0 },
      broadcast: { desired: 'running', generation: 1 },
    },
    media: { gameId: 'match', broadcast: structuredClone(broadcast) },
  },
});
const connection = () => ({
  connection: {
    gameId: 'match',
    generation: 1,
    readUrl: 'srt://localhost:8890?streamid=read:match&passphrase=private-key',
    source: { ready: true, inboundBytes: 300, tracks: ['H264', 'MPEG-4 Audio'] },
  },
});
const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const close of cleanup.splice(0)) await close();
});
async function fixture(
  handler: (
    path: string,
    index: number,
  ) => { body?: unknown; status?: number; delay?: number; headers?: Record<string, string> },
  timeoutMs = 2500,
) {
  const requests: { path: string; auth?: string }[] = [];
  const server = createServer(async (req, res) => {
    requests.push({ path: req.url!, auth: req.headers.authorization });
    const result = handler(req.url!, requests.length);
    if (result.delay) await new Promise((resolve) => setTimeout(resolve, result.delay));
    res.writeHead(result.status ?? 200, { 'content-type': 'application/json', ...result.headers });
    res.end(JSON.stringify(result.body ?? {}));
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  cleanup.push(
    () =>
      new Promise((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  );
  const url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  return {
    requests,
    url,
    client: new WorkerClient(`${url}/prefix/`, 'private-worker-token', 'mac', timeoutMs),
  };
}
it('loads source access between two snapshots and uses the latest authoritative score', async () => {
  const latest = snapshot();
  latest.assignment.match.revision = 2;
  latest.assignment.match.score.home = 1;
  const f = await fixture((_path, index) => ({
    body: index === 1 ? snapshot() : index === 2 ? connection() : latest,
  }));
  expect(await f.client.load()).toEqual({
    gameId: 'match',
    generation: 1,
    scoreRevision: 2,
    overlay:
      JSON.stringify({
        style: 'bar',
        label: null,
        bestOf: 3,
        teams: snapshot().assignment.match.teams,
        score: { home: 1, away: 0, set: 1, homeSets: 0, awaySets: 0 },
        completedSets: [],
        serving: null,
      }) + '\n',
    readUrl: connection().connection.readUrl,
    sourceReady: true,
    outputId: 'local-sink',
  });
  expect(f.requests.map((r) => r.path)).toEqual([
    '/prefix/v1/worker/snapshot?workerId=mac',
    '/prefix/v1/worker/connection?workerId=mac',
    '/prefix/v1/worker/snapshot?workerId=mac',
  ]);
  expect(f.requests.every((r) => r.auth === 'Bearer private-worker-token')).toBe(true);
});
it('returns idle without retrieving credentials when no assignment exists', async () => {
  const f = await fixture(() => ({ body: { assignment: null } }));
  expect(await f.client.load()).toBeNull();
  expect(f.requests).toHaveLength(1);
});
it('returns waiting-source input rather than claiming output is live', async () => {
  const source = connection();
  source.connection.source.ready = false;
  const f = await fixture((_path, index) => ({ body: index === 2 ? source : snapshot() }));
  expect(await f.client.load()).toMatchObject({ sourceReady: false });
});
it.each(['generation', 'ended', 'worker', 'match', 'stopped'])(
  'returns no runnable input if %s changes during credential retrieval',
  async (kind) => {
    const latest = snapshot();
    if (kind === 'generation') latest.assignment.media.broadcast.generation = 2;
    if (kind === 'ended') latest.assignment.match.status = 'ended';
    if (kind === 'worker') latest.assignment.media.broadcast.selection.workerId = 'other';
    if (kind === 'match') latest.assignment.match.id = 'other';
    if (kind === 'stopped') latest.assignment.media.broadcast.desired = 'stopped';
    const f = await fixture((_path, index) => ({
      body: index === 1 ? snapshot() : index === 2 ? connection() : latest,
    }));
    expect(await f.client.load()).toBeNull();
  },
);
it('rejects malformed response values and unsafe source transports', async () => {
  const source = connection();
  source.connection.readUrl = 'file:///private/file';
  const f = await fixture((_path, index) => ({ body: index === 2 ? source : snapshot() }));
  await expect(f.client.load()).rejects.toThrow('invalid_worker_response');
  const bad = snapshot();
  bad.assignment.match.score.home = -1;
  const g = await fixture(() => ({ body: bad }));
  await expect(g.client.load()).rejects.toThrow('invalid_worker_response');
});
it('uses one bounded deadline for the complete fetch sequence', async () => {
  const f = await fixture(
    (_path, index) => ({ body: index === 2 ? connection() : snapshot(), delay: 20 }),
    30,
  );
  await expect(f.client.load()).rejects.toThrow('worker_unavailable');
});
it('does not follow redirects or reveal remote error bodies', async () => {
  const target = await fixture(() => ({ body: snapshot() }));
  const redirected = await fixture(() => ({ status: 302, headers: { location: target.url } }));
  await expect(redirected.client.load()).rejects.toThrow('worker_unavailable');
  expect(target.requests).toHaveLength(0);
  const failed = await fixture(() => ({ status: 503, body: { error: 'private-worker-token' } }));
  await expect(failed.client.load()).rejects.toThrow('worker_http_503');
});
it('rejects credentials in the control URL and unsafe worker identities', () => {
  for (const url of ['file:///private', 'http://token@localhost', 'https://host/?token=private'])
    expect(() => new WorkerClient(url, 'token', 'mac')).toThrow();
  expect(() => new WorkerClient('http://localhost', 'token', '../other')).toThrow();
});
it('carries the scorebug style, best-of and completed sets into the overlay', async () => {
  const styled = snapshot() as ReturnType<typeof snapshot> & {
    assignment: { match: Record<string, unknown> };
  };
  Object.assign(styled.assignment.match, {
    scorebugStyle: 'setCard',
    rules: { bestOf: 5, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
    completedSets: [{ set: 1, home: 25, away: 20, winner: 'home', overrideReason: null }],
  });
  const f = await fixture((path) => ({
    body: path.includes('/connection') ? connection() : styled,
  }));
  expect(JSON.parse((await f.client.load())!.overlay)).toMatchObject({
    style: 'setCard',
    bestOf: 5,
    completedSets: [{ set: 1, home: 25, away: 20, winner: 'home' }],
  });
  Object.assign(styled.assignment.match, { scorebugStyle: 'hologram' });
  expect(JSON.parse((await f.client.load())!.overlay).style).toBe('bar');
});
