import { afterEach, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { testConfig, phoneAuth } from './helpers.js';
import type { MatchStore } from '../src/matches-store.js';

const stores: MatchStore[] = [];

afterEach(() => {
  stores.splice(0).forEach((store) => store.close());
  vi.useRealTimers();
});
async function fixture() {
  const config = testConfig();
  const built = createApp(config);
  const { app, matches } = built;
  stores.push(matches);
  const request = (path: string, token = config.HOME_TOKEN, body?: unknown) =>
    app.request(path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { ...phoneAuth(token), 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
  const team = { name: 'Team', shortName: 'T', color: '#123456' };
  matches.create({
    id: 'match',
    deviceId: 'scorer',
    teams: { home: team, away: team },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const scorer = matches.issueCredential('match', 'scorer', 'score');
  const capture = matches.issueCredential('match', 'phone', 'capture');
  matches.media.reportRecording('match', 'phone', {
    recordingId: 'archive',
    sequence: 0,
    status: 'recording',
    startedAt: new Date().toISOString(),
  });
  matches.media.execute({
    commandId: 'start',
    gameId: 'match',
    expectedGeneration: 0,
    issuedAt: new Date().toISOString(),
    operation: {
      type: 'start',
      selection: {
        workerId: 'mac',
        outputId: 'sink',
        captureDeviceId: 'phone',
        recordingId: 'archive',
      },
    },
  });
  const registration = await request('/v1/worker/sessions', config.HOME_TOKEN, {
    workerId: 'mac',
    runId: 'run',
  });
  const session = registration.status === 200 ? await registration.json() : {};
  const observation = {
    gameId: 'match',
    generation: 1,
    state: 'producing_output',
    reason: null,
    attempt: 1,
    frame: 12,
    outTimeUs: 1000,
    scoreRevision: 1,
  };
  const body = { workerId: 'mac', sessionId: session.sessionId, sequence: 1, observation };
  const report = (value: unknown = body, token = config.HOME_TOKEN) =>
    request('/v1/worker/observations', token, value);
  const status = async () => (await request('/v1/matches/match/media/status', scorer.token)).json();
  return {
    ...built,
    config,
    request,
    scorer,
    capture,
    registration,
    session,
    body,
    report,
    status,
  };
}
it('registers one current session per worker and retires replaced runs permanently', async () => {
  const f = await fixture();
  expect(f.registration.status).toBe(200);
  expect(
    (
      await (
        await f.request('/v1/worker/sessions', f.config.HOME_TOKEN, {
          workerId: 'mac',
          runId: 'run',
        })
      ).json()
    ).sessionId,
  ).toBe(f.session.sessionId);
  expect((await f.report()).status).toBe(200);
  const replaced = await f.request('/v1/worker/sessions', f.config.HOME_TOKEN, {
    workerId: 'mac',
    runId: 'replacement',
  });
  expect(replaced.status).toBe(200);
  expect((await f.status()).status.state).toBe('unknown');
  expect(await (await f.report()).json()).toEqual({ error: 'worker_session_retired' });
  const retired = await f.request('/v1/worker/sessions', f.config.HOME_TOKEN, {
    workerId: 'mac',
    runId: 'run',
  });
  expect(retired.status).toBe(409);
  expect(await retired.json()).toEqual({ error: 'worker_session_retired' });
});
it('uses scoped reads, worker-only writes, strict public telemetry and no durable mutations', async () => {
  const f = await fixture();
  const before = { match: f.matches.get('match'), media: f.matches.media.get('match') };
  for (const token of [f.config.SERVER_SECRET, f.scorer.token, f.capture.token, 'bad']) {
    expect((await f.report(f.body, token)).status).toBe(401);
    expect(
      (await f.request('/v1/worker/sessions', token, { workerId: 'mac', runId: 'other' })).status,
    ).toBe(401);
  }
  for (const token of [f.config.SERVER_SECRET, f.config.HOME_TOKEN, 'bad'])
    expect((await f.request('/v1/matches/match/media/status', token)).status).toBe(401);
  expect((await f.request('/v1/matches/other/media/status', f.scorer.token)).status).toBe(401);
  expect((await f.request('/v1/matches/match/media/status', f.capture.token)).status).toBe(200);
  expect((await f.report()).status).toBe(200);
  const result = await f.status();
  expect(result.status).toMatchObject({
    gameId: 'match',
    generation: 1,
    workerId: 'mac',
    state: 'producing_output',
    observation: f.body.observation,
  });
  expect(Object.keys(result.status.observation).sort()).toEqual(
    Object.keys(f.body.observation).sort(),
  );
  expect(JSON.stringify(result)).not.toContain(f.session.sessionId);
  expect({ match: f.matches.get('match'), media: f.matches.media.get('match') }).toEqual(before);
});
it('rejects unknown sessions, wrong assignment or generation and unbounded/raw values', async () => {
  const f = await fixture();
  const unknown = await f.report({ ...f.body, sessionId: 'unknown' });
  expect(unknown.status).toBe(409);
  expect(await unknown.json()).toEqual({ error: 'worker_session_unknown' });
  for (const patch of [{ gameId: 'other' }, { generation: 2 }]) {
    const response = await f.report({
      ...f.body,
      observation: { ...f.body.observation, ...patch },
    });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: 'broadcast_changed' });
  }
  const otherSession = await (
    await f.request('/v1/worker/sessions', f.config.HOME_TOKEN, { workerId: 'other', runId: 'run' })
  ).json();
  expect(
    await (
      await f.report({ ...f.body, workerId: 'other', sessionId: otherSession.sessionId })
    ).json(),
  ).toEqual({ error: 'broadcast_changed' });
  for (const patch of [
    { frame: 0 },
    { outTimeUs: null },
    { attempt: -1 },
    { frame: 1.5 },
    { outTimeUs: Number.MAX_SAFE_INTEGER + 1 },
    { scoreRevision: -1 },
    { reason: 'raw stderr secret' },
    { stderr: 'secret' },
    { state: 'live' },
    { gameId: '💥' },
  ])
    expect(
      (await f.report({ ...f.body, observation: { ...f.body.observation, ...patch } })).status,
    ).toBe(400);
  expect((await f.report({ ...f.body, rawOutput: 'secret' })).status).toBe(400);
});
it('rejects reordered and changed duplicate reports; permits counter resets only on a newer attempt', async () => {
  const f = await fixture();
  expect((await f.report()).status).toBe(200);
  expect((await f.report()).status).toBe(200);
  for (const value of [
    { ...f.body, sequence: 0 },
    { ...f.body, observation: { ...f.body.observation, frame: 13 } },
    { ...f.body, sequence: 2, observation: { ...f.body.observation, attempt: 0 } },
    { ...f.body, sequence: 2, observation: { ...f.body.observation, frame: 1 } },
    { ...f.body, sequence: 2, observation: { ...f.body.observation, outTimeUs: 1 } },
    { ...f.body, sequence: 2, observation: { ...f.body.observation, scoreRevision: 0 } },
  ]) {
    const response = await f.report(value);
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: 'observation_conflict' });
  }
  expect(
    (
      await f.report({
        ...f.body,
        sequence: 2,
        observation: {
          ...f.body.observation,
          state: 'retrying',
          frame: null,
          outTimeUs: null,
          scoreRevision: null,
        },
      })
    ).status,
  ).toBe(200);
  expect(
    (await f.report({ ...f.body, sequence: 3, observation: { ...f.body.observation, frame: 1 } }))
      .status,
  ).toBe(409);
  expect(
    (
      await f.report({
        ...f.body,
        sequence: 3,
        observation: {
          ...f.body.observation,
          attempt: 2,
          frame: 1,
          outTimeUs: 1,
          scoreRevision: 0,
        },
      })
    ).status,
  ).toBe(200);
});
it('API restart forgets observations and a stop overrides the previous report', async () => {
  const f = await fixture();
  expect((await f.report()).status).toBe(200);
  const restarted = createApp(f.config, { matches: f.matches });
  expect(
    (
      await (
        await restarted.app.request('/v1/matches/match/media/status', {
          headers: phoneAuth(f.scorer.token),
        })
      ).json()
    ).status.state,
  ).toBe('unknown');
  f.matches.media.execute({
    commandId: 'stop',
    gameId: 'match',
    expectedGeneration: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'stop' },
  });
  expect((await f.status()).status).toMatchObject({
    state: 'not_requested',
    observation: null,
    observedAt: null,
    expiresAt: null,
  });
  expect(await (await f.report()).json()).toEqual({ error: 'broadcast_changed' });
  expect(f.matches.media.get('match').recordings[0]?.status).toBe('recording');
});

