import { Hono } from 'hono';
import { createMiddleware } from 'hono/factory';
import { zValidator } from '@hono/zod-validator';
import { z } from 'zod';
import {
  WORKER_STATES,
  WORKER_REASONS,
  DECODED_VIDEO_INVALID_REASONS,
  type MatchCredential,
} from '@scorebug/protocol';
import { WorkerObservations, WorkerObservationError } from '../worker-observations.js';
import { bearer } from '../auth.js';
import type { Config } from '../config.js';
import type { MatchStore } from '../matches-store.js';
import { MediaStoreError } from '../media-store.js';
import { MediaStateError } from '../media-state.js';
import { RelayLifecycleError, type RelayLifecycle } from '../relay-lifecycle.js';

const id = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);
const sequence = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const pts = z.number().int().min(Number.MIN_SAFE_INTEGER).max(Number.MAX_SAFE_INTEGER);
const decodedVideo = z
  .object({
    completed: z
      .object({
        sequence: sequence.min(1),
        durationMs: z.literal(5000),
        ageMs: z.number().nonnegative().max(Number.MAX_SAFE_INTEGER),
        firstPTS: pts.nullable(),
        lastPTS: pts.nullable(),
        freshFrames: sequence,
        duplicateFrames: sequence,
        reorderedFrames: sequence,
        valid: z.boolean(),
      })
      .strict()
      .refine((w) => {
        if (!Number.isSafeInteger(w.freshFrames + w.duplicateFrames + w.reorderedFrames))
          return false;
        if (w.freshFrames === 0) return w.firstPTS === null && w.lastPTS === null;
        if (w.firstPTS === null || w.lastPTS === null) return false;
        return w.freshFrames === 1 ? w.firstPTS === w.lastPTS : w.firstPTS < w.lastPTS;
      })
      .nullable(),
    invalidReason: z.enum(DECODED_VIDEO_INVALID_REASONS).nullable(),
    ended: z.boolean(),
  })
  .strict()
  .refine((v) => v.completed === null || v.completed.valid === (v.invalidReason === null));
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
export function mediaRoutes(
  config: Config,
  matches: MatchStore,
  relayLifecycle?: RelayLifecycle,
  observations = new WorkerObservations(matches.media),
) {
  const app = new Hono<Env>();
  const installation = bearer(config.PHONE_TOKEN, 'installation');
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
    zValidator('json', z.object({ recordingId: id, generation: sequence.min(1) }).strict()),
    async (c) => {
      const credential = c.get('credential');
      if (credential.role !== 'capture') return c.json({ error: 'forbidden' }, 403);
      if (!relayLifecycle) return c.json({ error: 'relay_not_configured' }, 503);
      const result = await relayLifecycle.publish({
        ...c.req.valid('json'),
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
    const outcome = matches.media.execute(command);
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
  app.post('/sessions', zValidator('json', z.object({ workerId: id, runId: id }).strict()), (c) =>
    c.json(observations.register(c.req.valid('json'))),
  );
  app.post(
    '/observations',
    zValidator(
      'json',
      z
        .object({
          workerId: id,
          sessionId: id,
          timingToken: id.optional(),
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
              decodedVideo: decodedVideo.optional(),
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
      const body = c.req.valid('json');
      const { decodedVideo, ...observation } = body.observation;
      const { timingToken, ...request } = body;
      return c.json(
        observations.report({
          ...request,
          ...(timingToken !== undefined ? { timingToken } : {}),
          observation: { ...observation, ...(decodedVideo ? { decodedVideo } : {}) },
        }),
      );
    },
  );
  app.get('/snapshot', zValidator('query', z.object({ workerId: id }).strict()), (c) =>
    c.json({
      assignment: matches.media.workerAssignment(c.req.valid('query').workerId),
      serverTime: new Date().toISOString(),
    }),
  );
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
