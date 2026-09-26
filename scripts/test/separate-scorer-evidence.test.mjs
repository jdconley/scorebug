import test from 'node:test';
import assert from 'node:assert/strict';
import { qualifySeparateScorerEvidence } from '../separate-scorer-evidence.mjs';
function fixture() {
  const matchId = 'match',
    recordingId = 'recording',
    capture = 'capture-distinct';
  const operations = [
    { type: 'take_over' },
    { type: 'award_point', side: 'home' },
    { type: 'take_over' },
    { type: 'award_point', side: 'away' },
    { type: 'undo' },
    { type: 'award_point', side: 'away' },
  ];
  const scores = [
    [0, 0],
    [1, 0],
    [1, 0],
    [1, 1],
    [1, 0],
    [1, 1],
  ];
  const commands = operations.map((operation, i) => ({
    request: {
      gameId: matchId,
      commandId: `score-${i}`,
      deviceId: i < 2 ? 'camera-score' : 'other-score',
      expectedRevision: i === 0 ? 0 : i + 1,
      scorerEpoch: i === 0 ? 1 : i <= 2 ? 2 : 3,
      operation,
    },
    outcome: {
      commandId: `score-${i}`,
      accepted: true,
      error: null,
      snapshot: {
        id: matchId,
        revision: i === 0 ? 1 : i + 2,
        status: 'active',
        score: { home: scores[i][0], away: scores[i][1], set: 1, homeSets: 0, awaySets: 0 },
        scorer: { deviceId: i < 2 ? 'camera-score' : 'other-score', epoch: i < 2 ? 2 : 3 },
        broadcast: { desired: i === 0 ? 'stopped' : 'running', generation: i === 0 ? 0 : 1 },
      },
    },
  }));
  const recording = {
    gameId: matchId,
    recordingId,
    deviceId: capture,
    status: 'stopped',
    sequence: 1,
    startedAt: '2026-09-26T12:00:00.000Z',
  };
  const mediaCommands = ['start', 'stop'].map((type, i) => ({
    request: {
      gameId: matchId,
      commandId: type,
      expectedGeneration: i,
      operation: {
        type,
        ...(!i
          ? {
              selection: {
                workerId: 'mac',
                outputId: 'local-sink',
                captureDeviceId: capture,
                recordingId,
              },
            }
          : {}),
      },
    },
    outcome: {
      commandId: type,
      accepted: true,
      error: null,
      snapshot: {
        gameId: matchId,
        broadcast: {
          desired: i ? 'stopped' : 'running',
          generation: i + 1,
          selection: i
            ? null
            : { workerId: 'mac', outputId: 'local-sink', captureDeviceId: capture, recordingId },
        },
        recordings: [{ ...recording, status: 'recording', sequence: 0 }],
      },
    },
  }));
  return {
    matchId,
    recordingId,
    commands,
    mediaCommands,
    recordings: [recording],
    final: {
      ...commands[5].outcome.snapshot,
      revision: 8,
      broadcast: { desired: 'stopped', generation: 2 },
    },
  };
}
test('durable sequence proves distinct scoring roles and independent capture, independent of row ordering', () => {
  const f = fixture();
  f.commands.reverse();
  f.mediaCommands.reverse();
  const result = qualifySeparateScorerEvidence(f);
  assert.equal(result.cameraScorerDeviceId, 'camera-score');
  assert.equal(result.otherScorerDeviceId, 'other-score');
  assert.equal(result.captureDeviceId, 'capture-distinct');
  assert.equal(result.acceptedScoreCommands, 6);
});
for (const [name, mutate] of [
  ['extra tap', (f) => f.commands.push(structuredClone(f.commands[5]))],
  ['wrong actor', (f) => (f.commands[3].request.deviceId = 'camera-score')],
  ['duplicate revision', (f) => (f.commands[4].outcome.snapshot.revision = 4)],
  ['stale epoch', (f) => (f.commands[3].request.scorerEpoch = 2)],
  ['wrong game', (f) => (f.commands[3].request.gameId = 'other')],
  ['early stream stop', (f) => (f.commands[4].outcome.snapshot.broadcast.desired = 'stopped')],
  ['rejected command', (f) => (f.commands[2].outcome.accepted = false)],
  ['wrong side', (f) => (f.commands[3].request.operation.side = 'home')],
  ['wrong score', (f) => (f.commands[4].outcome.snapshot.score.away = 1)],
  ['wrong exported recording', (f) => (f.recordingId = 'old-recording')],
  [
    'scorer capture association',
    (f) =>
      f.recordings.push({
        ...f.recordings[0],
        deviceId: 'other-score',
        recordingId: 'scorer-video',
      }),
  ],
  ['missing terminal recording', (f) => (f.recordings[0].status = 'recording')],
  ['extra restart', (f) => f.mediaCommands.push(structuredClone(f.mediaCommands[0]))],
  [
    'wrong start ACK selection',
    (f) => (f.mediaCommands[0].outcome.snapshot.broadcast.selection.outputId = 'elsewhere'),
  ],
  [
    'stop retaining selection',
    (f) =>
      (f.mediaCommands[1].outcome.snapshot.broadcast.selection =
        f.mediaCommands[0].request.operation.selection),
  ],
  ['missing stop recording', (f) => (f.mediaCommands[1].outcome.snapshot.recordings = [])],
  [
    'wrong stop recording identity',
    (f) => (f.mediaCommands[1].outcome.snapshot.recordings[0].recordingId = 'other'),
  ],
  [
    'early archive stop',
    (f) => (f.mediaCommands[1].outcome.snapshot.recordings[0].status = 'stopped'),
  ],
  ['changed archive start time', (f) => (f.recordings[0].startedAt = '2026-09-26T12:01:00.000Z')],
  [
    'changed stop start time',
    (f) => (f.mediaCommands[1].outcome.snapshot.recordings[0].startedAt = 'other'),
  ],
  [
    'final sequence not after stream stop',
    (f) => (f.mediaCommands[1].outcome.snapshot.recordings[0].sequence = 1),
  ],
  [
    'invalid initial sequence',
    (f) => (f.mediaCommands[0].outcome.snapshot.recordings[0].sequence = -1),
  ],
  ['wrong final owner', (f) => (f.final.scorer.deviceId = 'camera-score')],
])
  test(`rejects ${name}`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => qualifySeparateScorerEvidence(f));
  });