it('expires at the receipt TTL and duplicate delivery never refreshes freshness', async () => {
  vi.useFakeTimers();
  const f = await fixture();
  expect((await f.status()).status.state).toBe('unknown');
  expect((await f.report()).status).toBe(200);
  const initial = await f.status();
  expect(Date.parse(initial.status.expiresAt) - Date.parse(initial.status.observedAt)).toBe(5000);
  vi.advanceTimersByTime(4999);
  expect((await f.status()).status.state).toBe('producing_output');
  const reversed = Object.fromEntries(Object.entries(f.body).reverse());
  expect((await f.report(reversed)).status).toBe(200);
  expect((await f.status()).status.observedAt).toBe(initial.status.observedAt);
  vi.advanceTimersByTime(1);
  expect((await f.status()).status).toMatchObject({
    state: 'stale',
    observation: f.body.observation,
    observedAt: initial.status.observedAt,
  });
  expect((await f.report({ ...f.body, sequence: 2 })).status).toBe(200);
  expect((await f.status()).status.state).toBe('producing_output');
  expect((await f.status()).status.observedAt).not.toBe(initial.status.observedAt);
});
it('bounds sessions, sequences and required observation fields before accepting telemetry', async () => {
  const f = await fixture();
  for (const value of [
    { workerId: '', runId: 'run' },
    { workerId: 'mac', runId: 'x'.repeat(129) },
    { workerId: 'mac', runId: 'http://secret' },
    { workerId: 'mac', runId: 'run', token: 'secret' },
  ])
    expect((await f.request('/v1/worker/sessions', f.config.HOME_TOKEN, value)).status).toBe(400);
  for (const sequence of [-1, 0.5, Number.MAX_SAFE_INTEGER + 1])
    expect((await f.report({ ...f.body, sequence })).status).toBe(400);
  const { reason: _, ...missingReason } = f.body.observation;
  expect((await f.report({ ...f.body, observation: missingReason })).status).toBe(400);
  const { frame: __, ...missingFrame } = f.body.observation;
  expect((await f.report({ ...f.body, observation: missingFrame })).status).toBe(400);
  expect(
    (
      await f.report({
        ...f.body,
        observation: {
          ...f.body.observation,
          state: 'waiting_source',
          reason: 'source_unavailable',
          attempt: 0,
          frame: null,
          outTimeUs: null,
          scoreRevision: null,
        },
      })
    ).status,
  ).toBe(200);
});

