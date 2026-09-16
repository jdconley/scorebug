import { afterEach, expect, it } from 'vitest';
import { createServer } from 'node:http';
import { IngestRelay } from '../src/ingest.js';
const path = 'scorebug-' + 'a'.repeat(16) + '-' + 'b'.repeat(32);
const readId = '11111111-1111-4111-8111-111111111111';
const readerId = '22222222-2222-4222-8222-222222222222';
const publisherId = '33333333-3333-4333-8333-333333333333';
const publisherQuery = 'sbp1=' + readId + '.' + 'a'.repeat(64);
const clock = { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '8589934591' };
const items = () => [
  {
    id: readerId,
    state: 'read',
    path,
    query: 'sbw1=' + readId,
    scorebugReaderSource: { type: 'srtConn', id: publisherId },
    remoteAddr: 'private-reader',
  },
  {
    id: publisherId,
    state: 'publish',
    path,
    query: publisherQuery,
    scorebugTransportClock: clock,
    remoteAddr: 'private-publisher',
  },
];
const closes: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const close of closes.splice(0)) await close();
});
async function fixture(body: unknown, status = 200, raw?: string) {
  const requests: { url: string; auth?: string; cache?: string }[] = [];
  const server = createServer((req, res) => {
    requests.push({
      url: req.url!,
      auth: req.headers.authorization,
      cache: req.headers['cache-control'] as string,
    });
    res.writeHead(status, { 'content-type': 'application/json', location: '/redirect' });
    res.end(raw ?? JSON.stringify(body));
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  closes.push(
    () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  );
  const port = (server.address() as { port: number }).port;
  return {
    requests,
    client: new IngestRelay({
      apiUrl: `http://127.0.0.1:${port}`,
      username: 'admin',
      password: 'private-password',
      timeoutMs: 1000,
    }),
  };
}
const page = (entries: unknown[]) => ({ pageCount: 1, itemCount: entries.length, items: entries });
it('follows actual reader source with bounded private HTTP lookup and sanitized result', async () => {
  const f = await fixture(page(items()));
  expect(await f.client.publication(path, readId)).toEqual({
    readerId,
    publisherId,
    publisherQuery,
    clock,
  });
  expect(f.requests).toEqual([
    {
      url: '/v3/srtconns/list?itemsPerPage=100&page=0',
      auth: 'Basic ' + Buffer.from('admin:private-password').toString('base64'),
      cache: 'no-cache, no-store',
    },
  ]);
});
it.each([
  'missing-reader',
  'missing-publisher',
  'missing-source',
  'missing-clock',
  'duplicate-reader',
  'duplicate-publisher',
  'wrong-reader-path',
  'wrong-publisher-path',
  'wrong-state',
  'wrong-type',
  'same-id',
  'uppercase-id',
  'newline-id',
  'wrong-origin',
  'negative-origin',
  'overflow-origin',
  'leading-zero-origin',
  'newline-origin',
])('rejects or omits %s evidence', async (mode) => {
  const list: any[] = items();
  if (mode === 'missing-reader') list.shift();
  if (mode === 'missing-publisher') list.pop();
  if (mode === 'missing-source') delete list[0].scorebugReaderSource;
  if (mode === 'missing-clock') delete list[1].scorebugTransportClock;
  if (mode === 'duplicate-reader') list.push({ ...list[0] });
  if (mode === 'duplicate-publisher') list.push({ ...list[1] });
  if (mode === 'wrong-reader-path') list[0].path += 'other';
  if (mode === 'wrong-publisher-path') list[1].path += 'other';
  if (mode === 'wrong-state') list[0].state = 'publish';
  if (mode === 'wrong-type') list[0].scorebugReaderSource.type = 'rtspSession';
  if (mode === 'same-id') list[0].id = publisherId;
  if (mode === 'uppercase-id') list[0].id = 'ABCDEFAB-2222-4222-8222-222222222222';
  if (mode === 'newline-id') list[0].id += '\n';
  if (mode.endsWith('origin'))
    list[1].scorebugTransportClock = {
      ...clock,
      originPTS: (
        {
          'wrong-origin': 'not-a-number',
          'negative-origin': '-1',
          'overflow-origin': '8589934592',
          'leading-zero-origin': '09000',
          'newline-origin': '9000\n',
        } as any
      )[mode],
    };
  const f = await fixture(page(list));
  const result = await f.client.publication(path, readId).catch(() => undefined);
  expect(result).toBeUndefined();
});
it.each([
  { pageCount: 2, itemCount: 2, items: items() },
  { pageCount: 1, itemCount: 3, items: items() },
  { pageCount: 1, itemCount: 101, items: Array(101).fill({}) },
  { pageCount: 1, itemCount: 2, items: {} },
])('rejects incomplete/malformed inventory %j', async (body) => {
  const f = await fixture(body);
  await expect(f.client.publication(path, readId)).rejects.toThrow();
});
it('rejects response bytes beyond 256KiB even with only two items', async () => {
  const f = await fixture({ ...page(items()), padding: 'x'.repeat(256 * 1024) });
  await expect(f.client.publication(path, readId)).rejects.toThrow();
});
it.each([302, 401, 500])('rejects HTTP %i without redirect or body disclosure', async (status) => {
  const f = await fixture({ error: 'private-leak' }, status);
  await expect(f.client.publication(path, readId)).rejects.not.toThrow('private-leak');
  expect(f.requests).toHaveLength(1);
});
it('validates requested path and UUID before I/O', async () => {
  const f = await fixture(page(items()));
  for (const [p, id] of [
    [path + '\n', readId],
    [path, readId + '\n'],
  ])
    await expect(f.client.publication(p!, id!)).rejects.toThrow();
  expect(f.requests).toEqual([]);
});
it.each([null, [], 'invalid', {}, { id: readerId, state: 'other', path, query: '' }])(
  'rejects malformed unrelated inventory item %j',
  async (item) => {
    const f = await fixture(page([...items(), item]));
    await expect(f.client.publication(path, readId)).rejects.toThrow();
  },
);

const probe = {
  convention: 'mpegts-null-probe-v1',
  id: '60000000-0000-4000-8000-00000000000d',
  publishingGeneration: '18446744073709551615',
  bitRate: 1000000,
  deliveredMessages: '2',
  deliveredPayloadBytes: '2632',
  nextSequence: '2',
  pendingPackets: 3,
  observedAtNanoseconds: '1000000000',
  firstDeliveredAtNanoseconds: '100000000',
  lastDeliveredAtNanoseconds: '900000000',
};
it('sanitizes probe evidence from the selected publisher without changing identity', async () => {
  const list: any[] = items();
  list[0].scorebugBandwidthProbe = { ...probe, id: readId };
  list[1].scorebugBandwidthProbe = { ...probe, privateField: 'must-not-leak' };
  const f = await fixture(page(list));
  expect(await f.client.publication(path, readId)).toEqual({
    readerId,
    publisherId,
    publisherQuery,
    clock,
    receiverProbe: probe,
  });
});
it.each([
  { convention: 'other' },
  { id: '00000000-0000-0000-0000-000000000000' },
  { id: probe.id.toUpperCase() },
  { id: probe.id + '\n' },
  { publishingGeneration: '0' },
  { publishingGeneration: '18446744073709551616' },
  { publishingGeneration: '01' },
  { publishingGeneration: '1\n' },
  { bitRate: 0 },
  { bitRate: 2000001 },
  { bitRate: 1.5 },
  { deliveredPayloadBytes: '2631' },
  { nextSequence: '3' },
  { deliveredMessages: '12749', deliveredPayloadBytes: '16777684', nextSequence: '12749' },
  {
    deliveredMessages: '12748',
    deliveredPayloadBytes: '16776368',
    nextSequence: '12748',
    pendingPackets: 1,
  },
  {
    deliveredMessages: '12748',
    deliveredPayloadBytes: '16776368',
    nextSequence: '12748',
    pendingPackets: 6,
  },
  { pendingPackets: -1 },
  { pendingPackets: 7 },
  { pendingPackets: 1.5 },
  { observedAtNanoseconds: '86400000000001' },
  { observedAtNanoseconds: '1e9' },
  { firstDeliveredAtNanoseconds: '900000001' },
  { firstDeliveredAtNanoseconds: undefined },
  { lastDeliveredAtNanoseconds: '1000000001' },
  { lastDeliveredAtNanoseconds: undefined },
  { invalidReason: 'unknown' },
  { invalidReason: null },
  { deliveredMessages: '0', deliveredPayloadBytes: '0', nextSequence: '0' },
  { deliveredMessages: '1', deliveredPayloadBytes: '1316', nextSequence: '1' },
])('omits malformed optional probe while retaining publication: %j', async (fault) => {
  const list: any[] = items();
  list[1].scorebugBandwidthProbe = { ...probe, ...fault };
  const f = await fixture(page(list));
  expect(await f.client.publication(path, readId)).toEqual({
    readerId,
    publisherId,
    publisherQuery,
    clock,
  });
});
it('retains valid empty, one-message and invalidated snapshots for diagnostics', async () => {
  for (const snapshot of [
    {
      ...probe,
      deliveredMessages: '0',
      deliveredPayloadBytes: '0',
      nextSequence: '0',
      firstDeliveredAtNanoseconds: undefined,
      lastDeliveredAtNanoseconds: undefined,
    },
    {
      ...probe,
      deliveredMessages: '1',
      deliveredPayloadBytes: '1316',
      nextSequence: '1',
      lastDeliveredAtNanoseconds: probe.firstDeliveredAtNanoseconds,
    },
    { ...probe, invalidReason: 'sequence' },
    {
      ...probe,
      deliveredMessages: '12748',
      deliveredPayloadBytes: '16776368',
      nextSequence: '12748',
      pendingPackets: 0,
    },
  ]) {
    const list: any[] = items();
    list[1].scorebugBandwidthProbe = snapshot;
    const f = await fixture(page(list));
    expect((await f.client.publication(path, readId)) as any).toMatchObject({
      receiverProbe: JSON.parse(JSON.stringify(snapshot)),
    });
  }
});
