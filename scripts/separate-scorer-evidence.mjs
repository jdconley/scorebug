import assert from 'node:assert/strict';

/** Durable receipts establish actors and accepted order; they do not prove media quality. */
export function qualifySeparateScorerEvidence({
  matchId,
  recordingId,
  commands,
  mediaCommands,
  recordings,
  final,
  watchDeviceId,
}) {
  assert(matchId && recordingId);
  const count = watchDeviceId ? 11 : 6;
  assert.equal(commands.length, count, 'Exact durable score command count required');
  const rows = [...commands].sort(
    (a, b) => a.outcome.snapshot.revision - b.outcome.snapshot.revision,
  );
  const camera = rows[0].request.deviceId,
    scorer = rows[2].request.deviceId;
  assert(camera && scorer && camera !== scorer, 'Scoring identities must differ');
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
  if (watchDeviceId) {
    assert(
      watchDeviceId !== camera && watchDeviceId !== scorer,
      'Watch must have a third scoring identity',
    );
    const reason = rows.at(-1).request.operation.reason;
    assert(typeof reason === 'string' && reason.length > 0);
    operations.push(
      { type: 'take_over' },
      { type: 'award_point', side: 'home' },
      { type: 'undo' },
      { type: 'award_point', side: 'away' },
      { type: 'end_match', reason },
    );
    scores.push([1, 1], [2, 1], [1, 1], [1, 2], [1, 2]);
  }
  assert.equal(
    new Set(rows.map((r) => `${r.request.deviceId}/${r.request.commandId}`)).size,
    count,
  );
  for (const [i, { request, outcome }] of rows.entries()) {
    const actor = i < 2 ? camera : i < 6 ? scorer : watchDeviceId,
      epoch = i < 2 ? 2 : i < 6 ? 3 : 4;
    assert.equal(request.gameId, matchId);
    assert.equal(outcome.snapshot.id, matchId);
    assert.equal(outcome.accepted, true);
    assert.equal(outcome.error, null);
    assert.equal(outcome.commandId, request.commandId);
    assert(request.commandId);
    assert.equal(request.deviceId, actor);
    assert.deepEqual(request.operation, operations[i]);
    assert.equal(request.expectedRevision, i === 0 ? 0 : i + 1);
    assert.equal(outcome.snapshot.revision, i === 0 ? 1 : i + 2);
    assert.equal(request.scorerEpoch, i === 0 ? 1 : i <= 2 ? 2 : i <= 6 ? 3 : 4);
    assert.deepEqual(outcome.snapshot.scorer, { deviceId: actor, epoch });
    assert.deepEqual(outcome.snapshot.score, {
      home: scores[i][0],
      away: scores[i][1],
      set: 1,
      homeSets: 0,
      awaySets: 0,
    });
    assert.equal(outcome.snapshot.status, watchDeviceId && i === 10 ? 'ended' : 'active');
    assert.deepEqual(outcome.snapshot.broadcast, {
      desired: i === 0 || i === 10 ? 'stopped' : 'running',
      generation: i === 0 ? 0 : i === 10 ? 2 : 1,
    });
  }
  assert.equal(
    mediaCommands.length,
    watchDeviceId ? 1 : 2,
    'Native start; Watch end replaces explicit media stop',
  );
  const [start, stop] = [...mediaCommands].sort(
    (a, b) => a.request.expectedGeneration - b.request.expectedGeneration,
  );
  assert.equal(new Set(mediaCommands.map((r) => r.request.commandId)).size, watchDeviceId ? 1 : 2);
  for (const [i, row] of [start, stop].filter(Boolean).entries()) {
    assert.equal(row.request.gameId, matchId);
    assert.equal(row.outcome.snapshot.gameId, matchId);
    assert.equal(row.request.expectedGeneration, i);
    assert.equal(row.outcome.accepted, true);
    assert.equal(row.outcome.error, null);
    assert.equal(row.outcome.commandId, row.request.commandId);
    assert.equal(row.request.operation.type, i ? 'stop' : 'start');
    assert.equal(row.outcome.snapshot.broadcast.generation, i + 1);
    assert.equal(row.outcome.snapshot.broadcast.desired, i ? 'stopped' : 'running');
  }
  const selection = start.request.operation.selection;
  assert.equal(selection.workerId, 'mac');
  assert.equal(selection.outputId, 'local-sink');
  assert.equal(selection.recordingId, recordingId);
  assert(selection.captureDeviceId);
  assert.notEqual(selection.captureDeviceId, scorer, 'Scorer cannot be the capture actor');
  assert.deepEqual(start.outcome.snapshot.broadcast.selection, selection);
  if (stop) assert.equal(stop.outcome.snapshot.broadcast.selection, null);
  const active = start.outcome.snapshot.recordings;
  assert.equal(active.length, 1);
  assert.equal(active[0].gameId, matchId);
  assert.equal(active[0].recordingId, recordingId);
  assert.equal(active[0].deviceId, selection.captureDeviceId);
  assert.equal(active[0].status, 'recording');
  assert(Number.isSafeInteger(active[0].sequence) && active[0].sequence >= 0);
  assert(
    typeof active[0].startedAt === 'string' && Number.isFinite(Date.parse(active[0].startedAt)),
  );
  const atStreamStop = stop ? stop.outcome.snapshot.recordings : active;
  assert.equal(atStreamStop.length, 1);
  for (const field of ['gameId', 'recordingId', 'deviceId', 'startedAt'])
    assert.equal(atStreamStop[0][field], active[0][field]);
  assert.equal(atStreamStop[0].status, 'recording');
  assert(
    Number.isSafeInteger(atStreamStop[0].sequence) &&
      atStreamStop[0].sequence >= active[0].sequence,
  );
  assert.equal(recordings.length, 1, 'Only filming phone may associate a recording');
  assert.equal(recordings[0].gameId, matchId);
  assert.equal(recordings[0].recordingId, recordingId);
  assert.equal(recordings[0].deviceId, selection.captureDeviceId);
  assert.equal(recordings[0].status, 'stopped');
  assert.equal(recordings[0].startedAt, active[0].startedAt);
  assert(
    Number.isSafeInteger(recordings[0].sequence) &&
      recordings[0].sequence > atStreamStop[0].sequence,
  );
  assert.equal(final.id, matchId);
  assert.equal(final.revision, watchDeviceId ? 12 : 8);
  assert.equal(final.status, watchDeviceId ? 'ended' : 'active');
  assert.deepEqual(final.score, {
    home: 1,
    away: watchDeviceId ? 2 : 1,
    set: 1,
    homeSets: 0,
    awaySets: 0,
  });
  assert.deepEqual(final.scorer, {
    deviceId: watchDeviceId ?? scorer,
    epoch: watchDeviceId ? 4 : 3,
  });
  if (watchDeviceId) assert.notEqual(selection.captureDeviceId, watchDeviceId);
  assert.deepEqual(final.broadcast, { desired: 'stopped', generation: 2 });
  return {
    cameraScorerDeviceId: camera,
    otherScorerDeviceId: scorer,
    captureDeviceId: selection.captureDeviceId,
    recordingId,
    matchId,
    acceptedScoreCommands: count,
    acceptedMediaCommands: mediaCommands.length,
    ...(watchDeviceId ? { watchDeviceId } : {}),
    scope: 'Durable command and recording association only',
    mediaQualified: false,
  };
}
export async function readSeparateScorerEvidence(
  databasePath,
  matchId,
  recordingId,
  watchDeviceId,
) {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(databasePath, { readOnly: true });
  try {
    const rows = (table) =>
      db
        .prepare(`SELECT request,outcome FROM ${table} WHERE game_id=?`)
        .all(matchId)
        .map((row) => ({ request: JSON.parse(row.request), outcome: JSON.parse(row.outcome) }));
    const stored = JSON.parse(db.prepare('SELECT data FROM matches WHERE id=?').get(matchId).data);
    return qualifySeparateScorerEvidence({
      matchId,
      recordingId,
      watchDeviceId,
      commands: rows('commands'),
      mediaCommands: rows('media_commands'),
      recordings: db
        .prepare('SELECT data FROM recordings WHERE game_id=?')
        .all(matchId)
        .map((row) => JSON.parse(row.data)),
      final: {
        id: stored.id,
        revision: stored.revision,
        status: stored.scoring.status,
        score: stored.scoring.score,
        scorer: stored.scorer,
        broadcast: stored.broadcast,
      },
    });
  } finally {
    db.close();
  }
}
