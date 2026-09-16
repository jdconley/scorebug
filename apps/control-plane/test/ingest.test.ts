import { afterEach, expect, it } from 'vitest';
import { createServer } from 'node:http';
import { IngestRelay, deriveIngestGrant, ingestPathPrefix } from '../src/ingest.js';

const selection = {
  workerId: 'mac',
  outputId: 'local-sink',
  captureDeviceId: 'phone',
  recordingId: 'archive',
};
const grant = () =>
  deriveIngestGrant(
    'installation-secret-not-production',
    'match',
    selection,
    1,
    '127.0.0.1',
    18890,
  );
const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const close of cleanup.splice(0)) await close();
});
async function relay(
  handler: (
    method: string,
    path: string,
    body: any,
    auth: string | undefined,
  ) => { status?: number; body?: unknown; headers?: Record<string, string>; delayMs?: number },
  timeoutMs = 1000,
) {
  const requests: { method: string; path: string; body: any; auth?: string }[] = [];
  const server = createServer(async (req, res) => {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    const request = {
      method: req.method!,
      path: req.url!,
      body: raw ? JSON.parse(raw) : null,
      auth: req.headers.authorization,
    };
    requests.push(request);
    const response = handler(request.method, request.path, request.body, request.auth);
    if (response.delayMs) await new Promise((resolve) => setTimeout(resolve, response.delayMs));
    res.writeHead(response.status ?? 200, {
      'content-type': 'application/json',
      ...response.headers,
    });
    res.end(JSON.stringify(response.body ?? { status: 'ok' }));
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  cleanup.push(
    () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  );
  const address = server.address() as { port: number };
  return {
    client: new IngestRelay({
      apiUrl: `http://127.0.0.1:${address.port}`,
      username: 'admin',
      password: 'private-api-password',
      timeoutMs,
    }),
    requests,
    url: `http://127.0.0.1:${address.port}`,
  };
}
it('derives stable, separate capabilities scoped to installation and broadcast identity', () => {
  const a = grant();
  expect(a).toEqual(grant());
  expect(a.path).toMatch(/^scorebug-[a-f0-9]{16}-[a-f0-9]{32}$/);
  expect(ingestPathPrefix('installation-secret-not-production')).toBe(a.path.slice(0, 26));
  expect(a.publishPassphrase).not.toEqual(a.readPassphrase);
  const publisher = new URL(a.publishUrl),
    reader = new URL(a.readUrl);
  expect(publisher.protocol).toBe('srt:');
  expect(publisher.searchParams.get('streamid')).toBe(`publish:${a.path}`);
  expect(reader.searchParams.get('streamid')).toBe(`read:${a.path}`);
  expect(publisher.searchParams.get('passphrase')).toBe(a.publishPassphrase);
  expect(reader.searchParams.get('passphrase')).toBe(a.readPassphrase);
  expect(publisher.searchParams.get('pkt_size')).toBe('1316');
  for (const changed of [
    deriveIngestGrant('different-installation-secret', 'match', selection, 1, 'localhost', 8890),
    deriveIngestGrant(
      'installation-secret-not-production',
      'match',
      selection,
      2,
      'localhost',
      8890,
    ),
    deriveIngestGrant(
      'installation-secret-not-production',
      'match',
      { ...selection, recordingId: 'other' },
      1,
      'localhost',
      8890,
    ),
  ]) {
    expect(changed.path).not.toBe(a.path);
    expect(changed.publishPassphrase).not.toBe(a.publishPassphrase);
  }
});
it('lists only exact paths in this installation namespace across bounded pages', async () => {
  const prefix = grant().path.slice(0, 26);
  const second = `${prefix}${'a'.repeat(32)}`;
  const f = await relay((_method, path) => ({
    body: {
      pageCount: 2,
      items: path.includes('page=0&')
        ? [{ name: grant().path }, { name: 'fixture' }, { name: `~${prefix}.*` }]
        : [{ name: second }, { name: `scorebug-${'0'.repeat(16)}-${'1'.repeat(32)}` }],
    },
  }));
  expect(await f.client.list(prefix)).toEqual([grant().path, second]);
  expect(f.requests.map((r) => r.path)).toEqual([
    '/v3/config/paths/list?page=0&itemsPerPage=100',
    '/v3/config/paths/list?page=1&itemsPerPage=100',
  ]);
  await expect(f.client.list('scorebug-')).rejects.toThrow('invalid_relay_prefix');
});
it('rejects excessive or malformed pagination instead of returning a partial inventory', async () => {
  for (const body of [
    { pageCount: 11, items: [] },
    { pageCount: 1, items: [{ name: 3 }] },
  ]) {
    const f = await relay(() => ({ body }));
    await expect(f.client.list(grant().path.slice(0, 26))).rejects.toThrow(
      'relay_invalid_response',
    );
  }
});
it.each(['', 'unknown-codec'])(
  'rejects malformed codec %j rather than reporting a healthy source',
  async (codec) => {
    const f = await relay(() => ({
      body: {
        online: true,
        available: true,
        inboundBytes: 1,
        source: { type: 'srtConn' },
        tracks2: [{ codec }],
      },
    }));
    await expect(f.client.status(grant().path)).rejects.toThrow('relay_invalid_response');
  },
);
it('bounds a stalled relay request without exposing connection details', async () => {
  const f = await relay(() => ({ delayMs: 100, body: {} }), 10);
  await expect(f.client.status(grant().path)).rejects.toThrow('relay_unavailable');
});
it('rejects management redirects without forwarding credentials', async () => {
  const target = await relay(() => ({}));
  const f = await relay(() => ({ status: 302, headers: { location: target.url } }));
  await expect(f.client.status(grant().path)).rejects.toThrow('relay_unavailable');
  expect(target.requests).toHaveLength(0);
});
it('rejects unsafe identity, generation, endpoint, and management configuration', () => {
  for (const host of ['host/path', 'user@host', 'host?x', 'host:8890', ''])
    expect(() =>
      deriveIngestGrant('installation-secret-not-production', 'match', selection, 1, host, 8890),
    ).toThrow();
  expect(() => deriveIngestGrant('short', 'match', selection, 1, 'localhost', 8890)).toThrow();
  expect(() =>
    deriveIngestGrant(
      'installation-secret-not-production',
      '../match',
      selection,
      1,
      'localhost',
      8890,
    ),
  ).toThrow();
  for (const generation of [0, -1, 1.1, Number.MAX_SAFE_INTEGER + 1])
    expect(() =>
      deriveIngestGrant(
        'installation-secret-not-production',
        'match',
        selection,
        generation,
        'localhost',
        8890,
      ),
    ).toThrow();
  for (const url of [
    'file:///tmp/api',
    'http://user:pass@localhost',
    'http://localhost/?token=secret',
    'http://localhost/#x',
  ])
    expect(() => new IngestRelay({ apiUrl: url, username: 'admin', password: 'secret' })).toThrow();
});
it('creates an encrypted publisher path through authenticated private API and retries without interruption', async () => {
  let conf: any = null;
  const f = await relay((method, path, body) => {
    if (method === 'GET') return conf ? { body: conf } : { status: 404 };
    expect(path).toBe(`/v3/config/paths/add/${grant().path}`);
    conf = body;
    return {};
  });
  await f.client.ensure(grant());
  await f.client.ensure(grant());
  expect(conf).toEqual({
    source: 'publisher',
    overridePublisher: false,
    alwaysAvailable: false,
    record: false,
    srtPublishPassphrase: grant().publishPassphrase,
    srtReadPassphrase: grant().readPassphrase,
  });
  expect(f.requests.map((r) => r.method)).toEqual(['GET', 'POST', 'GET']);
  for (const request of f.requests)
    expect(request.auth).toBe(
      `Basic ${Buffer.from('admin:private-api-password').toString('base64')}`,
    );
});
it('handles a competing identical creation without changing a live path', async () => {
  let reads = 0;
  const g = grant();
  const f = await relay((method) =>
    method === 'POST'
      ? { status: 400 }
      : ++reads === 1
        ? { status: 404 }
        : {
            body: {
              source: 'publisher',
              overridePublisher: false,
              alwaysAvailable: false,
              record: false,
              srtPublishPassphrase: g.publishPassphrase,
              srtReadPassphrase: g.readPassphrase,
            },
          },
  );
  await f.client.ensure(g);
  expect(f.requests.map((r) => r.method)).toEqual(['GET', 'POST', 'GET']);
});
it('refuses an existing path whose security settings differ', async () => {
  const f = await relay(() => ({
    body: { source: 'publisher', overridePublisher: true, srtPublishPassphrase: 'other-secret' },
  }));
  await expect(f.client.ensure(grant())).rejects.toThrow('relay_path_conflict');
  expect(f.requests).toHaveLength(1);
});
it('revokes a path idempotently and rejects unrelated path identifiers', async () => {
  const f = await relay(() => ({ status: 404 }));
  await f.client.remove(grant().path);
  expect(f.requests[0]?.method).toBe('DELETE');
  expect(f.requests[0]?.path).toBe(`/v3/config/paths/delete/${grant().path}`);
  await expect(f.client.remove('fixture')).rejects.toThrow('invalid_relay_path');
  expect(f.requests).toHaveLength(1);
});
it('returns observed readiness and counters without exposing source or reader details', async () => {
  const f = await relay(() => ({
    body: {
      name: grant().path,
      online: true,
      available: true,
      inboundBytes: 1200,
      source: { type: 'srtConn', id: 'private' },
      tracks2: [{ codec: 'H264' }, { codec: 'MPEG-4 Audio' }],
      readers: [{ query: 'password=secret' }],
    },
  }));
  expect(await f.client.status(grant().path)).toEqual({
    ready: true,
    inboundBytes: 1200,
    tracks: ['H264', 'MPEG-4 Audio'],
  });
});
it('reports absent source as not ready and never treats malformed or failed API response as healthy', async () => {
  const missing = await relay(() => ({ status: 404 }));
  expect(await missing.client.status(grant().path)).toEqual({
    ready: false,
    inboundBytes: 0,
    tracks: [],
  });
  const malformed = await relay(() => ({
    body: { online: true, available: true, inboundBytes: -1 },
  }));
  await expect(malformed.client.status(grant().path)).rejects.toThrow('relay_invalid_response');
  const failed = await relay(() => ({
    status: 401,
    body: { error: 'private-api-password srt://secret' },
  }));
  await expect(failed.client.status(grant().path)).rejects.toThrow('relay_http_401');
});

it('sets native publish peer latency only, preserving read URL and capability identity', () => {
  const baseline = grant();
  const changed = deriveIngestGrant(
    'installation-secret-not-production',
    'match',
    selection,
    1,
    '127.0.0.1',
    18890,
    400,
  );
  expect(new URL(baseline.publishUrl).searchParams.has('peerlatency')).toBe(false);
  expect(new URL(changed.publishUrl).searchParams.get('peerlatency')).toBe('400');
  const publish = new URL(changed.publishUrl);
  publish.searchParams.delete('peerlatency');
  expect(publish.toString()).toBe(baseline.publishUrl);
  expect({ ...changed, publishUrl: baseline.publishUrl }).toEqual(baseline);
  for (const value of [0, 119, 2001, 400.5, NaN, Infinity, '400', null])
    expect(() =>
      deriveIngestGrant(
        'installation-secret-not-production',
        'match',
        selection,
        1,
        '127.0.0.1',
        18890,
        value as number,
      ),
    ).toThrow('invalid_ingest_identity');
});

it('relative pacing changes only the native publish URL', () => {
  const baseline = grant();
  const changed = deriveIngestGrant(
    'installation-secret-not-production',
    'match',
    selection,
    1,
    '127.0.0.1',
    18890,
    undefined,
    'relative',
  );
  const url = new URL(changed.publishUrl);
  expect(url.searchParams.get('maxbw')).toBe('0');
  expect(url.searchParams.has('inputbw')).toBe(false);
  expect(url.searchParams.has('oheadbw')).toBe(false);
  url.searchParams.delete('maxbw');
  expect(url.toString()).toBe(baseline.publishUrl);
  expect({ ...changed, publishUrl: baseline.publishUrl }).toEqual(baseline);
  for (const pacing of ['', 0, null, 'default'])
    expect(() =>
      deriveIngestGrant(
        'installation-secret-not-production',
        'match',
        selection,
        1,
        '127.0.0.1',
        18890,
        undefined,
        pacing as 'relative',
      ),
    ).toThrow('invalid_ingest_identity');
});
