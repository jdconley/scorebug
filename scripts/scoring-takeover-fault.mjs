import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { scoringTestToken } from './scoring-test-server.mjs';

/** Real API actor used only while the native scorer is held behind its fault proxy. */
export async function takeOverPendingScore(baseURL, { command, token, receipt }) {
  async function post(path, credential, body, status = 200) {
    const response = await fetch(baseURL + path, {
      method: 'POST',
      headers: { authorization: `Bearer ${credential}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(5000),
    });
    assert.equal(response.status, status);
    return response.json();
  }
  const path = `/v1/matches/${command.gameId}`,
    deviceId = 'pending-recovery-peer';
  const joined = await post(path + '/join', scoringTestToken, { deviceId, role: 'score' });
  const takeover = await post(path + '/commands', joined.credential.token, {
    commandId: randomUUID(),
    gameId: command.gameId,
    deviceId,
    expectedRevision: receipt.snapshot.revision,
    scorerEpoch: receipt.snapshot.scorer.epoch,
    issuedAt: new Date().toISOString(),
    operation: { type: 'take_over' },
  });
  assert.equal(takeover.accepted, true);
  const staleOwner = await post(
    path + '/commands',
    token,
    {
      ...command,
      commandId: randomUUID(),
      issuedAt: new Date().toISOString(),
      expectedRevision: takeover.snapshot.revision,
    },
    409,
  );
  const staleRevision = await post(
    path + '/commands',
    joined.credential.token,
    {
      ...command,
      commandId: randomUUID(),
      issuedAt: new Date().toISOString(),
      deviceId,
      scorerEpoch: takeover.snapshot.scorer.epoch,
      expectedRevision: receipt.snapshot.revision,
    },
    409,
  );
  assert.equal(staleOwner.accepted, false);
  assert.equal(staleOwner.error, 'scorer_changed');
  assert.equal(staleRevision.accepted, false);
  assert.equal(staleRevision.error, 'revision_conflict');
  for (const outcome of [takeover, staleOwner, staleRevision]) {
    assert.equal(outcome.snapshot.score.home, 1);
    assert.equal(outcome.snapshot.score.away, 0);
    assert.equal(outcome.snapshot.scorer.deviceId, deviceId);
    assert.equal(outcome.snapshot.revision, takeover.snapshot.revision);
  }
  return { takeover, staleOwner, staleRevision };
}
