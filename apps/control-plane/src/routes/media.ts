import { Hono } from 'hono';
import { createMiddleware } from 'hono/factory';
import { zValidator } from '@hono/zod-validator';
import { z } from 'zod';
import type { MatchCredential } from '@scorebug/protocol';
import { bearer } from '../auth.js';
import type { Config } from '../config.js';
import type { MatchStore } from '../matches-store.js';
import { MediaStoreError } from '../media-store.js';
import { MediaStateError } from '../media-state.js';

const id = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);
const sequence = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const report = z
  .object({
    recordingId: id,
    sequence,
    status: z.enum(['recording', 'stopped', 'interrupted']),
    startedAt: z.iso.datetime({ offset: true }),
  })
  .strict();
const selection = z
  .object({ workerId: id, outputId: id, captureDeviceId: id, recordingId: id })
  .strict();
const command = z
  .object({
    commandId: id,
    gameId: id,
    expectedGeneration: sequence,
    issuedAt: z.iso.datetime({ offset: true }),
    operation: z.discriminatedUnion('type', [
      z.object({ type: z.literal('start'), selection }).strict(),
      z.object({ type: z.literal('stop') }).strict(),
    ]),
  })
  .strict();
type Env = { Variables: { credential: Omit<MatchCredential, 'token'> } };

/** Mounted under /v1/matches/:id/media. Recording telemetry never changes scoring authority. */
export function mediaRoutes(config: Config, matches: MatchStore) {
  const app = new Hono<Env>();
  const installation = bearer(config.PHONE_TOKEN, 'installation');
  const scoped = createMiddleware<Env>(async (c, next) => {
    const token = c.req.header('authorization')?.match(/^Bearer (.+)$/i)?.[1] ?? '';
    const credential = matches.authenticate(c.req.param('id') ?? '', token);
    if (!credential) return c.json({ error: 'unauthorized' }, 401);
    c.set('credential', credential);
    await next();
  });
  app.get('/', scoped, (c) =>
    c.json({
      snapshot: matches.media.get(c.get('credential').gameId),
      serverTime: new Date().toISOString(),
    }),
  );
  app.post('/recordings', scoped, zValidator('json', report), (c) => {
    const credential = c.get('credential');
    if (credential.role !== 'capture') return c.json({ error: 'forbidden' }, 403);
    const recording = matches.media.reportRecording(
      credential.gameId,
      credential.deviceId,
      c.req.valid('json'),
    );
    return c.json({ recording, serverTime: new Date().toISOString() });
  });
  app.post('/commands', installation, zValidator('json', command), (c) => {
    const command = c.req.valid('json');
    if (command.gameId !== c.req.param('id')) return c.json({ error: 'forbidden' }, 403);
    const outcome = matches.media.execute(command);
    return c.json(outcome, outcome.accepted ? 200 : 409);
  });
  app.get('/commands/:commandId', installation, (c) => {
    const outcome = matches.media.receipt(c.req.param('id') ?? '', c.req.param('commandId'));
    return outcome ? c.json(outcome) : c.json({ error: 'command_not_found' }, 404);
  });
  app.onError((error, c) => {
    if (error instanceof MediaStoreError || error instanceof MediaStateError)
      return c.json({ error: error.code }, error.code === 'match_not_found' ? 404 : 409);
    throw error;
  });
  return app;
}
export function workerRoutes(config: Config, matches: MatchStore) {
  const app = new Hono();
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    await next();
  });
  app.use('*', bearer(config.HOME_TOKEN, 'worker'));
  app.get('/snapshot', zValidator('query', z.object({ workerId: id }).strict()), (c) =>
    c.json({
      assignment: matches.media.workerAssignment(c.req.valid('query').workerId),
      serverTime: new Date().toISOString(),
    }),
  );
  return app;
}
