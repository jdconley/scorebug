import { Hono, type MiddlewareHandler } from 'hono';
import { createMiddleware } from 'hono/factory';
import { zValidator } from '@hono/zod-validator';
import { z } from 'zod';
import { WORKER_STATES, WORKER_REASONS, type MatchCredential } from '@scorebug/protocol';
import { WorkerObservations, WorkerObservationError } from '../worker-observations.js';
import { bearer, ownerAuth } from '../auth.js';
import type { Config } from '../config.js';
import type { MatchStore } from '../matches-store.js';
import { MediaStoreError } from '../media-store.js';
import { MediaStateError } from '../media-state.js';
import { RelayLifecycleError, type RelayLifecycle } from '../relay-lifecycle.js';
import { PUBLISHING_ATTEMPT_ID_PATTERN } from '../publishing-attempt.js';

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
// The app may leave workerId/outputId out; the server then picks its worker.
const selection = z
  .object({
    workerId: id.optional(),
    outputId: id.optional(),
    captureDeviceId: id,
    recordingId: id,
  })
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
export function mediaRoutes(
  config: Config,
  matches: MatchStore,
  installation: MiddlewareHandler = ownerAuth(matches.account),
  relayLifecycle?: RelayLifecycle,
  observations = new WorkerObservations(matches.media),
) {
  const app = new Hono<Env>();
  const scoped = createMiddleware<Env>(async (c, next) => {
    const token = c.req.header('authorization')?.match(/^Bearer (.+)$/i)?.[1] ?? '';
    const credential = matches.authenticate(c.req.param('id') ?? '', token);
    if (!credential) return c.json({ error: 'unauthorized' }, 401);
    c.set('credential', credential);
    await next();
  });
  app.get('/status', scoped, (c) => c.json(observations.status(c.get('credential').gameId)));
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
  app.post(
    '/publish',
    scoped,
    zValidator(
      'json',
      z
        .object({
          recordingId: id,
          generation: sequence.min(1),
          publishingAttemptId: z
            .string()
            .length(36)
            .regex(PUBLISHING_ATTEMPT_ID_PATTERN)
            .optional(),
        })
        .strict(),
    ),
    async (c) => {
      const credential = c.get('credential');
      if (credential.role !== 'capture') return c.json({ error: 'forbidden' }, 403);
      if (!relayLifecycle) return c.json({ error: 'relay_not_configured' }, 503);
      const { publishingAttemptId, ...request } = c.req.valid('json');
      const result = await relayLifecycle.publish({
        ...request,
        ...(publishingAttemptId !== undefined ? { publishingAttemptId } : {}),
        gameId: credential.gameId,
        deviceId: credential.deviceId,
      });
      const current = matches.media.get(credential.gameId).broadcast;
      if (
        current.desired !== 'running' ||
        current.generation !== result.generation ||
        current.selection?.captureDeviceId !== credential.deviceId ||
        current.selection.recordingId !== result.recordingId
      )
        throw new RelayLifecycleError('broadcast_changed');
      return c.json({ ...result, serverTime: new Date().toISOString() });
    },
  );
  app.post('/commands', installation, zValidator('json', command), (c) => {
    const command = c.req.valid('json');
    if (command.gameId !== c.req.param('id')) return c.json({ error: 'forbidden' }, 403);
    const configured =
      config.WORKER_ID && config.OUTPUT_ID
        ? { workerId: config.WORKER_ID, outputId: config.OUTPUT_ID }
        : undefined;
    const outcome = matches.media.execute(command, (requested) =>
      observations.selectWorker(requested, configured),
    );
    return c.json(outcome, outcome.accepted ? 200 : 409);
  });
  app.get('/commands/:commandId', installation, (c) => {
    const outcome = matches.media.receipt(c.req.param('id') ?? '', c.req.param('commandId'));
    return outcome ? c.json(outcome) : c.json({ error: 'command_not_found' }, 404);
  });
  app.onError((error, c) => {
    if (error instanceof WorkerObservationError) return c.json({ error: error.code }, 409);
    if (error instanceof RelayLifecycleError)
      return c.json(
        { error: error.code },
        error.code === 'capture_not_selected'
          ? 403
          : error.code === 'broadcast_changed'
            ? 409
            : 503,
      );
    if (error instanceof MediaStoreError || error instanceof MediaStateError)
      return c.json({ error: error.code }, error.code === 'match_not_found' ? 404 : 409);
    throw error;
  });
  return app;
}
export function workerRoutes(
  config: Config,
  matches: MatchStore,
  relayLifecycle?: RelayLifecycle,
  observations = new WorkerObservations(matches.media),
) {
  const app = new Hono();
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    await next();
  });
  app.use('*', bearer(config.HOME_TOKEN, 'worker'));
  app.post(
    '/sessions',
    zValidator('json', z.object({ workerId: id, runId: id, outputId: id.optional() }).strict()),
    (c) => c.json(observations.register(c.req.valid('json'))),
  );
  app.post(
    '/observations',
    zValidator(
      'json',
      z
        .object({
          workerId: id,
          sessionId: id,
          sequence,
          observation: z
            .object({
              gameId: id,
              generation: sequence,
              state: z.enum(WORKER_STATES),
              reason: z.enum(WORKER_REASONS).nullable(),
              attempt: sequence,
              frame: sequence.nullable(),
              outTimeUs: sequence.nullable(),
              scoreRevision: sequence.nullable(),
              output: z
                .object({
                  width: z.number().int().min(2).max(7680),
                  height: z.number().int().min(2).max(4320),
                  fps: z.number().int().min(1).max(60),
                  bitrateKbps: z.number().int().min(100).max(100_000),
                })
                .strict()
                .optional(),
            })
            .strict()
            .refine(
              (o) =>
                o.state !== 'producing_output' ||
                (o.frame !== null && o.frame > 0 && o.outTimeUs !== null && o.outTimeUs > 0),
            ),
        })
        .strict(),
    ),
    (c) => {
      const { observation, ...request } = c.req.valid('json');
      const { output, ...rest } = observation;
      return c.json(
        observations.report({
          ...request,
          observation: { ...rest, ...(output ? { output } : {}) },
        }),
      );
    },
  );
  app.get('/snapshot', zValidator('query', z.object({ workerId: id }).strict()), (c) => {
    const { workerId } = c.req.valid('query');
    observations.seen(workerId);
    return c.json({
      assignment: matches.media.workerAssignment(workerId),
      serverTime: new Date().toISOString(),
    });
  });
  app.get('/connection', zValidator('query', z.object({ workerId: id }).strict()), async (c) => {
    if (!relayLifecycle) return c.json({ error: 'relay_not_configured' }, 503);
    const connection = await relayLifecycle.worker(c.req.valid('query').workerId);
    if (connection) {
      const current = matches.media.workerAssignment(c.req.valid('query').workerId);
      if (
        !current ||
        current.match.id !== connection.gameId ||
        current.media.broadcast.generation !== connection.generation
      )
        throw new RelayLifecycleError('broadcast_changed');
    }
    return c.json({ connection, serverTime: new Date().toISOString() });
  });
  app.onError((error, c) => {
    if (error instanceof WorkerObservationError) return c.json({ error: error.code }, 409);
    if (error instanceof RelayLifecycleError)
      return c.json({ error: error.code }, error.code === 'broadcast_changed' ? 409 : 503);
    throw error;
  });
  return app;
}
