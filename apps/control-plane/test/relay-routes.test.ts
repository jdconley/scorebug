import { afterEach, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { testConfig, phoneAuth } from './helpers.js';
import type { MatchStore } from '../src/matches-store.js';
import type { IngestGrant } from '../src/ingest.js';

const stores: MatchStore[] = [];
afterEach(() => stores.splice(0).forEach((store) => store.close()));
async function fixture(enabled = true) {
  const config = testConfig();
  const paths = new Map<string, IngestGrant>();
  let failure = false;
  const relay = {
    async list() {
      if (failure) throw new Error('private-network-secret');
      return [...paths.keys()];
    },
    async ensure(grant: IngestGrant) {
      paths.set(grant.path, grant);
    },
    async remove(path: string) {
      paths.delete(path);
    },
    async status() {
      return { ready: false, inboundBytes: 0, tracks: [] };
    },
  };
  const { app, matches, relayLifecycle } = createApp(config, enabled ? { relay } : {});
  stores.push(matches);
  const team = { name: 'Team', shortName: 'T', color: '#123456' };
  matches.create({
    id: 'match',
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const scorer = matches.issueCredential('match', 'scorer', 'score');
  const capture = matches.issueCredential('match', 'phone', 'capture');
  const other = matches.issueCredential('match', 'other', 'capture');
  const issuedAt = new Date().toISOString();
  matches.media.reportRecording('match', 'phone', {
    recordingId: 'archive',
    sequence: 0,
    status: 'recording',
    startedAt: issuedAt,
  });
  matches.media.execute({
    commandId: 'start',
    gameId: 'match',
    expectedGeneration: 0,
    issuedAt,
    operation: {
      type: 'start',
      selection: {
        workerId: 'mac',
        outputId: 'local',
        captureDeviceId: 'phone',
        recordingId: 'archive',
      },
    },
  });
  const request = (path: string, token: string, body?: unknown) =>
    app.request(path, {
      method: body ? 'POST' : 'GET',
      headers: { ...phoneAuth(token), 'content-type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  return {
    config,
    matches,
    relayLifecycle,
    paths,
    scorer,
    capture,
    other,
    request,
    fail: () => {
      failure = true;
    },
  };
}
it('gives publishing access only to the selected capture and current recording generation', async () => {
  const f = await fixture();
  const body = { recordingId: 'archive', generation: 1 };
  expect((await f.request('/v1/matches/match/media/publish', 'bad', body)).status).toBe(401);
  expect((await f.request('/v1/matches/match/media/publish', f.scorer.token, body)).status).toBe(
    403,
  );
  expect((await f.request('/v1/matches/match/media/publish', f.other.token, body)).status).toBe(
    403,
  );
  expect(f.paths.size).toBe(0);
  const response = await f.request('/v1/matches/match/media/publish', f.capture.token, body);
  expect(response.status).toBe(200);
  expect(response.headers.get('cache-control')).toBe('no-store');
  const result = await response.json();
  expect(result).toMatchObject({ gameId: 'match', generation: 1, recordingId: 'archive' });
  expect(result.publishUrl).toMatch(/^srt:/);
  expect(result.readUrl).toBeUndefined();
  expect(f.paths.size).toBe(1);
  expect(
    (
      await f.request('/v1/matches/match/media/publish', f.capture.token, {
        ...body,
        generation: 2,
      })
    ).status,
  ).toBe(409);
  expect(
    (
      await f.request('/v1/matches/match/media/publish', f.capture.token, {
        ...body,
        deviceId: 'spoof',
      })
    ).status,
  ).toBe(400);
});
it('restricts worker connections and keeps connection secrets out of public snapshots', async () => {
  const f = await fixture();
  expect((await f.request('/v1/worker/connection?workerId=mac', f.scorer.token)).status).toBe(401);
  expect((await f.request('/v1/worker/connection', f.config.HOME_TOKEN)).status).toBe(400);
  expect(
    (await (await f.request('/v1/worker/connection?workerId=other', f.config.HOME_TOKEN)).json())
      .connection,
  ).toBeNull();
  const result = await (
    await f.request('/v1/worker/connection?workerId=mac', f.config.HOME_TOKEN)
  ).json();
  expect(result.connection).toMatchObject({
    gameId: 'match',
    generation: 1,
    source: { ready: false },
  });
  expect(result.connection.readUrl).toMatch(/^srt:/);
  expect(result.connection.publishUrl).toBeUndefined();
  const media = await (await f.request('/v1/matches/match/media', f.scorer.token)).text();
  expect(media).not.toContain('passphrase');
  expect(media).not.toContain('srt:');
});

it('issues optional attempt grants only to the selected capture and keeps proof private', async () => {
  const f = await fixture();
  const publishingAttemptId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
  const body = { recordingId: 'archive', generation: 1, publishingAttemptId };
  for (const credential of [f.scorer, f.other])
    expect(
      (await f.request('/v1/matches/match/media/publish', credential.token, body)).status,
    ).toBe(403);
  expect(f.paths.size).toBe(0);
  const response = await f.request('/v1/matches/match/media/publish', f.capture.token, body);
  expect(response.status).toBe(200);
  const result = await response.json();
  expect(result.publishingAttemptId).toBe(publishingAttemptId);
  expect(new URL(result.publishUrl).searchParams.get('streamid')).toMatch(
    new RegExp(`:sbp1=${publishingAttemptId}\\.[0-9a-f]{64}$`),
  );
  for (const endpoint of ['media', 'media/status']) {
    const publicState = await (
      await f.request(`/v1/matches/match/${endpoint}`, f.scorer.token)
    ).text();
    expect(publicState).not.toContain(publishingAttemptId);
    expect(publicState).not.toContain('sbp1=');
    expect(publicState).not.toContain('passphrase');
  }
  expect(
    (
      await f.request('/v1/matches/match/media/publish', f.capture.token, {
        ...body,
        generation: 2,
      })
    ).status,
  ).toBe(409);
});

it.each([
  '',
  'not-uuid',
  'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE',
  'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\n',
  null,
  4,
])('rejects malformed route attempt %j before relay I/O', async (publishingAttemptId) => {
  const f = await fixture();
  expect(
    (
      await f.request('/v1/matches/match/media/publish', f.capture.token, {
        recordingId: 'archive',
        generation: 1,
        publishingAttemptId,
      })
    ).status,
  ).toBe(400);
  expect(f.paths.size).toBe(0);
});
it('reconciles stopped broadcasts without stopping the recording association', async () => {
  const f = await fixture();
  await f.request('/v1/matches/match/media/publish', f.capture.token, {
    recordingId: 'archive',
    generation: 1,
  });
  f.matches.execute({
    commandId: 'end',
    gameId: 'match',
    deviceId: 'scorer',
    expectedRevision: 1,
    scorerEpoch: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'end_match', reason: 'Finished' },
  });
  await f.relayLifecycle!.reconcile();
  expect(f.paths.size).toBe(0);
  expect(f.matches.media.get('match').recordings[0]?.status).toBe('recording');
  expect(
    (
      await f.request('/v1/matches/match/media/publish', f.capture.token, {
        recordingId: 'archive',
        generation: 1,
      })
    ).status,
  ).toBe(409);
  expect(
    (await (await f.request('/v1/worker/connection?workerId=mac', f.config.HOME_TOKEN)).json())
      .connection,
  ).toBeNull();
});
it('reports missing or failed relay without leaking secrets or claiming readiness', async () => {
  const missing = await fixture(false);
  expect(
    (await missing.request('/v1/worker/connection?workerId=mac', missing.config.HOME_TOKEN)).status,
  ).toBe(503);
  const f = await fixture();
  f.fail();
  const response = await f.request('/v1/matches/match/media/publish', f.capture.token, {
    recordingId: 'archive',
    generation: 1,
  });
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ error: 'relay_unavailable' });
});
it.each(['publish', 'worker'] as const)(
  'checks current generation at the %s response boundary',
  async (kind) => {
    const f = await fixture();
    const end = () =>
      f.matches.execute({
        commandId: 'end',
        gameId: 'match',
        deviceId: 'scorer',
        expectedRevision: 1,
        scorerEpoch: 1,
        issuedAt: new Date().toISOString(),
        operation: { type: 'end_match', reason: 'Ended while response was pending' },
      });
    if (kind === 'publish') {
      const original = f.relayLifecycle!.publish.bind(f.relayLifecycle);
      f.relayLifecycle!.publish = async (request) => {
        const result = await original(request);
        end();
        return result;
      };
    } else {
      const original = f.relayLifecycle!.worker.bind(f.relayLifecycle);
      f.relayLifecycle!.worker = async (worker) => {
        const result = await original(worker);
        end();
        return result;
      };
    }
    const response =
      kind === 'publish'
        ? await f.request('/v1/matches/match/media/publish', f.capture.token, {
            recordingId: 'archive',
            generation: 1,
          })
        : await f.request('/v1/worker/connection?workerId=mac', f.config.HOME_TOKEN);
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: 'broadcast_changed' });
  },
);
