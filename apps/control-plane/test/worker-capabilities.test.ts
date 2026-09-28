import { MatchStore } from '../src/matches-store.js';
import { WorkerObservations } from '../src/worker-observations.js';
import { expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { testConfig } from './helpers.js';

it('capabilities are scoped, expire without heartbeats, and change with the worker session', async () => {
  let clock = 0;
  const matches = new MatchStore(':memory:', testConfig().PHONE_TOKEN);
  const observations = new WorkerObservations(matches.media, Date.now, () => clock);
  const { app } = createApp(testConfig(), { matches, observations });
  try {
    const capabilities = {
      version: 1 as const,
      outputId: 'sink',
      encoder: 'software' as const,
      outputProfile: '1080p30' as const,
      outputMode: 'rtmp+record' as const,
      startup: 'passed' as const,
      sustainedPerformance: 'unqualified' as const,
    };
    const team = { name: 'Home', shortName: 'HOM', color: '#112233' };
    matches.create({
      id: 'match',
      deviceId: 'phone',
      teams: { home: team, away: team },
      rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
    });
    const credential = matches.issueCredential('match', 'camera', 'capture');
    const endpoint = '/v1/matches/match/media/capabilities?workerId=mac';
    expect((await app.request(endpoint)).status).toBe(401);
    expect(observations.capabilities('mac').state).toBe('unknown');
    const session = observations.register({ workerId: 'mac', runId: 'first', capabilities });
    expect(observations.capabilities('mac')).toMatchObject({ state: 'fresh', capabilities });
    const response = await app.request(endpoint, {
      headers: { authorization: `Bearer ${credential.token}` },
    });
    expect(response.status).toBe(200);
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(await response.json()).toMatchObject({ state: 'fresh', capabilities, validForMs: 5000 });
    clock = 5001;
    expect(observations.capabilities('mac').state).toBe('stale');
    observations.sampleTiming({ workerId: 'mac', sessionId: session.sessionId });
    expect(observations.capabilities('mac').state).toBe('fresh');
    observations.register({ workerId: 'mac', runId: 'second' });
    expect(observations.capabilities('mac')).toMatchObject({
      state: 'unknown',
      capabilities: null,
    });
    expect(() =>
      observations.sampleTiming({ workerId: 'mac', sessionId: session.sessionId }),
    ).toThrow();
    const bad = await app.request('/v1/worker/sessions', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${testConfig().HOME_TOKEN}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        workerId: 'mac',
        runId: 'third',
        capabilities: { ...capabilities, sustainedPerformance: 'qualified' },
      }),
    });
    expect(bad.status).toBe(400);
  } finally {
    matches.close();
  }
});
