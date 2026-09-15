import { afterEach, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import type { WorkerObservation } from '@scorebug/protocol';
import { createApp } from '../src/app.js';
import { testConfig, phoneAuth } from './helpers.js';
import type { MatchStore } from '../src/matches-store.js';

const stores: MatchStore[] = [];
it.each(['decoded-video-v1.json', 'decoded-video-clock-v1.json'])(
  'accepts the exact shared Swift observations in %s',
  async (fixtureName) => {
    const examples = JSON.parse(
      readFileSync(
        new URL(`../../../packages/protocol/fixtures/${fixtureName}`, import.meta.url),
        'utf8',
      ),
    );
    for (const example of Object.values(examples) as {
      status: { observation: WorkerObservation };
    }[]) {
      const f = await fixture();
      const observation = example.status.observation;
      expect((await f.report({ ...f.body, observation })).status).toBe(200);
      const actual = (await f.status()).status.observation;
      if (observation.decodedVideo?.completed) {
        expect(actual.decodedVideo.completed.ageMs).toBeGreaterThanOrEqual(
          observation.decodedVideo.completed.ageMs,
        );
        actual.decodedVideo.completed.ageMs = observation.decodedVideo.completed.ageMs;
      }
      expect(actual).toEqual(observation);
    }
  },
);
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
  for (const token of [f.config.PHONE_TOKEN, f.scorer.token, f.capture.token, 'bad']) {
    expect((await f.report(f.body, token)).status).toBe(401);
    expect(
      (await f.request('/v1/worker/sessions', token, { workerId: 'mac', runId: 'other' })).status,
    ).toBe(401);
  }
  for (const token of [f.config.PHONE_TOKEN, f.config.HOME_TOKEN, 'bad'])
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

const decoded = () => ({
  completed: {
    sequence: 1,
    durationMs: 5000,
    ageMs: 100,
    firstPTS: 0,
    lastPTS: 447000,
    freshFrames: 150,
    duplicateFrames: 0,
    reorderedFrames: 0,
    valid: true,
  },
  invalidReason: null,
  ended: false,
});

it('carries decoded ingress windows and ages them without changing stored evidence or duplicate freshness', async () => {
  vi.useFakeTimers();
  const f = await fixture();
  const body = { ...f.body, observation: { ...f.body.observation, decodedVideo: decoded() } };
  expect((await f.report(body)).status).toBe(200);
  expect((await f.status()).status.observation.decodedVideo.completed.ageMs).toBe(100);
  vi.advanceTimersByTime(1200);
  vi.setSystemTime(Date.now() - 60_000);
  const read = await f.status();
  expect(read.status.observation.decodedVideo.completed.ageMs).toBe(1300);
  read.status.observation.decodedVideo.completed.freshFrames = 999;
  expect((await f.report(body)).status).toBe(200);
  vi.advanceTimersByTime(800);
  const next = await f.status();
  expect(next.status.observation.decodedVideo.completed).toMatchObject({
    ageMs: 2100,
    freshFrames: 150,
  });
});

it('rejects malformed decoded windows and raw data while retaining legacy and unknown observations', async () => {
  const f = await fixture();
  const malformed = [
    { ...decoded(), raw: 'secret' },
    { ...decoded(), invalidReason: 'secret' },
    { ...decoded(), ended: 'false' },
    ...[
      { sequence: 0 },
      { durationMs: 4000 },
      { ageMs: -1 },
      { ageMs: Number.MAX_SAFE_INTEGER + 1 },
      { firstPTS: 1.5 },
      { lastPTS: Number.MAX_SAFE_INTEGER + 1 },
      { freshFrames: -1 },
      { duplicateFrames: 0.1 },
      { reorderedFrames: Number.MAX_SAFE_INTEGER + 1 },
      { firstPTS: null },
      { lastPTS: -1 },
      { freshFrames: 0 },
      { valid: false },
      { raw: 'secret' },
    ].map((patch) => ({ ...decoded(), completed: { ...decoded().completed, ...patch } })),
  ];
  for (const decodedVideo of malformed) {
    expect(
      (await f.report({ ...f.body, observation: { ...f.body.observation, decodedVideo } })).status,
    ).toBe(400);
  }
  expect((await f.report()).status).toBe(200);
  expect(
    (
      await f.report({
        ...f.body,
        sequence: 2,
        observation: {
          ...f.body.observation,
          decodedVideo: { completed: null, invalidReason: null, ended: false },
        },
      })
    ).status,
  ).toBe(200);
  expect(
    (
      await f.report({
        ...f.body,
        sequence: 3,
        observation: {
          ...f.body.observation,
          decodedVideo: { completed: null, invalidReason: 'numeric', ended: false },
        },
      })
    ).status,
  ).toBe(200);
});

it('rejects changed completed windows, regressions and recovery of terminal decoder evidence within one attempt', async () => {
  const f = await fixture();
  const report = (decodedVideo: unknown, sequence = 2, attempt = 1) =>
    f.report({
      ...f.body,
      sequence,
      observation: { ...f.body.observation, attempt, decodedVideo },
    });
  const first = decoded();
  expect((await report(first, 1)).status).toBe(200);
  for (const patch of [
    { freshFrames: 149 },
    { firstPTS: 1 },
    { lastPTS: 448000 },
    { ageMs: 99 },
    { duplicateFrames: 1 },
    { reorderedFrames: 1 },
  ]) {
    expect((await report({ ...first, completed: { ...first.completed, ...patch } })).status).toBe(
      409,
    );
  }
  const second = {
    ...first,
    completed: { ...first.completed, sequence: 2, ageMs: 0, firstPTS: 450000, lastPTS: 897000 },
  };
  expect((await report(second)).status).toBe(200);
  expect((await report(first, 3)).status).toBe(409);
  // An absent optional field cannot erase the anti-regression watermark.
  expect((await f.report({ ...f.body, sequence: 3 })).status).toBe(200);
  expect((await report(first, 4)).status).toBe(409);
  const failed = {
    ...second,
    invalidReason: 'framing',
    ended: true,
    completed: { ...second.completed, valid: false, ageMs: 100 },
  };
  expect((await report(failed, 4)).status).toBe(200);
  expect((await report(second, 5)).status).toBe(409);
  // New worker attempt gets a new collector and can restart all decoder counters.
  expect((await report(first, 5, 2)).status).toBe(200);
});

it('cannot make the same decoder window younger with newer report sequence numbers', async () => {
  vi.useFakeTimers();
  const f = await fixture();
  const body = { ...f.body, observation: { ...f.body.observation, decodedVideo: decoded() } };
  expect((await f.report(body)).status).toBe(200);
  vi.advanceTimersByTime(1200);
  expect((await f.report({ ...body, sequence: 2 })).status).toBe(200);
  expect((await f.status()).status.observation.decodedVideo.completed.ageMs).toBe(1300);
  // Dropping the optional field must not reset the known window age either.
  expect((await f.report({ ...f.body, sequence: 3 })).status).toBe(200);
  vi.advanceTimersByTime(800);
  expect((await f.report({ ...body, sequence: 4 })).status).toBe(200);
  expect((await f.status()).status.observation.decodedVideo.completed.ageMs).toBe(2100);
});

it('preserves nested observations against mutation on both input and direct reads', async () => {
  const f = await fixture();
  const body = {
    ...f.body,
    observation: {
      ...f.body.observation,
      state: 'producing_output' as const,
      decodedVideo: decoded(),
    },
  };
  f.observations.report(body);
  body.observation.decodedVideo.completed.freshFrames = 999;
  const first = f.observations.status('match');
  expect(first.status.observation?.decodedVideo?.completed?.freshFrames).toBe(150);
  first.status.observation!.decodedVideo!.completed!.freshFrames = 999;
  expect(
    f.observations.status('match').status.observation?.decodedVideo?.completed?.freshFrames,
  ).toBe(150);
});

it('retains fresh PTS range across zero-progress windows and rejects a later source rewind', async () => {
  const f = await fixture();
  const report = (video: unknown, sequence: number) =>
    f.report({ ...f.body, sequence, observation: { ...f.body.observation, decodedVideo: video } });
  expect((await report(decoded(), 1)).status).toBe(200);
  const empty = {
    ...decoded(),
    completed: {
      ...decoded().completed,
      sequence: 2,
      ageMs: 0,
      firstPTS: null,
      lastPTS: null,
      freshFrames: 0,
    },
  };
  expect((await report(empty, 2)).status).toBe(200);
  const rewind = { ...decoded(), completed: { ...decoded().completed, sequence: 3 } };
  expect((await report(rewind, 3)).status).toBe(409);
  const resumed = {
    ...decoded(),
    completed: { ...decoded().completed, sequence: 3, firstPTS: 900000, lastPTS: 1347000 },
  };
  expect((await report(resumed, 3)).status).toBe(200);
});

const transportClock = 'mpegts-pts-90k-v1';
it('advertises the decoded transport clock on initial and idempotent session registration', async () => {
  const f = await fixture();
  expect(f.session.decodedVideoClock).toBe(transportClock);
  const repeat = await (
    await f.request('/v1/worker/sessions', f.config.HOME_TOKEN, {
      workerId: 'mac',
      runId: 'run',
    })
  ).json();
  expect(repeat).toMatchObject({
    sessionId: f.session.sessionId,
    decodedVideoClock: transportClock,
  });
});

it.each([undefined, transportClock, 'future-clock-v2', 'a', 'a'.repeat(64)])(
  'roundtrips optional bounded decoded clock %s',
  async (clock) => {
    const f = await fixture();
    const decodedVideo = { ...decoded(), ...(clock === undefined ? {} : { clock }) };
    expect(
      (await f.report({ ...f.body, observation: { ...f.body.observation, decodedVideo } })).status,
    ).toBe(200);
    const actual = (await f.status()).status.observation.decodedVideo;
    expect(actual.clock).toBe(clock);
    if (clock === undefined) expect(actual).not.toHaveProperty('clock');
  },
);

it.each([
  null,
  42,
  true,
  {},
  [],
  '',
  'A',
  '9clock',
  '-clock',
  'bad_clock',
  'bad clock',
  'clock.v1',
  'a'.repeat(65),
])('rejects malformed decoded clock %j without changing accepted state', async (clock) => {
  vi.useFakeTimers();
  const f = await fixture();
  expect((await f.report()).status).toBe(200);
  const before = await f.status();
  expect(
    (
      await f.report({
        ...f.body,
        sequence: 2,
        observation: { ...f.body.observation, decodedVideo: { ...decoded(), clock } },
      })
    ).status,
  ).toBe(400);
  expect(await f.status()).toEqual(before);
  expect((await f.report({ ...f.body, sequence: 2 })).status).toBe(200);
});

it.each([undefined, transportClock, 'future-clock-v2'])(
  'freezes the first decoded snapshot clock %s across omissions and retries, resetting on attempts and sessions',
  async (clock) => {
    vi.useFakeTimers();
    const f = await fixture();
    // Even an incomplete first snapshot fixes the attempt clock.
    const decodedVideo = {
      completed: null,
      invalidReason: null,
      ended: false,
      ...(clock === undefined ? {} : { clock }),
    };
    const body = {
      ...f.body,
      timingToken: f.session.timingToken,
      observation: { ...f.body.observation, decodedVideo },
    };
    expect((await f.report(body)).status).toBe(200);
    expect((await f.report(body)).status).toBe(200);
    expect((await f.report({ ...f.body, sequence: 2 })).status).toBe(200);
    const before = await f.status();
    const nextClock = clock === transportClock ? undefined : transportClock;
    const changed = { ...decoded(), ...(nextClock === undefined ? {} : { clock: nextClock }) };
    const conflict = {
      ...f.body,
      timingToken: f.session.timingToken,
      sequence: 3,
      observation: { ...f.body.observation, decodedVideo: changed },
    };
    expect((await f.report(conflict)).status).toBe(409);
    expect(await f.status()).toEqual(before);
    // Same sequence remains available after rejection; the omission retained the original guard.
    const sameClock = { ...decoded(), ...(clock === undefined ? {} : { clock }) };
    expect(
      (
        await f.report({
          ...conflict,
          observation: { ...f.body.observation, decodedVideo: sameClock },
        })
      ).status,
    ).toBe(200);
    expect(
      (
        await f.report({
          ...conflict,
          sequence: 4,
          observation: { ...conflict.observation, attempt: 2 },
        })
      ).status,
    ).toBe(200);
    const replacement = await (
      await f.request('/v1/worker/sessions', f.config.HOME_TOKEN, {
        workerId: 'mac',
        runId: 'new-run',
      })
    ).json();
    expect((await f.report({ ...body, sessionId: replacement.sessionId })).status).toBe(200);
  },
);
