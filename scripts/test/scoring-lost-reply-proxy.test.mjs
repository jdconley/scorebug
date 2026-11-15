import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from 'node:http';
import test from 'node:test';
import { startScoringLostReplyProxy } from '../scoring-lost-reply-proxy.mjs';

test('loses only an applied point reply, blocks reconciliation, then resumes real HTTP', async () => {
  let points = 0;
  const upstream = createServer(async (request, response) => {
    for await (const _ of request) {
      /* consume */
    }
    if (request.method === 'POST') points++;
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ snapshot: { score: { home: points, away: 0 } } }));
  }).listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  const proxy = await startScoringLostReplyProxy(`http://127.0.0.1:${upstream.address().port}`);
  try {
    assert.equal((await fetch(proxy.baseURL + '/v1/matches/active')).status, 200);
    await assert.rejects(
      fetch(proxy.baseURL + '/v1/matches/game/commands', {
        method: 'POST',
        body: JSON.stringify({
          commandId: 'point',
          operation: { type: 'award_point', side: 'home' },
        }),
      }),
    );
    assert.equal(points, 1);
    assert.equal((await fetch(proxy.baseURL + '/v1/matches/game/commands/point')).status, 503);
    assert.equal(proxy.audit().phase, 'blocked');
    proxy.resume();
    assert.equal((await fetch(proxy.baseURL + '/v1/matches/game/commands/point')).status, 200);
    assert.equal(points, 1);
    assert.equal(proxy.audit().lostCommand.commandId, 'point');
    assert.equal(proxy.audit().lostCommand.score.home, 1);
    assert.throws(() => proxy.resume());
  } finally {
    await proxy.stop();
    upstream.closeAllConnections();
    await new Promise((resolve) => upstream.close(resolve));
  }
});
test('fault target is restricted to an owned loopback server', async () => {
  for (const url of [
    'https://example.com',
    'http://localhost:1234',
    'http://127.0.0.1:1234/private',
  ])
    await assert.rejects(startScoringLostReplyProxy(url));
});
