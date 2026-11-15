import { expect, it } from 'vitest';
import { deriveIngestGrant, type IngestGrant, type SourceObservation } from '../src/ingest.js';
import { RelayLifecycle, RelayLifecycleError, type RelayDesired } from '../src/relay-lifecycle.js';
import { attemptOf } from './helpers.js';

const config = {
  installationSecret: 'installation-secret-not-production',
  host: 'localhost',
  port: 18890,
};
const running = (generation = 1): RelayDesired => ({
  gameId: 'match',
  generation,
  selection: {
    workerId: 'mac',
    outputId: 'local-sink',
    captureDeviceId: 'phone',
    recordingId: 'archive',
  },
});
const grantFor = (value: RelayDesired) =>
  deriveIngestGrant(
    config.installationSecret,
    value.gameId,
    value.selection,
    value.generation,
    config.host,
    config.port,
  );
const request = { gameId: 'match', generation: 1, deviceId: 'phone', recordingId: 'archive' };
const deferred = () => {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
};
function fixture(initial: RelayDesired | null = running()) {
  let desired = initial;
  const paths = new Set<string>();
  const calls: string[] = [];
  const source: SourceObservation = { ready: false, inboundBytes: 0, tracks: [] };
  const relay = {
    async list(prefix: string) {
      calls.push(`list:${prefix}`);
      return [...paths];
    },
    async ensure(grant: IngestGrant) {
      calls.push(`ensure:${grant.path}`);
      paths.add(grant.path);
    },
    async remove(path: string) {
      calls.push(`remove:${path}`);
      paths.delete(path);
    },
    async status(path: string) {
      calls.push(`status:${path}`);
      return source;
    },
  };
  const create = () => new RelayLifecycle(relay, config, () => desired);
  return {
    paths,
    calls,
    relay,
    source,
    create,
    lifecycle: create(),
    setDesired(value: RelayDesired | null) {
      desired = value;
    },
  };
}

it('provisions only the selected capture and returns only its publish capability', async () => {
  const f = fixture();
  const result = await f.lifecycle.publish(request);
  expect(result).toEqual({
    gameId: 'match',
    generation: 1,
    recordingId: 'archive',
    publishUrl: grantFor(running()).publishUrl,
  });
  expect([...f.paths]).toEqual([grantFor(running()).path]);
});

it('attests each publishing attempt without changing the path or worker capability', async () => {
  const f = fixture();
  const id = '11111111-2222-4333-8444-555555555555';
  const next = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
  const first = await f.lifecycle.publish({ ...request, publishingAttemptId: id });
  const repeated = await f.create().publish({ ...request, publishingAttemptId: id });
  expect(first).toEqual(repeated);
  expect(first.publishingAttemptId).toBe(id);
  const second = await f.lifecycle.publish({ ...request, publishingAttemptId: next });
  expect(second.publishUrl).not.toBe(first.publishUrl);
  const grant = grantFor(running());
  for (const result of [first, second]) {
    const url = new URL(result.publishUrl);
    const streamid = url.searchParams.get('streamid')!;
    expect(streamid.startsWith(`publish:${grant.path}:`)).toBe(true);
    expect(result.publishUrl).toContain(`?streamid=${streamid}&`);
    expect(attemptOf(config.installationSecret, grant.path, streamid.split(':')[2])).toBe(
      result.publishingAttemptId,
    );
    expect(url.searchParams.get('passphrase')).toBe(grant.publishPassphrase);
  }
  expect([...f.paths]).toEqual([grant.path]);
  expect((await f.lifecycle.worker('mac'))?.readUrl).toBe(grant.readUrl);
  expect(f.calls.filter((call) => call.startsWith('remove:'))).toEqual([]);
});

it('rejects an invalid attempt before touching the relay, including direct callers', async () => {
  const f = fixture();
  await expect(
    f.lifecycle.publish({ ...request, publishingAttemptId: 'bad' }),
  ).rejects.toMatchObject({ code: 'invalid_ingest_identity' });
  expect(f.calls).toEqual([]);
});

