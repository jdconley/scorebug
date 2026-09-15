import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { WorkerObservations } from '../src/worker-observations.js';
import { testConfig } from './helpers.js';

it('returns the canonical native worker-status fixture through scoped HTTP routes', async () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../packages/protocol/fixtures/worker-status-v1.json', import.meta.url),
      'utf8',
    ),
  );
  const config = testConfig();
  const { matches } = createApp(config);
  let now = Date.parse('2026-09-14T04:00:00.000Z');
  let monotonic = 0;
  const observations = new WorkerObservations(
    matches.media,
    () => now,
    () => monotonic,
  );
  const { app } = createApp(config, { matches, observations });
  try {
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
    const status = async () => {
      const result = await app.request('/v1/matches/match/media/status', {
        headers: { authorization: `Bearer ${scorer.token}` },
      });
      expect(result.status).toBe(200);
      return result.json();
    };
    expect(await status()).toEqual(fixture.unknown);
    const { sessionId } = observations.register({ workerId: 'mac', runId: 'one' });
    observations.report({
      workerId: 'mac',
      sessionId,
      sequence: 1,
      observation: fixture.current.status.observation,
    });
    const current = await status();
    const workerEpoch = current.status.workerEpoch;
    expect(workerEpoch).toMatch(/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/);
    expect(current).toEqual({
      ...fixture.current,
      status: { ...fixture.current.status, workerEpoch },
    });
    now += 5000;
    monotonic += 5000;
    expect(await status()).toEqual({
      ...fixture.stale,
      status: { ...fixture.stale.status, workerEpoch },
    });
    matches.media.execute({
      commandId: 'stop',
      gameId: 'match',
      expectedGeneration: 1,
      issuedAt: new Date().toISOString(),
      operation: { type: 'stop' },
    });
    expect(await status()).toEqual(fixture.stopped);
  } finally {
    matches.close();
  }
});
