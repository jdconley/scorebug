import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';
import { WorkerObservations } from '../src/worker-observations.js';
import { createTestApp, testStore } from './helpers.js';

const worker = { workerId: 'mac', outputId: 'sink' };

it('serves every field of the iOS worker-status fixture, plus the simple phase', async () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../packages/protocol/fixtures/worker-status-v1.json', import.meta.url),
      'utf8',
    ),
  );
  const matches = testStore();
  let now = Date.parse('2026-09-14T04:00:00.000Z');
  let monotonic = 0;
  const observations = new WorkerObservations(
    matches.media,
    () => now,
    () => monotonic,
  );
  const { app } = createTestApp({ matches, observations });
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
    matches.media.execute(
      {
        commandId: 'start',
        gameId: 'match',
        expectedGeneration: 0,
        issuedAt: new Date().toISOString(),
        operation: {
          type: 'start',
          selection: {
            captureDeviceId: 'phone',
            recordingId: 'archive',
          },
        },
      },
      worker,
    );
    const status = async () => {
      const result = await app.request('/v1/matches/match/media/status', {
        headers: { authorization: `Bearer ${scorer.token}` },
      });
      expect(result.status).toBe(200);
      return result.json();
    };
    // The app decodes the fixture's fields and ignores the rest (phase, output).
    const expectDecodes = (actual: any, expected: any, phase: string) => {
      expect(actual).toMatchObject(expected);
      expect(actual.status.phase).toBe(phase);
    };
    expectDecodes(await status(), fixture.unknown, 'starting');
    const { sessionId } = observations.register({ workerId: 'mac', runId: 'one' });
    observations.report({
      workerId: 'mac',
      sessionId,
      sequence: 1,
      observation: fixture.current.status.observation,
    });
    expectDecodes(await status(), fixture.current, 'live');
    now += 5000;
    monotonic += 5000;
    expectDecodes(await status(), fixture.stale, 'error');
    matches.media.execute(
      {
        commandId: 'stop',
        gameId: 'match',
        expectedGeneration: 1,
        issuedAt: new Date().toISOString(),
        operation: { type: 'stop' },
      },
      worker,
    );
    expectDecodes(await status(), fixture.stopped, 'idle');
  } finally {
    matches.close();
  }
});
