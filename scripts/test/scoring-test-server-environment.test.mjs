import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startScoringTestServer } from '../scoring-test-server.mjs';

test('ordinary server clears ambient publisher endpoint while validating explicit overrides', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'scorebug-test-server-environment-'));
  const saved = { host: process.env.INGEST_PUBLISH_HOST, port: process.env.INGEST_PUBLISH_PORT };
  let server;
  try {
    process.env.INGEST_PUBLISH_HOST = 'invalid://ambient-route';
    process.env.INGEST_PUBLISH_PORT = 'invalid-port';
    server = await startScoringTestServer(join(directory, 'ordinary.sqlite'));
    assert.match(server.baseURL, /^http:\/\/127\.0\.0\.1:\d+$/);
    await server.stop();
    server = undefined;
    await assert.rejects(
      startScoringTestServer(join(directory, 'explicit-invalid.sqlite'), {
        INGEST_PUBLISH_HOST: 'invalid://explicit-route',
        INGEST_PUBLISH_PORT: '12345',
      }),
      /API exited/,
    );
    server = await startScoringTestServer(join(directory, 'explicit-valid.sqlite'), {
      INGEST_PUBLISH_HOST: '127.0.0.1',
      INGEST_PUBLISH_PORT: '12345',
    });
  } finally {
    await server?.stop();
    for (const [key, value] of [
      ['INGEST_PUBLISH_HOST', saved.host],
      ['INGEST_PUBLISH_PORT', saved.port],
    ]) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    await rm(directory, { recursive: true, force: true });
  }
});