it('retains the requested attempt across asynchronous provisioning', async () => {
  const f = fixture();
  const entered = deferred(),
    released = deferred();
  const ensure = f.relay.ensure;
  f.relay.ensure = async (grant) => {
    entered.resolve();
    await released.promise;
    await ensure(grant);
  };
  const original = '11111111-2222-4333-8444-555555555555';
  const mutable = { ...request, publishingAttemptId: original };
  const pending = f.lifecycle.publish(mutable);
  await entered.promise;
  mutable.publishingAttemptId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
  released.resolve();
  const result = await pending;
  expect(result.publishingAttemptId).toBe(original);
  expect(
    attemptOf(
      config.installationSecret,
      grantFor(running()).path,
      new URL(result.publishUrl).searchParams.get('streamid')!.split(':')[2],
    ),
  ).toBe(original);
});

it.each([
  { input: { ...request, deviceId: 'other' }, code: 'capture_not_selected' },
  { input: { ...request, recordingId: 'other' }, code: 'capture_not_selected' },
  { input: { ...request, generation: 2 }, code: 'broadcast_changed' },
  { input: { ...request, gameId: 'other' }, code: 'broadcast_changed' },
])(
  'rejects unauthorized or stale publisher requests before relay side effects: $code',
  async ({ input, code }) => {
    const f = fixture();
    await expect(f.lifecycle.publish(input)).rejects.toMatchObject({
      name: 'RelayLifecycleError',
      code,
      message: code,
    });
    expect(f.calls).toEqual([]);
  },
);

it('distinguishes an absent assignment from an unselected capture', async () => {
  const f = fixture(null);
  await expect(f.lifecycle.publish(request)).rejects.toMatchObject({ code: 'broadcast_changed' });
  expect(await f.lifecycle.worker('mac')).toBeNull();
  expect(f.calls).toEqual([]);
});

it('returns observed source readiness and only the selected worker read capability', async () => {
  const f = fixture();
  expect(await f.lifecycle.worker('other')).toBeNull();
  expect(f.calls).toEqual([]);
  expect(await f.lifecycle.worker('mac')).toEqual({
    gameId: 'match',
    generation: 1,
    readUrl: grantFor(running()).readUrl,
    source: f.source,
  });
  f.source.ready = true;
  f.source.inboundBytes = 100;
  f.source.tracks = ['H264'];
  expect((await f.lifecycle.worker('mac'))?.source).toEqual({
    ready: true,
    inboundBytes: 100,
    tracks: ['H264'],
  });
});

it('a new coordinator removes persisted stale paths while preserving other namespaces', async () => {
  const f = fixture(running(2));
  const stale = grantFor(running()).path;
  const other = deriveIngestGrant(
    'another-installation-secret',
    'match',
    running().selection,
    1,
    'localhost',
    18890,
  ).path;
  f.paths.add(stale).add(other).add('fixture');
  await f.create().reconcile();
  expect([...f.paths].sort()).toEqual([other, 'fixture', grantFor(running(2)).path].sort());
  expect(f.calls.filter((call) => call.startsWith('remove:'))).toEqual([`remove:${stale}`]);
});

it('stopping cleans owned relay paths after a coordinator restart', async () => {
  const f = fixture();
  await f.lifecycle.reconcile();
  f.setDesired(null);
  await f.create().reconcile();
  expect([...f.paths]).toEqual([]);
});

it('a profile change revokes old credentials before provisioning the new selection', async () => {
  const f = fixture();
  await f.lifecycle.reconcile();
  const next = { ...running(2), selection: { ...running().selection, outputId: 'other-output' } };
  f.setDesired(next);
  f.calls.length = 0;
  await f.lifecycle.reconcile();
  expect(f.calls.slice(1)).toEqual([
    `remove:${grantFor(running()).path}`,
    `ensure:${grantFor(next).path}`,
  ]);
  expect([...f.paths]).toEqual([grantFor(next).path]);
});

it('revokes a grant when broadcast stops while provisioning and returns no stale capability', async () => {
  const f = fixture();
  const entered = deferred(),
    released = deferred();
  const ensure = f.relay.ensure;
  f.relay.ensure = async (grant) => {
    entered.resolve();
    await released.promise;
    await ensure(grant);
  };
  const result = f.lifecycle.publish(request);
  const rejection = expect(result).rejects.toMatchObject({ code: 'broadcast_changed' });
  await entered.promise;
  f.setDesired(null);
  released.resolve();
  await rejection;
  expect([...f.paths]).toEqual([]);
});

