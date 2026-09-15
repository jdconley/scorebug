import { afterEach, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { createApp } from '../src/app.js';
import { WorkerObservations } from '../src/worker-observations.js';
import { deriveIngestGrant } from '../src/ingest.js';
import { publishAttemptQuery } from '../src/publishing-attempt.js';
import { testConfig } from './helpers.js';

const readId = '11111111-1111-4111-8111-111111111111';
const nextId = '22222222-2222-4222-8222-222222222222';
const readerId = '33333333-3333-4333-8333-333333333333';
const publisherId = '44444444-4444-4444-8444-444444444444';
const publishingAttemptId = '55555555-5555-4555-8555-555555555555';
const clock = { convention: 'mpegts-ingress-origin-90k-v1', originPTS: '9000' } as const;
const publication = { readerId, publisherId, publishingAttemptId, clock };
const closes: (() => void)[] = [];
afterEach(() => closes.splice(0).forEach((close) => close()));
function fixture() {
  const config = testConfig();
  const { matches } = createApp(config);
  closes.push(() => matches.close());
  const team = { name: 'Team', shortName: 'T', color: '#123456' };
  matches.create({
    id: 'match',
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const scorer = matches.issueCredential('match', 'scorer', 'score');
  matches.issueCredential('match', 'phone', 'capture');
  matches.media.reportRecording('match', 'phone', {
    recordingId: 'archive',
    sequence: 0,
    status: 'recording',
    startedAt: new Date().toISOString(),
  });
  const selection = {
    workerId: 'mac',
    outputId: 'sink',
    captureDeviceId: 'phone',
    recordingId: 'archive',
  };
  const start = (generation: number) =>
    matches.media.execute({
      commandId: `start-${generation}`,
      gameId: 'match',
      expectedGeneration: generation,
      issuedAt: new Date().toISOString(),
      operation: { type: 'start', selection },
    });
  start(0);
  let time = 0;
  const observations = new WorkerObservations(
    matches.media,
    () => 1789510000000 + time,
    () => time,
  );
  const session = observations.register({ workerId: 'mac', runId: 'run' });
  const grant = deriveIngestGrant(
    config.PHONE_TOKEN,
    'match',
    selection,
    1,
    config.INGEST_HOST,
    config.INGEST_PORT,
  );
  const queried: unknown[] = [];
  let resolve: () => Promise<unknown> = async () => ({
    readerId,
    publisherId,
    publisherQuery: publishAttemptQuery(config.PHONE_TOKEN, grant.path, publishingAttemptId),
    clock,
  });
  const mutations: string[] = [];
  const relay = {
    ensure: async () => {
      mutations.push('ensure');
    },
    remove: async () => {
      mutations.push('remove');
    },
    list: async () => [],
    status: async () => ({ ready: true, inboundBytes: 0, tracks: [] }),
    publication: async (...args: unknown[]) => {
      queried.push(args);
      return resolve();
    },
  };
  const { app } = createApp(config, { matches, observations, relay: relay as any });
  const body = {
    workerId: 'mac',
    sessionId: session.sessionId,
    sequence: 1,
    pipelineReadId: readId,
    observation: {
      gameId: 'match',
      generation: 1,
      state: 'producing_output' as const,
      reason: null,
      attempt: 1,
      frame: 30,
      outTimeUs: 1000000,
      scoreRevision: 1,
    },
  };
  const report = (value: unknown = body) =>
    app.request('/v1/worker/observations', {
      method: 'POST',
      headers: { authorization: `Bearer ${config.HOME_TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify(value),
    });
  const status = async () => {
    const response = await app.request('/v1/matches/match/media/status', {
      headers: { authorization: `Bearer ${scorer.token}` },
    });
    expect(response.status).toBe(200);
    return response.json();
  };
  const stop = () =>
    matches.media.execute({
      commandId: 'stop',
      gameId: 'match',
      expectedGeneration: 1,
      issuedAt: new Date().toISOString(),
      operation: { type: 'stop' },
    });
  return {
    config,
    start,
    selection,
    matches,
    observations,
    session,
    grant,
    queried,
    mutations,
    body,
    report,
    status,
    stop,
    resolve: (value: typeof resolve) => {
      resolve = value;
    },
    time: (value: number) => {
      time = value;
    },
  };
}

it('advertises private read identity and exposes only verified public association', async () => {
  const f = fixture();
  expect(f.session.pipelineReadIdentity).toBe('srt-read-query-v1');
  expect((await f.report()).status).toBe(200);
  const result = await f.status();
  expect(result.status.publication).toEqual(publication);
  expect(f.queried).toEqual([[f.grant.path, readId]]);
  expect(f.mutations).toEqual([]);
  expect(result.status.observation).toEqual(f.body.observation);
  const encoded = JSON.stringify(result);
  for (const secret of [
    readId,
    f.session.sessionId,
    f.session.timingToken!,
    'sbw1=',
    'sbp1=',
    'publisherQuery',
  ])
    expect(encoded).not.toContain(secret);
});
it('keeps an established read ID immutable across omission in the same attempt', async () => {
  const f = fixture();
  expect((await f.report()).status).toBe(200);
  const { pipelineReadId: _, ...omitted } = f.body;
  expect((await f.report({ ...omitted, sequence: 2 })).status).toBe(200);
  expect((await f.status()).status.publication).toBeUndefined();
  expect((await f.report({ ...f.body, sequence: 3, pipelineReadId: nextId })).status).toBe(409);
  expect((await f.report({ ...f.body, sequence: 3 })).status).toBe(200);
  expect((await f.status()).status.publication).toEqual(publication);
});
it('rejects reuse by later attempts but accepts a fresh read ID', async () => {
  const f = fixture();
  expect((await f.report()).status).toBe(200);
  const retry = { ...f.body, sequence: 2, observation: { ...f.body.observation, attempt: 2 } };
  expect((await f.report(retry)).status).toBe(409);
  expect((await f.report({ ...retry, pipelineReadId: nextId })).status).toBe(200);
  expect(
    (await f.report({ ...retry, sequence: 3, observation: { ...retry.observation, attempt: 3 } }))
      .status,
  ).toBe(409);
});
it.each([readId.toUpperCase().replace('11111111', 'ABCDEFAB'), readId + '\n', '', null, 12])(
  'rejects malformed private ID %j',
  async (pipelineReadId) => {
    const f = fixture();
    expect((await f.report({ ...f.body, pipelineReadId })).status).toBe(400);
  },
);
it('rejects worker-supplied public publication metadata', async () => {
  const f = fixture();
  expect((await f.report({ ...f.body, publication })).status).toBe(400);
  expect(
    (await f.report({ ...f.body, observation: { ...f.body.observation, publication } })).status,
  ).toBe(400);
});
it.each(['missing', 'wrong-secret', 'wrong-path', 'unavailable'] as const)(
  'preserves ordinary status with %s publication evidence',
  async (mode) => {
    const f = fixture();
    expect((await f.report()).status).toBe(200);
    f.resolve(async () => {
      if (mode === 'unavailable') throw new Error('private credential');
      if (mode === 'missing') return undefined;
      return {
        readerId,
        publisherId,
        clock,
        publisherQuery: publishAttemptQuery(
          mode === 'wrong-secret' ? 'different-installation-secret' : f.config.PHONE_TOKEN,
          mode === 'wrong-path'
            ? 'scorebug-' + 'a'.repeat(16) + '-' + 'b'.repeat(32)
            : f.grant.path,
          publishingAttemptId,
        ),
      };
    });
    const value = await f.status();
    expect(value.status.state).toBe('producing_output');
    expect(value.status.publication).toBeUndefined();
    expect(JSON.stringify(value)).not.toContain('private credential');
  },
);
it.each(['new-session', 'new-attempt', 'stop', 'stale', 'omitted', 'stopping'] as const)(
  'drops association when %s happens during lookup',
  async (mode) => {
    const f = fixture();
    expect((await f.report()).status).toBe(200);
    f.resolve(async () => {
      if (mode === 'new-session')
        f.observations.register({ workerId: 'mac', runId: 'replacement' });
      if (mode === 'new-attempt')
        expect(
          (
            await f.report({
              ...f.body,
              sequence: 2,
              pipelineReadId: nextId,
              observation: { ...f.body.observation, attempt: 2 },
            })
          ).status,
        ).toBe(200);
      if (mode === 'stop') f.stop();
      if (mode === 'stale') f.time(5000);
      if (mode === 'omitted') {
        const { pipelineReadId: _, ...body } = f.body;
        expect((await f.report({ ...body, sequence: 2 })).status).toBe(200);
      }
      if (mode === 'stopping')
        expect(
          (
            await f.report({
              ...f.body,
              sequence: 2,
              observation: { ...f.body.observation, state: 'stopping' },
            })
          ).status,
        ).toBe(200);
      return {
        readerId,
        publisherId,
        clock,
        publisherQuery: publishAttemptQuery(
          f.config.PHONE_TOKEN,
          f.grant.path,
          publishingAttemptId,
        ),
      };
    });
    expect((await f.status()).status.publication).toBeUndefined();
    expect(f.mutations).toEqual([]);
  },
);
it('retains association across a newer report for the same pipeline', async () => {
  const f = fixture();
  expect((await f.report()).status).toBe(200);
  f.resolve(async () => {
    expect(
      (
        await f.report({
          ...f.body,
          sequence: 2,
          observation: { ...f.body.observation, frame: 60 },
        })
      ).status,
    ).toBe(200);
    return {
      readerId,
      publisherId,
      clock,
      publisherQuery: publishAttemptQuery(f.config.PHONE_TOKEN, f.grant.path, publishingAttemptId),
    };
  });
  const result = await f.status();
  expect(result.status.observation.frame).toBe(60);
  expect(result.status.publication).toEqual(publication);
});
it.each(['starting', 'retrying', 'failed', 'closed'] as const)(
  'only resolves live pipeline states: %s',
  async (state) => {
    const f = fixture();
    expect(
      (await f.report({ ...f.body, observation: { ...f.body.observation, state } })).status,
    ).toBe(200);
    expect((await f.status()).status.publication).toEqual(
      state === 'starting' ? publication : undefined,
    );
    expect(f.queried.length).toBe(state === 'starting' ? 1 : 0);
  },
);
it('rejects an old read ID first disclosed after an omitted report in a later attempt', async () => {
  const f = fixture();
  expect((await f.report()).status).toBe(200);
  const { pipelineReadId: _, ...withoutId } = f.body;
  const next = { ...withoutId, sequence: 2, observation: { ...withoutId.observation, attempt: 2 } };
  expect((await f.report(next)).status).toBe(200);
  expect((await f.report({ ...next, sequence: 3, pipelineReadId: readId })).status).toBe(409);
});
it('can bind a still-running read to a new reporting epoch after API-session replacement', async () => {
  const f = fixture();
  expect((await f.report()).status).toBe(200);
  const before = await f.status();
  const replacement = f.observations.register({ workerId: 'mac', runId: 'replacement' });
  expect((await f.report()).status).toBe(409);
  expect((await f.report({ ...f.body, sessionId: replacement.sessionId })).status).toBe(200);
  const after = await f.status();
  expect(after.status.workerEpoch).not.toBe(before.status.workerEpoch);
  expect(after.status.publication).toEqual(before.status.publication);
});

it.each(['current', 'starting', 'zeroOrigin', 'maximumOrigin'])(
  'returns shared native publication fixture %s through authenticated HTTP',
  async (name) => {
    const examples = JSON.parse(
      readFileSync(
        new URL('../../../packages/protocol/fixtures/worker-publication-v1.json', import.meta.url),
        'utf8',
      ),
    );
    const expected = examples[name];
    const f = fixture();
    f.start(1);
    const now = Date.parse(expected.status.observedAt) - 1789510000000;
    f.time(now);
    const grant = deriveIngestGrant(
      f.config.PHONE_TOKEN,
      'match',
      f.selection,
      2,
      f.config.INGEST_HOST,
      f.config.INGEST_PORT,
    );
    f.resolve(async () => ({
      readerId: expected.status.publication.readerId,
      publisherId: expected.status.publication.publisherId,
      clock: expected.status.publication.clock,
      publisherQuery: publishAttemptQuery(
        f.config.PHONE_TOKEN,
        grant.path,
        expected.status.publication.publishingAttemptId,
      ),
    }));
    expect((await f.report({ ...f.body, observation: expected.status.observation })).status).toBe(
      200,
    );
    f.time(now + 1000);
    const actual = await f.status();
    expect(actual).toEqual({
      ...expected,
      status: { ...expected.status, workerEpoch: actual.status.workerEpoch },
    });
  },
);