it('acknowledges both initial receipts and exact duplicates explicitly', async () => {
  const f = await fixture();
  expect(await (await f.report()).json()).toMatchObject({ accepted: true });
  expect(await (await f.report()).json()).toMatchObject({ accepted: true });
});

it('measures receipt freshness independently of forward and backward wall-clock changes', async () => {
  vi.useFakeTimers();
  const f = await fixture();
  expect((await f.report()).status).toBe(200);
  const initial = await f.status();
  const receivedWallTime = Date.parse(initial.status.observedAt);
  vi.advanceTimersByTime(1000);
  vi.setSystemTime(receivedWallTime + 60_000);
  const forward = await f.status();
  expect(forward.status.state).toBe('producing_output');
  expect(Date.parse(forward.status.expiresAt) - Date.parse(forward.serverTime)).toBe(4000);
  expect(forward.status.observedAt).toBe(initial.status.observedAt);
  vi.setSystemTime(receivedWallTime - 60_000);
  const backward = await f.status();
  expect(backward.status.state).toBe('producing_output');
  expect(Date.parse(backward.status.expiresAt) - Date.parse(backward.serverTime)).toBe(4000);
  vi.advanceTimersByTime(4000);
  expect((await f.status()).status.state).toBe('stale');
  vi.setSystemTime(receivedWallTime - 120_000);
  const expired = await f.status();
  expect(expired.status.state).toBe('stale');
  expect(Date.parse(expired.status.expiresAt)).toBeLessThanOrEqual(Date.parse(expired.serverTime));
});

