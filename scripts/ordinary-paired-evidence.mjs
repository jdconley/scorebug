import assert from 'node:assert/strict';

/** Durable accepted operations prove identity and transitions, not transport routing. */
export function qualifyOrdinaryPairedEvidence(input) {
  return qualify(input, false);
}
export function qualifyOrdinaryDirectWatchEvidence(input) {
  return qualify(input, true);
}
function qualify({ pairings, commands, mediaCommands, final }, direct) {
  assert.equal(pairings.length, 1, 'Exactly one real companion pairing required');
  const pairing = pairings[0];
  assert(pairing.redemption_request, 'Companion offer must be redeemed');
  const watch = pairing.watch_device_id;
  assert.deepEqual(
    commands.map((row) => row.request.operation.type),
    ['take_over', 'take_over', 'award_point', 'undo', 'award_point', 'end_match'],
  );
  const phone = commands[0].request.deviceId;
  assert(phone && watch && phone !== watch, 'Phone and real Watch identities must differ');
  assert.equal(new Set(commands.map((row) => row.request.commandId)).size, commands.length);
  assert(
    commands.every(
      (row) => row.outcome.accepted === true && row.outcome.commandId === row.request.commandId,
    ),
  );
  assert(
    commands
      .slice(1)
      .every(
        (row) => row.request.deviceId === watch && row.outcome.snapshot.scorer.deviceId === watch,
      ),
  );
  assert.equal(commands[2].request.operation.side, 'home');
  assert.equal(commands[4].request.operation.side, 'away');
  for (const [index, home, away] of [
    [2, 1, 0],
    [3, 0, 0],
    [4, 0, 1],
    [5, 0, 1],
  ]) {
    assert.equal(commands[index].outcome.snapshot.score.home, home);
    assert.equal(commands[index].outcome.snapshot.score.away, away);
  }
  assert.equal(final.status, 'ended');
  assert.equal(final.score.home, 0);
  assert.equal(final.score.away, 1);
  assert.equal(final.scorer.deviceId, watch);
  assert.equal(final.broadcast.desired, 'stopped');
  assert.equal(
    new Set(mediaCommands.map((row) => row.request.commandId)).size,
    mediaCommands.length,
  );
  assert(
    mediaCommands.length >= 1 && mediaCommands.length <= 2,
    'One start and at most one explicit post-end stop required',
  );
  const [start, stop] = mediaCommands;
  assert.equal(start.request.operation.type, 'start');
  // Film owns a separate persisted device identity from native phone scoring.
  const selection = start.request.operation.selection;
  assert(selection.captureDeviceId && selection.recordingId);
  const recording = start.outcome.snapshot.recordings.find(
    (item) => item.recordingId === selection.recordingId,
  );
  assert(
    recording &&
      recording.deviceId === selection.captureDeviceId &&
      recording.status === 'recording',
    'Accepted start must select its actual active capture recording',
  );
  assert.equal(start.outcome.accepted, true);
  assert.equal(start.outcome.commandId, start.request.commandId);
  assert.equal(start.outcome.snapshot.broadcast.desired, 'running');
  const started = start.outcome.snapshot.broadcast.generation;
  assert.equal(started, start.request.expectedGeneration + 1);
  assert.equal(
    start.request.expectedGeneration,
    0,
    'Disposable match must have no earlier broadcast',
  );
  const ended = commands[5].outcome.snapshot.broadcast;
  assert.equal(ended.desired, 'stopped');
  assert.equal(ended.generation, started + 1, 'Match end must invalidate the live generation');
  if (stop) {
    assert.equal(stop.request.operation.type, 'stop');
    assert.equal(stop.outcome.accepted, true);
    assert.equal(stop.outcome.commandId, stop.request.commandId);
    assert.equal(stop.request.expectedGeneration, ended.generation);
    assert.equal(stop.outcome.snapshot.broadcast.desired, 'stopped');
    assert.equal(stop.outcome.snapshot.broadcast.generation, ended.generation + 1);
  }
  assert.equal(final.broadcast.generation, ended.generation + (stop ? 1 : 0));
  return {
    watchCommands: commands.slice(1).map((row) => ({
      commandId: row.request.commandId,
      operation: row.request.operation.type,
      side: row.request.operation.side,
      accepted: row.outcome.accepted,
    })),
    phoneScorerDeviceId: phone,
    captureDeviceId: selection.captureDeviceId,
    recordingId: selection.recordingId,
    watchDeviceId: watch,
    pairingId: pairing.pairing_id,
    startGeneration: started,
    endGeneration: ended.generation,
    finalGeneration: final.broadcast.generation,
    ...(direct ? { setupTransport: 'simulator-fixture', watchConnectivityQualified: false } : {}),
    routeQualification: direct
      ? 'Simulator fixture setup and native direct HTTP scoring with durable accepted identity-bound commands; no WatchConnectivity qualification'
      : 'Real companion setup and accepted identity-bound commands; individual command routes are not inferred',
    mediaQualified: false,
  };
}

export async function readOrdinaryPairedEvidence(
  databasePath,
  matchId,
  setupTransport = 'watch-connectivity',
) {
  assert(['watch-connectivity', 'simulator-fixture'].includes(setupTransport));
  const { DatabaseSync } = await import('node:sqlite');
  const database = new DatabaseSync(databasePath, { readOnly: true });
  try {
    const rows = (table) =>
      database
        .prepare(`SELECT request,outcome FROM ${table} WHERE game_id=? ORDER BY rowid`)
        .all(matchId)
        .map((row) => ({ request: JSON.parse(row.request), outcome: JSON.parse(row.outcome) }));
    const stored = JSON.parse(
      database.prepare('SELECT data FROM matches WHERE id=?').get(matchId).data,
    );
    const qualifyEvidence =
      setupTransport === 'simulator-fixture'
        ? qualifyOrdinaryDirectWatchEvidence
        : qualifyOrdinaryPairedEvidence;
    return qualifyEvidence({
      pairings: database
        .prepare(
          'SELECT pairing_id,watch_device_id,redemption_request FROM watch_pairings WHERE game_id=?',
        )
        .all(matchId),
      commands: rows('commands'),
      mediaCommands: rows('media_commands'),
      final: {
        status: stored.scoring.status,
        score: stored.scoring.score,
        scorer: stored.scorer,
        broadcast: stored.broadcast,
      },
    });
  } finally {
    database.close();
  }
}
