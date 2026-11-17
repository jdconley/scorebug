import { Hono, type Context } from 'hono';
import { createMiddleware } from 'hono/factory';
import { bearerToken } from '../src/auth.js';
import type { RouteConfig } from '../src/config.js';
import type { IngestLifecycle } from '../src/media-lifecycle.js';
import { MatchStore } from '../src/matches-store.js';
import { RedeemGuard } from '../src/rate-limit.js';
import { inviteRedeemRoutes } from '../src/routes/invites.js';
import { matchesRoutes, type MatchAccess } from '../src/routes/matches.js';
import { workerRoutes } from '../src/routes/media.js';
import { WorkerObservations } from '../src/worker-observations.js';
import { openNodeSqlite } from './sqlite.js';

export const SERVER_SECRET = 'server-secret-1234567890abcdef';
/** The bearer token the test access treats as a signed-in team member. */
export const MEMBER_TOKEN = 'member-token-1234567890abcdef';

export function testConfig(overrides: Partial<RouteConfig> = {}): RouteConfig {
  return {
    workerToken: 'worker-token-1234567890abcdef',
    workerId: 'match',
    outputId: 'youtube',
    ...overrides,
  };
}

/** Team-member access the way the TeamObject grants it, keyed on MEMBER_TOKEN. */
export function memberAccess(onInvite?: MatchAccess['onInvite']): MatchAccess {
  const member = (c: Context) => (bearerToken(c) === MEMBER_TOKEN ? 'member:test' : undefined);
  return {
    bootstrap: createMiddleware(async (c, next) => {
      if (!member(c)) return c.json({ error: 'unauthorized', role: 'member' }, 401);
      await next();
    }),
    issuer: member,
    joinLink: (code) => `https://scorebug.test/join/${code}`,
    ...(onInvite ? { onInvite } : {}),
  };
}

/** An ingest with nothing behind it. The Worker tests cover the hosted one (HostedMedia). */
export const fakeIngest: IngestLifecycle = {
  publish: async (request) => ({
    gameId: request.gameId,
    generation: request.generation,
    recordingId: request.recordingId,
    publishUrl: 'srt://ingest.test:778?passphrase=test&streamid=test',
  }),
  worker: async () => null,
};

/** The match, invite and worker routes, composed as the TeamObject composes them. */
export function createTestApp(
  options: {
    config?: Partial<RouteConfig>;
    matches?: MatchStore;
    observations?: WorkerObservations;
    inviteGuard?: RedeemGuard;
  } = {},
) {
  const config = testConfig(options.config);
  const matches = options.matches ?? new MatchStore(openNodeSqlite(':memory:'), SERVER_SECRET);
  const observations = options.observations ?? new WorkerObservations(matches.media);
  const inviteGuard = options.inviteGuard ?? new RedeemGuard();
  const app = new Hono();
  app.route(
    '/v1/matches',
    matchesRoutes(config, matches, memberAccess(), fakeIngest, observations),
  );
  app.route('/v1/invites', inviteRedeemRoutes(matches, inviteGuard));
  app.route('/v1/worker', workerRoutes(config, matches, fakeIngest, observations));
  return { app, config, matches, observations, inviteGuard };
}

export function phoneAuth(token: string) {
  return { authorization: `Bearer ${token}` };
}