it('hides old observations and rejects late reports after replacement of a running generation', async () => {
  const f = await fixture();
  expect((await f.report()).status).toBe(200);
  const outcome = f.matches.media.execute({
    commandId: 'replace',
    gameId: 'match',
    expectedGeneration: 1,
    issuedAt: new Date().toISOString(),
    operation: {
      type: 'start',
      selection: {
        workerId: 'mac',
        outputId: 'other-sink',
        captureDeviceId: 'phone',
        recordingId: 'archive',
      },
    },
  });
  expect(outcome.accepted).toBe(true);
  expect((await f.status()).status).toMatchObject({
    state: 'unknown',
    generation: 2,
    observation: null,
  });
  const late = await f.report();
  expect(late.status).toBe(409);
  expect(await late.json()).toEqual({ error: 'broadcast_changed' });
  expect(
    (
      await f.report({
        ...f.body,
        sequence: 2,
        observation: { ...f.body.observation, generation: 2, attempt: 2 },
      })
    ).status,
  ).toBe(200);
  expect((await f.status()).status).toMatchObject({ state: 'producing_output', generation: 2 });
});

it('summarizes the broadcast as idle, starting, live, reconnecting or error', async () => {
  vi.useFakeTimers();
  const f = await fixture();
  const phase = async () => (await f.status()).status.phase;
  expect(await phase()).toBe('starting');
  let sequence = 0;
  const send = (patch: Record<string, unknown>) =>
    f.report({ ...f.body, sequence: ++sequence, observation: { ...f.body.observation, ...patch } });
  const waiting = {
    state: 'waiting_source',
    reason: 'source_unavailable',
    frame: null,
    outTimeUs: null,
  };
  expect((await send({ ...waiting, attempt: 0 })).status).toBe(200);
  expect(await phase()).toBe('starting');
  expect((await send({ state: 'starting', frame: null, outTimeUs: null })).status).toBe(200);
  expect(await phase()).toBe('starting');
  expect((await send({})).status).toBe(200);
  expect(await phase()).toBe('live');
  // The phone dropped: the same generation was live, so this is a reconnect.
  expect((await send({ ...waiting, attempt: 2 })).status).toBe(200);
  expect(await phase()).toBe('reconnecting');
  expect((await send({ state: 'retrying', reason: 'process_exited', attempt: 2 })).status).toBe(
    200,
  );
  expect(await phase()).toBe('reconnecting');
  expect((await send({ state: 'failed', reason: 'control_timeout', attempt: 2 })).status).toBe(200);
  expect(await phase()).toBe('error');
  expect((await send({ attempt: 3 })).status).toBe(200);
  expect(await phase()).toBe('live');
  vi.advanceTimersByTime(5000);
  expect((await f.status()).status).toMatchObject({ state: 'stale', phase: 'error' });
  f.matches.media.execute({
    commandId: 'stop',
    gameId: 'match',
    expectedGeneration: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'stop' },
  });
  expect((await f.status()).status).toMatchObject({ state: 'not_requested', phase: 'idle' });
});

it('reports the output the worker is encoding, outside the detailed observation', async () => {
  const f = await fixture();
  expect((await f.status()).status.output).toBeNull();
  const output = { width: 1920, height: 1080, fps: 30, bitrateKbps: 6000 };
  expect(
    (await f.report({ ...f.body, observation: { ...f.body.observation, output } })).status,
  ).toBe(200);
  const { status } = await f.status();
  expect(status.output).toEqual(output);
  expect(status.observation).toEqual(f.body.observation);
  for (const bad of [
    { ...output, width: 1 },
    { ...output, bitrateKbps: 1.5 },
    { ...output, codec: 'h264' },
    { width: 1920, height: 1080 },
  ])
    expect(
      (
        await f.report({
          ...f.body,
          sequence: 2,
          observation: { ...f.body.observation, output: bad },
        })
      ).status,
    ).toBe(400);
});
