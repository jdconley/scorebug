import { afterEach, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import type { WorkerObservationRequest } from '@scorebug/protocol';
import { createApp } from '../src/app.js';
import { WorkerObservations } from '../src/worker-observations.js';
import type { MatchStore } from '../src/matches-store.js';
import { testConfig } from './helpers.js';

const stores: MatchStore[] = [];
afterEach(() => stores.splice(0).forEach((store) => store.close()));

async function fixture(initial = 100) {
  const config = testConfig();
  const { matches } = createApp(config);
  stores.push(matches);
  let monotonic = initial;
  let wall = Date.parse('2026-09-14T04:00:00.000Z');
  let throws = false;
  let samples = 0;
  const clock = () => {
    samples++;
    if (throws) throw new Error('clock unavailable');
    return monotonic;
  };
  const observations = new WorkerObservations(matches.media, () => wall, clock);
  const { app } = createApp(config, { matches, observations });
  const team = { name: 'Team', shortName: 'T', color: '#123456' };
  const setupGame = (gameId: string) => {
    matches.create({
      id: gameId,
      deviceId: 'scorer',
      teams: { home: team, away: team },
      rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
    });
    const scorer = matches.issueCredential(gameId, 'scorer', 'score');
    matches.issueCredential(gameId, 'phone', 'capture');
    matches.media.reportRecording(gameId, 'phone', {
      recordingId: 'archive',
      sequence: 0,
      status: 'recording',
      startedAt: new Date(wall).toISOString(),
    });
    return scorer;
  };
  const scorer = setupGame('match');
  const start = (gameId = 'match', expectedGeneration = 0, outputId = 'sink') => {
    const outcome = matches.media.execute({
      commandId: `start-${gameId}-${expectedGeneration}`,
      gameId,
      expectedGeneration,
      issuedAt: new Date().toISOString(),
      operation: {
        type: 'start',
        selection: { workerId: 'mac', outputId, captureDeviceId: 'phone', recordingId: 'archive' },
      },
    });
    expect(outcome.accepted).toBe(true);
  };
  start();
  const post = (path: string, body: unknown) =>
    app.request(`/v1/worker/${path}`, {
      method: 'POST',
      headers: { authorization: `Bearer ${config.HOME_TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
  const register = async (runId = 'run') => {
    const response = await post('sessions', { workerId: 'mac', runId });
    expect(response.status).toBe(200);
    return response.json();
  };
  const session = await register();
  const body: WorkerObservationRequest = {
    workerId: 'mac',
    sessionId: session.sessionId,
    sequence: 1,
    observation: {
      gameId: 'match',
      generation: 1,
      state: 'producing_output',
      reason: null,
      attempt: 1,
      frame: 12,
      outTimeUs: 1000,
      scoreRevision: 1,
      decodedVideo: {
        completed: {
          sequence: 1,
          durationMs: 5000,
          ageMs: 50,
          firstPTS: 0,
          lastPTS: 447000,
          freshFrames: 150,
          duplicateFrames: 0,
          reorderedFrames: 0,
          valid: true,
        },
        invalidReason: null,
        ended: false,
      },
    },
  };
  const report = (value: unknown = body) => post('observations', value);
  const accept = async (value: unknown = body) => {
    const response = await report(value);
    expect(response.status).toBe(200);
    return response.json();
  };
  const status = async () => {
    const response = await app.request('/v1/matches/match/media/status', {
      headers: { authorization: `Bearer ${scorer.token}` },
    });
    expect(response.status).toBe(200);
    return response.json();
  };
  return {
    matches,
    app,
    post,
    observations,
    body,
    session,
    register,
    report,
    accept,
    status,
    setupGame,
    start,
    time: (value: number) => {
      monotonic = value;
    },
    wall: (value: number) => {
      wall = value;
    },
    throwClock: () => {
      throws = true;
    },
    restoreClock: () => {
      throws = false;
    },
    samples: () => samples,
  };
}

it('bounds snapshot age by token issuance, full transit, and status residence through HTTP', async () => {
  const f = await fixture();
  expect(f.session.timingToken).toMatch(/^[A-Za-z0-9_-]{1,128}$/);
  f.time(400);
  const ack = await f.accept({ ...f.body, timingToken: f.session.timingToken });
  expect(ack).toMatchObject({
    accepted: true,
    serverTime: expect.any(String),
    timingToken: expect.any(String),
  });
  expect(ack.timingToken).not.toBe(f.session.timingToken);
  f.time(600);
  const result = await f.status();
  const canonical = JSON.parse(
    readFileSync(
      new URL('../../../packages/protocol/fixtures/worker-report-age-v1.json', import.meta.url),
      'utf8',
    ),
  );
  expect(result).toEqual({
    ...canonical,
    status: {
      ...canonical.status,
      workerEpoch: expect.stringMatching(/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/),
    },
  });
  expect(result.status.decodedVideoAgeUpperBoundMs).toBe(550);
  expect(result.status.observation.decodedVideo.completed.ageMs).toBe(250);
  expect(JSON.stringify(result)).not.toContain('timingToken');
  expect(JSON.stringify(result)).not.toContain(f.session.sessionId);
  expect(f.samples()).toBe(3);
});

it('keeps token issue times on registration retries and lost observation acknowledgements', async () => {
  const f = await fixture();
  const token = f.session.timingToken;
  f.time(200);
  expect((await f.register()).timingToken).toBe(token);
  f.time(400);
  const ack = await f.accept({ ...f.body, timingToken: token });
  for (const [sequence, time] of [
    [2, 600],
    [3, 800],
  ]) {
    f.time(time!);
    expect((await f.accept({ ...f.body, sequence, timingToken: token })).timingToken).toBe(
      ack.timingToken,
    );
    expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(time! - 50);
  }
  f.time(1000);
  const rotated = await f.accept({ ...f.body, sequence: 4, timingToken: ack.timingToken });
  expect(rotated.timingToken).not.toBe(ack.timingToken);
  expect(rotated.timingToken).not.toBe(token);
  // The twice-old token was evicted and cannot prove age for a new attempt.
  f.time(1100);
  expect(
    (
      await f.accept({
        ...f.body,
        sequence: 5,
        timingToken: token,
        observation: { ...f.body.observation, attempt: 2 },
      })
    ).timingToken,
  ).toBe(rotated.timingToken);
  expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
});

it('does not refresh receipt, evidence, or issuance on an exact retry', async () => {
  const f = await fixture();
  f.time(400);
  const body = { ...f.body, timingToken: f.session.timingToken };
  const ack = await f.accept(body);
  const first = await f.status();
  f.time(5500);
  expect((await f.accept(body)).timingToken).toBe(ack.timingToken);
  const retried = await f.status();
  expect(retried.status.state).toBe('stale');
  expect(retried.status.observedAt).toBe(first.status.observedAt);
  expect(retried.status.decodedVideoAgeUpperBoundMs).toBe(5450);
  // Echoing the current token must measure from its original 400ms issue time.
  await f.accept({
    ...body,
    sequence: 2,
    timingToken: ack.timingToken,
    observation: { ...body.observation, attempt: 2 },
  });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(5150);
});

it.each([undefined, 'unknown-token'])(
  'accepts legacy/unknown tokens without adding unproven age (%s)',
  async (timingToken) => {
    const f = await fixture();
    f.time(400);
    const ack = await f.accept({ ...f.body, ...(timingToken ? { timingToken } : {}) });
    expect(ack.timingToken).toBe(f.session.timingToken);
    expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  },
);

it('preserves the older upper bound for repeated windows and across telemetry omission', async () => {
  const f = await fixture();
  f.time(400);
  const ack = await f.accept({ ...f.body, timingToken: f.session.timingToken });
  f.time(600);
  await f.accept({ ...f.body, sequence: 2, timingToken: ack.timingToken });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(550);
  f.time(700);
  await f.accept({ ...f.body, sequence: 3, timingToken: 'unknown' });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(650);
  const { decodedVideo: _, ...omitted } = f.body.observation;
  f.time(800);
  await f.accept({ ...f.body, sequence: 4, observation: omitted });
  const absent = await f.status();
  expect(absent.status.observation).not.toHaveProperty('decodedVideo');
  expect(absent.status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  f.time(1000);
  await f.accept({ ...f.body, sequence: 5 });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(950);
});

it.each(['window', 'attempt', 'generation', 'game'] as const)(
  'resets upper provenance for a new %s',
  async (change) => {
    const f = await fixture();
    f.time(400);
    await f.accept({ ...f.body, timingToken: f.session.timingToken });
    const next = structuredClone(f.body);
    next.sequence++;
    if (change === 'window') {
      Object.assign(next.observation.decodedVideo!.completed!, {
        sequence: 2,
        firstPTS: 450000,
        lastPTS: 897000,
        ageMs: 0,
      });
    } else if (change === 'attempt') next.observation.attempt++;
    else if (change === 'generation') {
      f.start('match', 1, 'new-sink');
      next.observation.generation = 2;
    } else {
      const stopped = f.matches.media.execute({
        commandId: 'stop',
        gameId: 'match',
        expectedGeneration: 1,
        issuedAt: new Date().toISOString(),
        operation: { type: 'stop' },
      });
      expect(stopped.accepted).toBe(true);
      expect(
        f.matches.execute({
          commandId: 'end',
          gameId: 'match',
          deviceId: 'scorer',
          expectedRevision: f.matches.get('match')!.revision,
          scorerEpoch: f.matches.get('match')!.scorer.epoch,
          issuedAt: new Date().toISOString(),
          operation: { type: 'end_match', reason: 'test' },
        }).accepted,
      ).toBe(true);
      f.setupGame('other');
      f.start('other');
      next.observation.gameId = 'other';
    }
    f.time(600);
    await f.accept(next);
    const status = f.observations.status(next.observation.gameId).status;
    expect(status.observation?.gameId).toBe(next.observation.gameId);
    expect(status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  },
);

it('isolates token provenance across replacement sessions and API restart', async () => {
  const f = await fixture();
  f.time(400);
  await f.accept({ ...f.body, timingToken: f.session.timingToken });
  f.time(500);
  const replacement = await f.register('replacement');
  expect(replacement.timingToken).not.toBe(f.session.timingToken);
  expect((await f.status()).status.state).toBe('unknown');
  expect((await f.report({ ...f.body, timingToken: f.session.timingToken })).status).toBe(409);
  await f.accept({
    ...f.body,
    sessionId: replacement.sessionId,
    timingToken: f.session.timingToken,
  });
  expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  const restarted = new WorkerObservations(
    f.matches.media,
    () => Date.now(),
    () => 0,
  );
  expect(() => restarted.report({ ...f.body, sessionId: replacement.sessionId })).toThrow(
    'worker_session_unknown',
  );
  expect(restarted.status('match').status.state).toBe('unknown');
  expect(restarted.register({ workerId: 'mac', runId: 'replacement' }).timingToken).not.toBe(
    replacement.timingToken,
  );
});

it('rejects malformed tokens and worker-injected upper bounds without rotating tokens', async () => {
  const f = await fixture();
  for (const timingToken of ['', 'x'.repeat(129), 'https://secret.test', 'with space', null, 10]) {
    expect((await f.report({ ...f.body, timingToken })).status).toBe(400);
  }
  for (const body of [
    { ...f.body, decodedVideoAgeUpperBoundMs: 0 },
    { ...f.body, observation: { ...f.body.observation, decodedVideoAgeUpperBoundMs: 0 } },
    {
      ...f.body,
      observation: {
        ...f.body.observation,
        decodedVideo: { ...f.body.observation.decodedVideo, decodedVideoAgeUpperBoundMs: 0 },
      },
    },
  ])
    expect((await f.report(body)).status).toBe(400);
  expect((await f.register()).timingToken).toBe(f.session.timingToken);
  f.time(400);
  const ack = await f.accept({ ...f.body, timingToken: f.session.timingToken });
  const rejected = await f.report({
    ...f.body,
    sequence: 2,
    timingToken: ack.timingToken,
    observation: { ...f.body.observation, frame: 0 },
  });
  expect(rejected.status).toBe(400);
  const conflict = await f.report({
    ...f.body,
    sequence: 2,
    timingToken: ack.timingToken,
    observation: { ...f.body.observation, frame: 1 },
  });
  expect(conflict.status).toBe(409);
  expect((await f.register()).timingToken).toBe(ack.timingToken);
  f.time(600);
  await f.accept({
    ...f.body,
    sequence: 2,
    timingToken: ack.timingToken,
    observation: { ...f.body.observation, attempt: 2 },
  });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(250);
});

it('isolates input and status mutations from age provenance', async () => {
  const f = await fixture();
  f.time(400);
  const body = { ...structuredClone(f.body), timingToken: f.session.timingToken };
  f.observations.report(body);
  body.observation.decodedVideo!.completed!.ageMs = 0;
  const first = f.observations.status('match');
  first.status.decodedVideoAgeUpperBoundMs = 0;
  first.status.observation!.decodedVideo!.completed!.sequence = 999;
  f.time(600);
  expect(f.observations.status('match').status.decodedVideoAgeUpperBoundMs).toBe(550);
});

it('rounds up fractional transit and residence while ignoring wall-clock changes', async () => {
  const f = await fixture(100.1);
  f.time(400.2);
  await f.accept({ ...f.body, timingToken: f.session.timingToken });
  f.time(600.3);
  f.wall(Date.parse('2040-01-01T00:00:00Z'));
  const forward = await f.status();
  expect(forward.status.decodedVideoAgeUpperBoundMs).toBe(552);
  f.wall(Date.parse('2000-01-01T00:00:00Z'));
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(552);
});

it.each(['throw', 'reversal', 'nan', 'infinity', 'negative', 'unsafe'] as const)(
  'latches an unavailable %s clock, leaves receipts stale and keeps ACKs working',
  async (failure) => {
    const f = await fixture();
    f.time(400);
    const body = { ...f.body, timingToken: f.session.timingToken };
    const ack = await f.accept(body);
    if (failure === 'throw') f.throwClock();
    else
      f.time(
        {
          reversal: 399,
          nan: NaN,
          infinity: Infinity,
          negative: -1,
          unsafe: Number.MAX_SAFE_INTEGER + 1,
        }[failure],
      );
    const status = await f.status();
    expect(status.status.state).toBe('stale');
    expect(status.status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
    expect(status.status.expiresAt).toBe(status.serverTime);
    f.restoreClock();
    f.time(600);
    expect(await f.accept(body)).not.toHaveProperty('timingToken');
    await f.accept({ ...body, sequence: 2, timingToken: ack.timingToken });
    expect((await f.status()).status.state).toBe('stale');
    expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
    expect(await f.register()).not.toHaveProperty('timingToken');
    expect(await f.register('after-failure')).not.toHaveProperty('timingToken');
  },
);

it('accepts reports when the first clock sample is unavailable', async () => {
  const f = await fixture(NaN);
  expect(f.session).not.toHaveProperty('timingToken');
  expect(await f.accept()).toMatchObject({ accepted: true });
  const status = await f.status();
  expect(status.status.state).toBe('stale');
  expect(status.status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
});

it.each(['receipt', 'residence', 'repeat'] as const)(
  'omits an overflowing %s upper bound instead of saturating',
  async (stage) => {
    const f = await fixture(0);
    const body = structuredClone(f.body);
    body.observation.decodedVideo!.completed!.ageMs = Number.MAX_SAFE_INTEGER - 100;
    f.time(stage === 'receipt' ? 200 : 50);
    const ack = await f.accept({ ...body, timingToken: f.session.timingToken });
    if (stage !== 'receipt')
      expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(
        Number.MAX_SAFE_INTEGER - 50,
      );
    f.time(200);
    if (stage === 'repeat') await f.accept({ ...body, sequence: 2, timingToken: ack.timingToken });
    expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
    f.time(250);
    await f.accept({ ...body, sequence: 3 });
    expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  },
);

it('latches contradictory newer lower age as unknown for the same window', async () => {
  const f = await fixture();
  f.time(400);
  const ack = await f.accept({ ...f.body, timingToken: f.session.timingToken });
  f.time(600);
  const newer = structuredClone(f.body);
  newer.sequence = 2;
  newer.observation.decodedVideo!.completed!.ageMs = 10000;
  await f.accept({ ...newer, timingToken: 'unknown' });
  expect((await f.status()).status.observation.decodedVideo.completed.ageMs).toBe(10000);
  expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  // A later recognized token must not hide the contradiction by proving a larger bound.
  f.time(700);
  await f.accept({ ...newer, sequence: 3, timingToken: ack.timingToken });
  expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  f.time(800);
  const current = await f.register();
  await f.accept({
    ...newer,
    sequence: 4,
    timingToken: current.timingToken,
    observation: { ...newer.observation, attempt: 2 },
  });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(10100);
});

it('does not contradict lower-age guards carried across a new generation in the same attempt', async () => {
  const f = await fixture();
  f.time(400);
  const ack = await f.accept({ ...f.body, timingToken: f.session.timingToken });
  f.start('match', 1, 'other-sink');
  f.time(1000);
  await f.accept({
    ...f.body,
    sequence: 2,
    observation: { ...f.body.observation, generation: 2 },
    timingToken: ack.timingToken,
  });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(650);
  // A later generation, still same attempt, has inherited lower-age residence even though
  // the current token is newer. That lower guard is deliberately retained for compatibility.
  const current = await f.register();
  f.start('match', 2, 'third-sink');
  f.time(1100);
  await f.accept({
    ...f.body,
    sequence: 3,
    observation: { ...f.body.observation, generation: 3 },
    timingToken: current.timingToken,
  });
  const status = (await f.status()).status;
  expect(status.observation.decodedVideo.completed.ageMs).toBe(750);
  expect(status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
});

it('omits fractional overflow at the maximum safe upper age', async () => {
  const f = await fixture(0);
  const body = structuredClone(f.body);
  body.observation.decodedVideo!.completed!.ageMs = Number.MAX_SAFE_INTEGER;
  f.time(0.1);
  await f.accept({ ...body, timingToken: f.session.timingToken });
  expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
});

it('does not let a recognized current token mask a contradiction with the prior upper bound', async () => {
  const f = await fixture();
  f.time(400);
  const first = await f.accept({ ...f.body, timingToken: f.session.timingToken });
  f.time(600);
  const newer = structuredClone(f.body);
  newer.sequence = 2;
  newer.observation.decodedVideo!.completed!.ageMs = 10000;
  // The candidate is 10200, but prior proven upper550 contradicts lower10000.
  const second = await f.accept({ ...newer, timingToken: first.timingToken });
  expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  f.time(700);
  newer.sequence = 3;
  newer.observation.decodedVideo!.completed!.ageMs = 10100;
  const third = await f.accept({ ...newer, timingToken: second.timingToken });
  expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  // Replacement of the completed window permits new independent proof.
  f.time(800);
  newer.sequence = 4;
  Object.assign(newer.observation.decodedVideo!.completed!, {
    sequence: 2,
    ageMs: 50,
    firstPTS: 450000,
    lastPTS: 897000,
  });
  await f.accept({ ...newer, timingToken: third.timingToken });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(150);
});

it('does not let a retained upper bound mask a contradictory newly proven candidate', async () => {
  const f = await fixture();
  f.time(400);
  const first = await f.accept({ ...f.body, timingToken: f.session.timingToken });
  f.time(600);
  const second = await f.accept({ ...f.body, sequence: 2, timingToken: first.timingToken });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(550);
  f.time(800);
  // Reusing the old sampled age50 with a newer token contradicts the retained lower450.
  // The new candidate250 must invalidate proof even though prior upper750 is large enough.
  const third = await f.accept({ ...f.body, sequence: 3, timingToken: second.timingToken });
  const status = (await f.status()).status;
  expect(status.observation.decodedVideo.completed.ageMs).toBe(450);
  expect(status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  f.time(1000);
  const sampled = structuredClone(f.body);
  sampled.sequence = 4;
  sampled.observation.decodedVideo!.completed!.ageMs = 650;
  await f.accept({ ...sampled, timingToken: third.timingToken });
  expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
});

it.each(['token', 'prior', 'residence'] as const)(
  'omits an overflowing upper bound when fractional %s endpoints would round elapsed down',
  async (stage) => {
    const f = await fixture(0.75);
    const body = structuredClone(f.body);
    body.observation.decodedVideo!.completed!.ageMs = 1;
    if (stage === 'token') f.time(Number.MAX_SAFE_INTEGER);
    await f.accept({ ...body, timingToken: f.session.timingToken });
    if (stage !== 'token') {
      expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(1);
      f.time(Number.MAX_SAFE_INTEGER);
      if (stage === 'prior') await f.accept({ ...body, sequence: 2 });
    }
    // Exact age+elapsed is MAX_SAFE_INTEGER+0.25, although subtracting raw
    // endpoints first rounds elapsed down and disguises that overflow.
    expect((await f.status()).status).not.toHaveProperty('decodedVideoAgeUpperBoundMs');
  },
);

it('rounds fractional elapsed endpoints outward before subtracting', async () => {
  const f = await fixture(100.75);
  f.time(400.25);
  await f.accept({ ...f.body, timingToken: f.session.timingToken });
  // ceil(receipt)-floor(issue)=301; identical receipt/status samples add no residence.
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(351);
  f.time(600.75);
  // ceil(status)-floor(receipt)=201 keeps the complete residence conservative.
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(552);
});

it('processing completion cannot refresh the age of its original decoder window', async () => {
  const f = await fixture(100);
  const wire = JSON.parse(
    readFileSync(
      new URL('../../../packages/protocol/fixtures/worker-processing-v1.json', import.meta.url),
      'utf8',
    ),
  );
  const body = {
    ...f.body,
    timingToken: f.session.timingToken,
    observation: wire.pending.status.observation,
  };
  body.observation.decodedVideo.completed.ageMs = 50;
  f.time(300);
  const acknowledgement = await f.accept(body);
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(250);
  f.time(1300);
  body.sequence = 2;
  body.timingToken = acknowledgement.timingToken;
  body.observation.processing = wire.complete.status.observation.processing;
  body.observation.decodedVideo.completed.ageMs = 1050;
  await f.accept(body);
  const completed = await f.status();
  expect(completed.status.decodedVideoAgeUpperBoundMs).toBe(2050);
  expect(completed.status.observation.decodedVideo.completed.ageMs).toBe(1050);
  expect(completed.status.observation.processing.interval.pendingFrames).toBe(0);
});

function cadenceBody(f: Awaited<ReturnType<typeof fixture>>) {
  return {
    ...f.body,
    timingToken: f.session.timingToken,
    pipelineReadId: '22222222-2222-4222-8222-222222222222',
    observation: {
      ...f.body.observation,
      decodedVideo: {
        ...f.body.observation.decodedVideo!,
        completed: null,
        clock: 'mpegts-pts-90k-v1',
      },
      decoderCadence: {
        formatVersion: 1,
        scopeID: '11111111-1111-4111-8111-111111111111',
        oneSecond: {
          sequence: 2,
          durationMs: 1000,
          ageMs: 100,
          firstPTS: 90000,
          lastPTS: 177000,
          freshFrames: 30,
          duplicateFrames: 0,
          reorderedFrames: 0,
          valid: true,
        },
        twoSeconds: {
          sequence: 1,
          durationMs: 2000,
          ageMs: 100,
          firstPTS: 0,
          lastPTS: 177000,
          freshFrames: 60,
          duplicateFrames: 0,
          reorderedFrames: 0,
          valid: true,
        },
        progress: { lastFreshPTS: 180000, ageMs: 50, stalled: false },
        invalidReason: null,
        ended: false,
      },
    },
  };
}
it('cadence snapshot age includes token transit and residence without changing measured progress', async () => {
  const f = await fixture();
  expect(f.session.decoderCadence).toBe('decoder-cadence-v1');
  const body = cadenceBody(f);
  f.time(150);
  await f.accept(body);
  f.time(200);
  const result = await f.status();
  expect(result.status.decoderCadenceAgeUpperBoundMs).toBe(100);
  expect(result.status.observation.decoderCadence).toEqual(body.observation.decoderCadence);
  f.time(1200);
  const later = await f.status();
  expect(later.status.decoderCadenceAgeUpperBoundMs).toBe(1100);
  expect(later.status.observation.decoderCadence.progress.stalled).toBe(false);
});
it('cadence omission is unknown and cannot erase anti-replay history', async () => {
  const f = await fixture();
  const body = cadenceBody(f);
  await f.accept(body);
  const omitted: any = structuredClone(body);
  omitted.sequence = 2;
  delete omitted.observation.decoderCadence;
  await f.accept(omitted);
  const status = await f.status();
  expect(status.status.observation.decoderCadence).toBeUndefined();
  expect(status.status.decoderCadenceAgeUpperBoundMs).toBeUndefined();
  body.sequence = 3;
  body.observation.decoderCadence.progress.ageMs = 49;
  expect((await f.report(body)).status).toBe(409);
});
it('cadence cannot qualify freshness without timing provenance or after clock failure', async () => {
  for (const mode of ['missing', 'foreign', 'clock']) {
    const f = await fixture();
    const body: any = cadenceBody(f);
    if (mode === 'missing') delete body.timingToken;
    if (mode === 'foreign') body.timingToken = 'not-issued';
    if (mode === 'clock') f.throwClock();
    await f.accept(body);
    expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBeUndefined();
  }
});
it('cadence scope cannot change within an attempt or return in a later attempt', async () => {
  const f = await fixture();
  const body = cadenceBody(f);
  await f.accept(body);
  body.sequence = 2;
  body.observation.decoderCadence.scopeID = '33333333-3333-4333-8333-333333333333';
  expect((await f.report(body)).status).toBe(409);
  body.observation.attempt = 2;
  body.pipelineReadId = '44444444-4444-4444-8444-444444444444';
  await f.accept(body);
  body.sequence = 3;
  body.observation.attempt = 3;
  body.pipelineReadId = '55555555-5555-4555-8555-555555555555';
  body.observation.decoderCadence.scopeID = '11111111-1111-4111-8111-111111111111';
  expect((await f.report(body)).status).toBe(409);
});
it('cadence requires current explicit read identity and valid transport coordinates', async () => {
  for (const field of ['read', 'clock', 'shape']) {
    const f = await fixture();
    const body: any = cadenceBody(f);
    if (field === 'read') delete body.pipelineReadId;
    if (field === 'clock') delete body.observation.decodedVideo.clock;
    if (field === 'shape') body.observation.decoderCadence.progress.stalled = true;
    expect([400, 409]).toContain((await f.report(body)).status);
  }
});

const freshTiming = 'worker-sample-timing-v1';
async function challenge(f: Awaited<ReturnType<typeof fixture>>, sessionId = f.session.sessionId) {
  const response = await f.post('sample-timing', { workerId: 'mac', sessionId });
  expect(response.status).toBe(200);
  return response.json();
}
it('advertises fresh sample timing and bounds the current sample after long idle', async () => {
  const f = await fixture();
  expect(f.session.sampleTiming).toBe(freshTiming);
  f.time(10_000);
  const timing = await challenge(f);
  expect(timing.timingToken).toMatch(/^[A-Za-z0-9_-]{1,128}$/);
  f.time(10_010);
  await f.accept({ ...cadenceBody(f), timingToken: timing.timingToken });
  f.time(10_015);
  expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBe(15);
  expect((await f.register()).timingToken).toBe(f.session.timingToken);
});
it('timing challenges do not mutate existing report age, epoch, or legacy issuance', async () => {
  const f = await fixture();
  await f.accept(cadenceBody(f));
  f.time(200);
  const before = await f.status();
  const legacy = await f.register();
  await challenge(f);
  await challenge(f);
  expect(await f.status()).toEqual(before);
  expect((await f.register()).timingToken).toBe(legacy.timingToken);
  f.time(300);
  await f.accept({
    ...f.body,
    sequence: 2,
    timingToken: legacy.timingToken,
    observation: {
      ...f.body.observation,
      decodedVideo: { ...f.body.observation.decodedVideo!, clock: 'mpegts-pts-90k-v1' },
    },
  });
  expect((await f.status()).status.decodedVideoAgeUpperBoundMs).toBe(250);
});
it('accepts exact duplicates without consuming a later pending challenge', async () => {
  const f = await fixture();
  f.time(200);
  const first = await challenge(f);
  const body = { ...cadenceBody(f), timingToken: first.timingToken };
  await f.accept(body);
  f.time(300);
  const next = await challenge(f);
  await f.accept(body);
  f.time(310);
  const advancing = structuredClone(body);
  advancing.sequence++;
  advancing.timingToken = next.timingToken;
  advancing.observation.decoderCadence.oneSecond.ageMs++;
  advancing.observation.decoderCadence.twoSeconds.ageMs++;
  await f.accept(advancing);
  expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBe(10);
});
it.each(['evicted', 'consumed', 'foreign'])(
  'does not prove timing with a %s challenge',
  async (mode) => {
    const f = await fixture();
    const old = await challenge(f);
    if (mode === 'evicted') await challenge(f);
    if (mode === 'consumed')
      await f.accept({
        ...f.body,
        timingToken: old.timingToken,
        observation: { ...f.body.observation, decodedVideo: undefined },
      });
    if (mode === 'foreign') {
      const other = await f.post('sessions', { workerId: 'other', runId: 'run' });
      const registered = await other.json();
      const timing = await f.post('sample-timing', {
        workerId: 'other',
        sessionId: registered.sessionId,
      });
      old.timingToken = (await timing.json()).timingToken;
    }
    await f.accept({ ...cadenceBody(f), sequence: 2, timingToken: old.timingToken });
    expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBeUndefined();
  },
);
it('keeps a pending challenge when a report is rejected', async () => {
  const f = await fixture();
  const timing = await challenge(f);
  const body = { ...cadenceBody(f), timingToken: timing.timingToken };
  expect(
    (await f.report({ ...body, observation: { ...body.observation, generation: 2 } })).status,
  ).toBe(409);
  f.time(120);
  await f.accept(body);
  expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBe(20);
});
it.each(['throw', 'backward', 'nonfinite'])(
  'omits fresh proof after a %s clock failure',
  async (mode) => {
    const f = await fixture();
    if (mode === 'throw') f.throwClock();
    else f.time(mode === 'backward' ? 99 : NaN);
    expect((await challenge(f)).timingToken).toBeUndefined();
    f.restoreClock();
    f.time(200);
    expect((await challenge(f)).timingToken).toBeUndefined();
    await f.accept(cadenceBody(f));
    expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBeUndefined();
  },
);
it('requires authenticated strict session-bound timing requests', async () => {
  const f = await fixture();
  const path = '/v1/worker/sample-timing';
  expect(
    (
      await f.app.request(path, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{}',
      })
    ).status,
  ).toBe(401);
  for (const body of [
    {},
    { workerId: 'mac', sessionId: f.session.sessionId, timingToken: 'injected' },
    { workerId: 'mac', sessionId: 7 },
  ])
    expect((await f.post('sample-timing', body)).status).toBe(400);
  const unknown = await f.post('sample-timing', { workerId: 'mac', sessionId: 'missing' });
  expect(unknown.status).toBe(409);
  expect(await unknown.json()).toEqual({ error: 'worker_session_unknown' });
  await f.register('replacement');
  const retired = await f.post('sample-timing', {
    workerId: 'mac',
    sessionId: f.session.sessionId,
  });
  expect(retired.status).toBe(409);
  expect(await retired.json()).toEqual({ error: 'worker_session_retired' });
});
it.each(['retained', 'omitted', 'unproven'])(
  'cannot redate unchanged cadence with a new challenge (%s)',
  async (mode) => {
    const f = await fixture();
    const first = await challenge(f);
    const body = {
      ...cadenceBody(f),
      timingToken: mode === 'unproven' ? 'unknown' : first.timingToken,
    };
    await f.accept(body);
    if (mode === 'omitted')
      await f.accept({
        ...f.body,
        sequence: 2,
        observation: { ...f.body.observation, decodedVideo: body.observation.decodedVideo },
      });
    f.time(1000);
    const next = await challenge(f);
    await f.accept({ ...body, sequence: 3, timingToken: next.timingToken });
    expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBe(
      mode === 'retained' ? 900 : undefined,
    );
  },
);
it('cannot redate an unchanged delivery sample and keeps merged delta history', async () => {
  const f = await fixture();
  const first = await challenge(f);
  const body = {
    ...cadenceBody(f),
    timingToken: first.timingToken,
    observation: {
      ...cadenceBody(f).observation,
      decoderDelivery: {
        formatVersion: 1,
        scopeID: '33333333-3333-4333-8333-333333333333',
        sampledAtMs: 80,
        coverageAtMs: 0,
        afterOrdinal: 0,
        lastOrdinal: 1,
        arrivals: [[3000, 40]],
        invalidReason: null,
        ended: false,
      },
    },
  };
  await f.accept(body);
  f.time(1000);
  const next = await challenge(f);
  await f.accept({
    ...body,
    sequence: 2,
    timingToken: next.timingToken,
    observation: {
      ...body.observation,
      decoderDelivery: { ...body.observation.decoderDelivery, afterOrdinal: 1, arrivals: [] },
    },
  });
  const result = f.observations.status('match', true);
  expect(result.status.decoderDeliveryAgeUpperBoundMs).toBe(900);
  expect(result.status.observation?.decoderDelivery?.arrivals).toEqual([[3000, 40]]);
});

it.each([
  ['equal', 1100],
  ['regressed', 1500],
] as const)(
  'does not redate a %s cadence coordinate hidden by a higher window sequence',
  async (mode, initialAge) => {
    const f = await fixture();
    const first = await challenge(f);
    const body = { ...cadenceBody(f), timingToken: first.timingToken };
    const old = structuredClone(body);
    old.observation.decoderCadence.oneSecond = {
      ...old.observation.decoderCadence.oneSecond,
      sequence: 1,
      ageMs: initialAge,
      firstPTS: 0,
      lastPTS: 87000,
    };
    (old.observation.decoderCadence as any).twoSeconds = null;
    await f.accept(old);
    f.time(1000);
    const next = await challenge(f);
    body.sequence = 2;
    body.timingToken = next.timingToken;
    if (mode === 'regressed') expect((await f.report(body)).status).toBe(409);
    else {
      await f.accept(body);
      expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBe(900);
    }
  },
);

it('does not consume a pending challenge when a legacy report succeeds', async () => {
  const f = await fixture();
  const timing = await challenge(f);
  const body = cadenceBody(f);
  await f.accept(body);
  const next = structuredClone(body);
  next.sequence++;
  next.observation.decoderCadence.oneSecond.ageMs++;
  next.observation.decoderCadence.twoSeconds.ageMs++;
  next.timingToken = timing.timingToken;
  f.time(110);
  await f.accept(next);
  expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBe(10);
});
it('cannot use a fresh challenge from a retired session in its replacement', async () => {
  const f = await fixture();
  const old = await challenge(f);
  const replacement = await f.register('replacement');
  await f.accept({
    ...cadenceBody(f),
    sessionId: replacement.sessionId,
    timingToken: old.timingToken,
  });
  expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBeUndefined();
});
it('loses pending fresh proof when the clock fails after issuance', async () => {
  const f = await fixture();
  const timing = await challenge(f);
  f.throwClock();
  await f.accept({ ...cadenceBody(f), timingToken: timing.timingToken });
  expect((await f.status()).status.decoderCadenceAgeUpperBoundMs).toBeUndefined();
});
