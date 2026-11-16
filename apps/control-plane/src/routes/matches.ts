import type { WorkerObservations } from '../worker-observations.js';
import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { createMiddleware } from 'hono/factory';
import { zValidator } from '@hono/zod-validator';
import { z } from 'zod';
import type { MatchCredential } from '@scorebug/protocol';
import { joinLink as protocolJoinLink, SCOREBUG_STYLES } from '@scorebug/protocol';
import { bearerToken, ownerAuth, resolveOwner } from '../auth.js';
import type { Config } from '../config.js';
import { mediaRoutes } from './media.js';
import { inviteRoutes } from './account.js';
import { defaultShortName } from '../scoring.js';
import type { RelayLifecycle } from '../relay-lifecycle.js';
import { MatchStore, MatchStoreError } from '../matches-store.js';

const id = z
  .string()
  .min(1)
  .max(128)
  .regex(/^[A-Za-z0-9_-]+$/);
export const teamName = z.string().trim().min(1).max(80);
// Scorebug label: at most 8 characters (code points); defaults from the name.
export const teamShortName = z
  .string()
  .trim()
  .min(1)
  .refine((value) => Array.from(value).length <= 8, {
    message: 'Short name must be at most 8 characters',
  });
export const teamColor = z.string().regex(/^#[0-9a-fA-F]{6}$/);
const team = z
  .object({
    name: teamName,
    shortName: teamShortName.optional(),
    color: teamColor,
  })
  .strict()
  .transform(({ shortName, ...value }) => ({
    ...value,
    shortName: shortName ?? defaultShortName(value.name),
  }));
const rules = z
  .object({
    bestOf: z.union([z.literal(3), z.literal(5)]),
    pointsToWin: z.number().int().min(1).max(99),
    decidingPointsToWin: z.number().int().min(1).max(99),
    winBy: z.number().int().min(1).max(10),
    pointCap: z.number().int().max(199).nullable(),
  })
  .strict()
  .refine(
    (value) =>
      value.pointCap === null ||
      value.pointCap >= Math.max(value.pointsToWin, value.decidingPointsToWin),
    { message: 'Point cap must be at least both set targets' },
  );
const create = z
  .object({
    id: id.refine((value) => value !== 'active', { message: 'Reserved match ID' }),
    deviceId: id,
    teams: z.object({ home: team, away: team }).strict(),
    rules,
    scorebugStyle: z.enum(SCOREBUG_STYLES).optional(),
    /** Stream to this owner destination; omitted uses the default destination. */
    destinationId: z.uuid().optional(),
    /** No broadcast at all: the phone only records. */
    recordOnly: z.boolean().optional(),
  })
  .strict()
  .refine((value) => !(value.recordOnly && value.destinationId !== undefined), {
    message: 'recordOnly and destinationId are mutually exclusive',
  });
const operation = z.discriminatedUnion('type', [
  z.object({ type: z.literal('award_point'), side: z.enum(['home', 'away']) }).strict(),
  z.object({ type: z.literal('undo') }).strict(),
  z
    .object({
      type: z.literal('end_set'),
      winner: z.enum(['home', 'away']).optional(),
      overrideReason: z.string().trim().min(1).max(500).optional(),
    })
    .strict(),
  z.object({ type: z.literal('end_match'), reason: z.string().trim().min(1).max(500) }).strict(),
  z.object({ type: z.literal('take_over') }).strict(),
  z.object({ type: z.literal('set_scorebug_style'), style: z.enum(SCOREBUG_STYLES) }).strict(),
]);
const command = z
  .object({
    commandId: id,
    gameId: id,
    deviceId: id,
    expectedRevision: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
    scorerEpoch: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
    issuedAt: z.iso.datetime(),
    operation,
  })
  .strict();
type Env = { Variables: { credential: Omit<MatchCredential, 'token'> } };

/**
 * Who may create matches, read the active match and join one (bootstrap), who may mint
 * join codes, and what a join link looks like. The self-hosted server trusts enrolled owner
 * phones; the hosted TeamObject trusts the team member the Worker vouches for.
 */
export type MatchAccess = {
  /** Guards create / active / join and broadcast commands; 401 if absent. */
  bootstrap: MiddlewareHandler;
  /** Invite issuer for owner-level callers, else undefined. */
  issuer(c: Context): string | undefined;
  /** Null when the server has no public URL to build links from. */
  joinLink(code: string): string | null;
  /** Called after a join code is minted or revoked, so it can be routed elsewhere. */
  onInvite?: {
    issued(i: { inviteId: string; code: string; gameId: string; expiresAt: string }): Promise<void>;
    revoked(i: { inviteId: string; gameId: string }): Promise<void>;
  };
};

/** Today's self-hosted behavior: owner device tokens and scorebug:// join links. */
export function ownerAccess(config: Config, store: MatchStore): MatchAccess {
  return {
    bootstrap: ownerAuth(store.account),
    issuer: (c) => {
      const owner = resolveOwner(bearerToken(c), store.account);
      return owner ? `device:${owner.deviceId}` : undefined;
    },
    joinLink: (code) => (config.PUBLIC_URL ? protocolJoinLink(config.PUBLIC_URL, code) : null),
  };
}

export function matchesRoutes(
  config: Config,
  store: MatchStore,
  access: MatchAccess,
  relayLifecycle?: RelayLifecycle,
  observations?: WorkerObservations,
) {
  const app = new Hono<Env>();
  app.use('*', async (c, next) => {
    c.header('Cache-Control', 'no-store');
    await next();
  });
  const bootstrap = access.bootstrap;
  const scoped = createMiddleware<Env>(async (c, next) => {
    const token = c.req.header('authorization')?.match(/^Bearer (.+)$/i)?.[1] ?? '';
    const credential = store.authenticate(c.req.param('id') ?? '', token);
    if (!credential) return c.json({ error: 'unauthorized' }, 401);
    c.set('credential', credential);
    await next();
  });
  app.post('/', bootstrap, zValidator('json', create), (c) => {
    const body = c.req.valid('json');
    const snapshot = store.create(body);
    const credential = store.issueCredential(snapshot.id, body.deviceId, 'score');
    return c.json({ snapshot, credential, serverTime: new Date().toISOString() }, 201);
  });
  app.get('/active', bootstrap, (c) =>
    c.json({ snapshot: store.active() ?? null, serverTime: new Date().toISOString() }),
  );
  app.post(
    '/:id/join',
    bootstrap,
    zValidator('json', z.object({ deviceId: id, role: z.enum(['score', 'capture']) }).strict()),
    (c) => {
      const body = c.req.valid('json');
      const credential = store.issueCredential(c.req.param('id'), body.deviceId, body.role);
      return c.json({
        credential,
        snapshot: store.get(credential.gameId),
        serverTime: new Date().toISOString(),
      });
    },
  );
  app.get('/:id', scoped, (c) =>
    c.json({ snapshot: store.get(c.req.param('id')), serverTime: new Date().toISOString() }),
  );
  app.post('/:id/commands', scoped, zValidator('json', command), (c) => {
    const body = c.req.valid('json');
    const credential = c.get('credential');
    if (
      credential.role !== 'score' ||
      body.deviceId !== credential.deviceId ||
      body.gameId !== credential.gameId
    )
      return c.json({ error: 'forbidden' }, 403);
    const outcome = store.execute(body);
    return c.json(outcome, outcome.accepted ? 200 : 409);
  });
  app.get('/:id/commands/:commandId', scoped, (c) => {
    const credential = c.get('credential');
    if (credential.role !== 'score') return c.json({ error: 'forbidden' }, 403);
    const outcome = store.receipt(credential.gameId, credential.deviceId, c.req.param('commandId'));
    return outcome ? c.json(outcome) : c.json({ error: 'command_not_found' }, 404);
  });
  app.route('/:id/invites', inviteRoutes(store, access));
  app.route('/:id/media', mediaRoutes(config, store, bootstrap, relayLifecycle, observations));
  app.onError((error, c) => {
    if (error instanceof MatchStoreError)
      return c.json(
        { error: error.code, snapshot: store.active() ?? null },
        error.code === 'match_not_found' ? 404 : 409,
      );
    throw error;
  });
  return app;
}