it('rejects an old generation if a new generation starts during provisioning', async () => {
  const f = fixture();
  const entered = deferred(),
    released = deferred();
  const ensure = f.relay.ensure;
  f.relay.ensure = async (grant) => {
    entered.resolve();
    await released.promise;
    await ensure(grant);
  };
  const result = f.lifecycle.publish(request);
  const rejection = expect(result).rejects.toMatchObject({ code: 'broadcast_changed' });
  await entered.promise;
  f.setDesired(running(2));
  released.resolve();
  await rejection;
  expect(f.paths.has(grantFor(running()).path)).toBe(false);
  await f.lifecycle.reconcile();
  expect([...f.paths]).toEqual([grantFor(running(2)).path]);
});

it('checks latest desired state before deleting a path returned by an earlier list', async () => {
  const f = fixture(running(2));
  const next = running(3);
  f.paths.add(grantFor(next).path);
  const entered = deferred(),
    released = deferred();
  const list = f.relay.list;
  f.relay.list = async (prefix) => {
    const paths = await list(prefix);
    entered.resolve();
    await released.promise;
    return paths;
  };
  const result = f.lifecycle.reconcile();
  const rejection = expect(result).rejects.toMatchObject({ code: 'broadcast_changed' });
  await entered.promise;
  f.setDesired(next);
  released.resolve();
  await rejection;
  expect(f.paths.has(grantFor(next).path)).toBe(true);
  expect(f.calls).not.toContain(`remove:${grantFor(next).path}`);
});

it('rejects a worker result if assignment changes during source observation', async () => {
  const f = fixture();
  const entered = deferred(),
    released = deferred();
  f.relay.status = async () => {
    entered.resolve();
    await released.promise;
    return f.source;
  };
  const result = f.lifecycle.worker('mac');
  const rejection = expect(result).rejects.toMatchObject({ code: 'broadcast_changed' });
  await entered.promise;
  f.setDesired(null);
  released.resolve();
  await rejection;
  expect([...f.paths]).toEqual([]);
});

it.each(['list', 'remove', 'ensure'] as const)(
  'fails closed on %s failure and retries on the next call',
  async (operation) => {
    const f = fixture(running(2));
    const stale = grantFor(running()).path;
    f.paths.add(stale);
    const original = f.relay[operation];
    f.relay[operation] = async () => {
      throw new Error('relay_http_503');
    };
    await expect(f.lifecycle.publish({ ...request, generation: 2 })).rejects.toThrow(
      'relay_http_503',
    );
    expect(f.paths.has(grantFor(running(2)).path)).toBe(false);
    Object.assign(f.relay, { [operation]: original });
    expect((await f.lifecycle.publish({ ...request, generation: 2 })).generation).toBe(2);
    expect([...f.paths]).toEqual([grantFor(running(2)).path]);
  },
);

it('sanitizes unexpected relay failures instead of exposing credential-bearing messages', async () => {
  const f = fixture();
  f.relay.list = async () => {
    throw new Error('srt://private?passphrase=secret');
  };
  await expect(f.lifecycle.publish(request)).rejects.toThrow(/^relay_unavailable$/);
});

it('serializes simultaneous publisher, worker, and reconciliation requests', async () => {
  const f = fixture();
  let active = 0,
    maximum = 0;
  const entered = deferred(),
    released = deferred();
  const list = f.relay.list;
  f.relay.list = async (prefix) => {
    active += 1;
    maximum = Math.max(maximum, active);
    entered.resolve();
    await released.promise;
    const result = await list(prefix);
    active -= 1;
    return result;
  };
  const publish = f.lifecycle.publish(request);
  await entered.promise;
  const worker = f.lifecycle.worker('mac');
  const reconcile = f.lifecycle.reconcile();
  await Promise.resolve();
  released.resolve();
  await Promise.all([publish, worker, reconcile]);
  expect(maximum).toBe(1);
});

it('exports errors with stable safe codes', () => {
  expect(new RelayLifecycleError('capture_not_selected')).toMatchObject({
    message: 'capture_not_selected',
    code: 'capture_not_selected',
  });
});

