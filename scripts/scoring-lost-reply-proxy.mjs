import assert from 'node:assert/strict';
import { createServer } from 'node:http';

/** Test-only loopback fault: commit one real point, lose its reply, then hold an outage. */
export async function startScoringLostReplyProxy(baseURL) {
  const upstream = new URL(baseURL);
  assert(
    upstream.protocol === 'http:' &&
      upstream.hostname === '127.0.0.1' &&
      upstream.port &&
      upstream.pathname === '/' &&
      !upstream.search &&
      !upstream.username &&
      !upstream.password,
  );
  let phase = 'armed',
    lostCommand,
    stopped = false;
  const requests = [],
    active = new Set();
  async function handle(request, response) {
    try {
      assert(requests.length < 256, 'Bounded fault audit exhausted');
      const event = { method: request.method, path: request.url, phase };
      requests.push(event);
      if (phase === 'blocked' || phase === 'applying') {
        response.writeHead(503, { 'content-type': 'application/json', connection: 'close' });
        response.end(JSON.stringify({ error: 'Owned test outage' }));
        event.status = 503;
        return;
      }
      const chunks = [];
      let size = 0;
      for await (const chunk of request) {
        size += chunk.length;
        assert(size <= 65536, 'Request exceeds fault fixture bound');
        chunks.push(chunk);
      }
      const body = Buffer.concat(chunks);
      const command =
        request.method === 'POST' && /^\/v1\/matches\/[^/]+\/commands$/.test(request.url)
          ? JSON.parse(body.toString())
          : undefined;
      const lose = phase === 'armed' && command?.operation?.type === 'award_point';
      if (lose) phase = 'applying';
      const reply = await fetch(upstream.origin + request.url, {
        method: request.method,
        headers: {
          'content-type': 'application/json',
          ...(request.headers.authorization
            ? { authorization: request.headers.authorization }
            : {}),
        },
        ...(body.length ? { body } : {}),
        signal: AbortSignal.timeout(5000),
        redirect: 'error',
      });
      const bytes = Buffer.from(await reply.arrayBuffer());
      event.status = reply.status;
      if (lose && reply.status === 200) {
        const receipt = JSON.parse(bytes.toString());
        lostCommand = {
          commandId: command.commandId,
          gameId: command.gameId,
          operation: command.operation,
          score: receipt.snapshot.score,
        };
        phase = 'blocked';
        event.replyLost = true;
        response.destroy();
      } else {
        if (lose) phase = 'armed';
        response.writeHead(reply.status, {
          'content-type': 'application/json',
          connection: 'close',
        });
        response.end(bytes);
      }
    } catch {
      if (phase === 'applying') phase = 'armed';
      response.destroy();
    }
  }
  const server = createServer((request, response) => {
    const task = handle(request, response);
    active.add(task);
    void task.finally(() => active.delete(task));
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  server.setTimeout(5000, (socket) => socket.destroy());
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    baseURL: `http://127.0.0.1:${server.address().port}`,
    resume() {
      assert(phase === 'blocked' && !stopped);
      phase = 'restored';
    },
    audit() {
      return structuredClone({ phase, lostCommand, requests });
    },
    async stop() {
      if (stopped) return;
      stopped = true;
      const closed = new Promise((resolve) => server.close(resolve));
      server.closeAllConnections();
      await Promise.all([...active]);
      await closed;
    },
  };
}
