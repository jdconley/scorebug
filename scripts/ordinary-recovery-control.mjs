import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

/** XCTest controls the owned network fixture, never the app's quality policy. */
export async function startOrdinaryRecoveryControl({ uplink, artifact }) {
  assert.equal(typeof uplink.constrainForward, 'function');
  assert.equal(typeof uplink.restoreForward, 'function');
  const token = randomBytes(32).toString('hex'),
    runID = randomUUID();
  const records = [],
    activeRequests = new Set();
  let busy = false,
    closed = false,
    stopping;
  async function handle(request, response) {
    const receivedAtHost = performance.now();
    response.setHeader('connection', 'close');
    function reply(status, value) {
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(JSON.stringify(value));
      request.resume();
    }
    if (request.headers.authorization !== `Bearer ${token}`)
      return reply(401, { error: 'Unauthorized' });
    if (request.method !== 'POST' || !['/constrain', '/restore'].includes(request.url))
      return reply(404, { error: 'Unknown operation' });
    if (closed || busy) return reply(409, { error: 'Controller unavailable' });
    busy = true;
    const deadline = setTimeout(() => request.destroy(), 2000);
    request.setTimeout(2000, () => request.destroy());
    try {
      const chunks = [];
      let size = 0;
      // Data listener keeps oversize rejection a normal HTTP response instead
      // of destroying the request via async-iterator cancellation.
      const body = await new Promise((resolve, reject) => {
        const fail = () => reject(new Error('Incomplete request'));
        request.once('aborted', fail);
        request.once('error', fail);
        request.on('data', (chunk) => {
          size += chunk.length;
          if (size > 8192) {
            resolve(null);
            return;
          }
          chunks.push(chunk);
        });
        request.once('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      });
      if (body === null) return reply(413, { error: 'Body exceeds limit' });
      let input;
      try {
        input = JSON.parse(body);
        assert(input && typeof input === 'object' && !Array.isArray(input));
        assert.deepEqual(Object.keys(input).sort(), ['diagnostic', 'runID', 'sequence']);
        assert.equal(input.runID, runID);
        assert(Number.isSafeInteger(input.sequence));
        assert(
          input.diagnostic &&
            typeof input.diagnostic === 'object' &&
            !Array.isArray(input.diagnostic),
        );
        assert(Object.values(input.diagnostic).every((v) => typeof v === 'string'));
        assert(Buffer.byteLength(JSON.stringify(input.diagnostic)) <= 4096);
        assert.match(input.diagnostic.policyOwnerKey ?? '', /^[a-f0-9]{64}$/);
      } catch {
        return reply(400, { error: 'Invalid bounded request' });
      }
      const operation = records.length === 0 ? '/constrain' : '/restore';
      if (
        closed ||
        records.length >= 2 ||
        input.sequence !== records.length + 1 ||
        request.url !== operation
      )
        return reply(409, { error: 'Unexpected phase or sequence' });
      let receipt;
      try {
        receipt = operation === '/constrain' ? uplink.constrainForward() : uplink.restoreForward();
      } catch {
        return reply(409, { error: 'Network phase is not ready' });
      }
      // The authoritative complete snapshot stays in the bounded two-entry audit.
      // The small response identifies that exact boundary for native clock brackets.
      const respondedAtHost = performance.now();
      records.push({
        runID,
        sequence: input.sequence,
        operation: operation.slice(1),
        diagnostic: input.diagnostic,
        receivedAtHost,
        receipt,
        respondedAtHost,
      });
      reply(200, {
        runID,
        sequence: input.sequence,
        phase: receipt.phase,
        rateBitsPerSecond: receipt.rateBitsPerSecond,
        appliedAt: receipt.appliedAt,
        forwardOperationOrdinal: receipt.forward.queue.rateLedgerOperationOrdinal,
      });
    } catch {
      if (!response.headersSent && !response.destroyed) reply(400, { error: 'Incomplete request' });
    } finally {
      clearTimeout(deadline);
      busy = false;
    }
  }
  const server = createServer((request, response) => {
    const active = handle(request, response);
    activeRequests.add(active);
    void active.then(
      () => activeRequests.delete(active),
      () => activeRequests.delete(active),
    );
  });
  server.requestTimeout = 2000;
  server.headersTimeout = 2000;
  server.maxHeadersCount = 16;
  server.setTimeout(2000, (socket) => socket.destroy());
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    endpoint: `http://127.0.0.1:${server.address().port}`,
    token,
    runID,
    stop() {
      return (stopping ??= (async () => {
        closed = true;
        await new Promise((resolve, reject) => {
          server.close((error) => (error ? reject(error) : resolve()));
          server.closeAllConnections();
        });
        await Promise.allSettled([...activeRequests]);
        const audit = JSON.stringify({
          formatVersion: 1,
          runID,
          closed,
          hostClock: 'performance.now milliseconds',
          records,
        });
        assert(Buffer.byteLength(audit) <= 8 * 1024 * 1024, 'Recovery audit exceeds limit');
        await writeFile(join(artifact, 'ordinary-recovery-control.json'), audit, {
          flag: 'wx',
          mode: 0o600,
        });
      })());
    },
  };
}