test('actual API receipts include media revision increments and deduplicate a retried point', async (t) => {
  const { mkdtemp, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { startScoringTestServer, scoringTestToken } = await import('../scoring-test-server.mjs');
  const { readSeparateScorerEvidence } = await import('../separate-scorer-evidence.mjs');
  const directory = await mkdtemp(join(tmpdir(), 'scorebug-separate-ledger-')),
    database = join(directory, 'match.sqlite');
  let server;
  t.after(async () => {
    await server?.stop();
    await rm(directory, { recursive: true, force: true });
  });
  server = await startScoringTestServer(database);
  async function request(path, token, body) {
    const r = await fetch(server.baseURL + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(5000),
    });
    const value = await r.json();
    assert(r.ok, `API status ${r.status}`);
    return value;
  }
  const matchId = 'separate-native-test',
    recordingId = 'actual-recording',
    capture = 'film-device';
  await request('/v1/matches', scoringTestToken, {
    id: matchId,
    deviceId: 'device-lab-bootstrap',
    teams: {
      home: { name: 'HOME', shortName: 'HOME', color: '#123456' },
      away: { name: 'AWAY', shortName: 'AWAY', color: '#123456' },
    },
    rules: { bestOf: 3, pointsToWin: 25, decidingPointsToWin: 15, winBy: 2, pointCap: null },
  });
  const credentials = {};
  for (const [deviceId, role] of [
    ['camera-score', 'score'],
    ['other-score', 'score'],
    [capture, 'capture'],
  ])
    credentials[deviceId] = (
      await request(`/v1/matches/${matchId}/join`, scoringTestToken, { deviceId, role })
    ).credential.token;
  let serial = 0,
    lastCommand;
  async function score(deviceId, operation) {
    const { snapshot } = await request('/v1/matches/active', scoringTestToken);
    lastCommand = {
      gameId: matchId,
      deviceId,
      commandId: `score-${serial++}`,
      expectedRevision: snapshot.revision,
      scorerEpoch: snapshot.scorer.epoch,
      issuedAt: new Date().toISOString(),
      operation,
    };
    const value = await request(
      `/v1/matches/${matchId}/commands`,
      credentials[deviceId],
      lastCommand,
    );
    assert.equal(value.accepted, true);
    return value;
  }
  await score('camera-score', { type: 'take_over' });
  const startedAt = new Date().toISOString();
  await request(`/v1/matches/${matchId}/media/recordings`, credentials[capture], {
    recordingId,
    sequence: 0,
    status: 'recording',
    startedAt,
  });
  await request(`/v1/matches/${matchId}/media/commands`, scoringTestToken, {
    gameId: matchId,
    commandId: 'start',
    expectedGeneration: 0,
    issuedAt: new Date().toISOString(),
    operation: {
      type: 'start',
      selection: { workerId: 'mac', outputId: 'local-sink', captureDeviceId: capture, recordingId },
    },
  });
  await score('camera-score', { type: 'award_point', side: 'home' });
  await score('other-score', { type: 'take_over' });
  await score('other-score', { type: 'award_point', side: 'away' });
  await score('other-score', { type: 'undo' });
  const last = await score('other-score', { type: 'award_point', side: 'away' });
  assert.deepEqual(
    await request(`/v1/matches/${matchId}/commands`, credentials['other-score'], lastCommand),
    last,
  );
  await request(`/v1/matches/${matchId}/media/commands`, scoringTestToken, {
    gameId: matchId,
    commandId: 'stop',
    expectedGeneration: 1,
    issuedAt: new Date().toISOString(),
    operation: { type: 'stop' },
  });
  await request(`/v1/matches/${matchId}/media/recordings`, credentials[capture], {
    recordingId,
    sequence: 1,
    status: 'stopped',
    startedAt,
  });
  await server.stop();
  server = undefined;
  const result = await readSeparateScorerEvidence(database, matchId, recordingId);
  assert.equal(result.acceptedScoreCommands, 6);
  assert.equal(result.captureDeviceId, capture);
});
