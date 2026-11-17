import { createServer } from 'node:http';
import { afterEach, expect, it } from 'vitest';
import { WorkerClient } from '../src/worker-client.js';

const selection = {
  workerId: 'mac',
  outputId: 'youtube',
  captureDeviceId: 'phone',
  recordingId: 'archive',
};
const broadcast = { desired: 'running', generation: 1, selection };
const destination = 'rtmps://a.rtmp.youtube.com/live2/private-stream-key';
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
      rules: { bestOf: 3 as 3 | 5 },
      completedSets: [] as unknown[],
      scorebugStyle: 'bar',
      broadcast: { desired: 'running', generation: 1 },
    },
    output: { publishUrl: destination } as { publishUrl: string | null },
    media: { gameId: 'match', broadcast: structuredClone(broadcast) },
  },
});
const connection = () => ({
  connection: {
    gameId: 'match',
    generation: 1,
    readUrl: 'rtmps://live.cloudflare.com:443/live/private-play-key',
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
    outputId: 'youtube',
    publishUrl: destination,
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
it('rejects malformed response values and any source but Stream RTMPS playback', async () => {
  for (const readUrl of [
    'file:///private/file',
    'srt://host:8890?streamid=read:match',
    'rtmp://live.cloudflare.com/live/playkey',
  ]) {
    const source = connection();
    source.connection.readUrl = readUrl;
    const f = await fixture((_path, index) => ({ body: index === 2 ? source : snapshot() }));
    await expect(f.client.load()).rejects.toThrow('invalid_worker_response');
  }
  const bad = snapshot();
  bad.assignment.match.score.home = -1;
  const g = await fixture(() => ({ body: bad }));
  await expect(g.client.load()).rejects.toThrow('invalid_worker_response');
  for (const field of ['rules', 'completedSets', 'scorebugStyle'] as const) {
    const partial = snapshot() as { assignment: { match: Record<string, unknown> } };
    delete partial.assignment.match[field];
    const h = await fixture(() => ({ body: partial }));
    await expect(h.client.load()).rejects.toThrow('invalid_worker_response');
  }
  const styled = snapshot();
  styled.assignment.match.scorebugStyle = 'hologram';
  const i = await fixture(() => ({ body: styled }));
  await expect(i.client.load()).rejects.toThrow('invalid_worker_response');
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
  const styled = snapshot();
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
});

it('takes the YouTube ingest from the latest snapshot and requires an RTMP(S) output', async () => {
  const withOutput = (publishUrl: string | null) => {
    const value = snapshot();
    value.assignment.output = { publishUrl };
    return value;
  };
  const f = await fixture((_path, index) => ({
    body: index === 2 ? connection() : withOutput(destination),
  }));
  expect((await f.client.load())?.publishUrl).toBe(destination);
  const none = await fixture((_path, index) => ({
    body: index === 2 ? connection() : withOutput(null),
  }));
  await expect(none.client.load()).rejects.toThrow('invalid_worker_response');
  const unsafe = await fixture((_path, index) => ({
    body: index === 2 ? connection() : withOutput('file:///etc/passwd'),
  }));
  await expect(unsafe.client.load()).rejects.toThrow('invalid_worker_response');
});