it('revokes an obsolete grant when provisioning applied but its response failed', async () => {
  const f = fixture();
  f.relay.ensure = async (grant) => {
    f.paths.add(grant.path);
    f.setDesired(null);
    throw new Error('relay_unavailable');
  };
  await expect(f.lifecycle.publish(request)).rejects.toThrow('relay_unavailable');
  expect([...f.paths]).toEqual([]);
});

it('exposes relay failures through the typed lifecycle error boundary', async () => {
  const f = fixture();
  f.relay.list = async () => {
    throw new Error('relay_http_503');
  };
  await expect(f.lifecycle.publish(request)).rejects.toMatchObject({
    name: 'RelayLifecycleError',
    code: 'relay_http_503',
  });
});

it('retries obsolete cleanup after a failed revocation without remembering in-process paths', async () => {
  const f = fixture();
  f.relay.ensure = async (grant) => {
    f.paths.add(grant.path);
    f.setDesired(null);
  };
  const remove = f.relay.remove;
  f.relay.remove = async () => {
    throw new Error('relay_unavailable');
  };
  await expect(f.lifecycle.publish(request)).rejects.toMatchObject({ code: 'relay_unavailable' });
  expect(f.paths.has(grantFor(running()).path)).toBe(true);
  f.relay.remove = remove;
  await f.create().reconcile();
  expect([...f.paths]).toEqual([]);
});

it('does not delete a newly selected path when state changes during an earlier deletion', async () => {
  const f = fixture(running(2));
  const next = running(3);
  f.paths.add(grantFor(running()).path).add(grantFor(next).path);
  const remove = f.relay.remove;
  f.relay.remove = async (path) => {
    await remove(path);
    f.setDesired(next);
  };
  await expect(f.lifecycle.reconcile()).rejects.toMatchObject({ code: 'broadcast_changed' });
  expect(f.paths.has(grantFor(next).path)).toBe(true);
  expect(f.calls).not.toContain(`remove:${grantFor(next).path}`);
});

it('rechecks assignment after the final asynchronous operation resolves', async () => {
  const f = fixture();
  f.relay.status = async () => {
    queueMicrotask(() => queueMicrotask(() => f.setDesired(null)));
    return f.source;
  };
  await expect(f.lifecycle.worker('mac')).rejects.toMatchObject({ code: 'broadcast_changed' });
  expect([...f.paths]).toEqual([]);
});

it('snapshots the publisher endpoint while preserving attestation and worker capability', async () => {
  const f = fixture();
  const endpoint = { host: '::1', port: 19990 };
  const mutable = {
    ...config,
    publishEndpoint: endpoint,
    publishPeerLatencyMs: 400,
    publishPacing: 'relative' as const,
  };
  const lifecycle = new RelayLifecycle(f.relay, mutable, () => running());
  endpoint.host = 'changed.test';
  endpoint.port = 29990;
  mutable.publishEndpoint = { host: 'replaced.test', port: 39990 };
  const publishingAttemptId = '11111111-2222-4333-8444-555555555555';
  const result = await lifecycle.publish({ ...request, publishingAttemptId });
  const url = new URL(result.publishUrl);
  expect(url.host).toBe('[::1]:19990');
  const baseline = grantFor(running());
  const streamid = url.searchParams.get('streamid')!;
  expect(streamid.startsWith(`publish:${baseline.path}:`)).toBe(true);
  expect(attemptOf(config.installationSecret, baseline.path, streamid.split(':')[2])).toBe(
    publishingAttemptId,
  );
  expect(url.searchParams.get('passphrase') === baseline.publishPassphrase).toBe(true);
  expect(url.searchParams.get('pkt_size')).toBe('1316');
  expect(url.searchParams.get('peerlatency')).toBe('400');
  expect(url.searchParams.get('maxbw')).toBe('0');
  expect((await lifecycle.worker('mac'))?.readUrl === baseline.readUrl).toBe(true);
});

it('retires obsolete paths through admission revocation when the relay supports draining', async () => {
  const f = fixture();
  const retired: string[] = [];
  const lifecycle = new RelayLifecycle(
    {
      ...f.relay,
      retire: async (path: string) => {
        retired.push(path);
      },
    },
    config,
    () => null,
  );
  const path = grantFor(running()).path;
  f.paths.add(path);
  await lifecycle.reconcile();
  expect(retired).toEqual([path]);
  expect(f.paths.has(path)).toBe(true);
});
