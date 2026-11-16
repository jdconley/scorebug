import { WorkerObservations } from './worker-observations.js';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import type { Config } from './config.js';
import { createLogger, type Logger } from './logger.js';
import { MatchStore } from './matches-store.js';
import { openNodeSqlite } from './sql-node.js';
import { matchesRoutes, ownerAccess } from './routes/matches.js';
import { workerRoutes } from './routes/media.js';
import { IngestRelay } from './ingest.js';
import { RelayLifecycle, type RelayAdapter } from './relay-lifecycle.js';
import { RedeemGuard } from './rate-limit.js';
import {
  destinationRoutes,
  deviceRoutes,
  inviteRedeemRoutes,
  setupRoutes,
} from './routes/account.js';

export type AppDeps = {
  config: Config;
  observations: WorkerObservations;
  log: Logger;
  matches: MatchStore;
  relay: RelayAdapter | undefined;
  relayLifecycle: RelayLifecycle | undefined;
  /** Brute-force limits for unauthenticated setup-code and invite-code redemption. */
  setupGuard: RedeemGuard;
  inviteGuard: RedeemGuard;
};

export function createApp(
  config: Config,
  overrides: Partial<AppDeps> = {},
): AppDeps & { app: Hono } {
  const log = overrides.log ?? createLogger(config.LOG_LEVEL);
  const matches =
    overrides.matches ?? new MatchStore(openNodeSqlite(config.DATABASE_PATH), config.SERVER_SECRET);
  const observations = overrides.observations ?? new WorkerObservations(matches.media);
  const relay =
    overrides.relay ??
    (config.RELAY_API_URL
      ? new IngestRelay({
          apiUrl: config.RELAY_API_URL,
          username: config.RELAY_API_USERNAME!,
          password: config.RELAY_API_PASSWORD!,
        })
      : undefined);
  const relayLifecycle =
    overrides.relayLifecycle ??
    (relay
      ? new RelayLifecycle(
          relay,
          {
            installationSecret: config.SERVER_SECRET,
            host: config.INGEST_HOST,
            port: config.INGEST_PORT,
            ...(config.INGEST_PUBLISH_HOST === undefined
              ? {}
              : {
                  publishEndpoint: {
                    host: config.INGEST_PUBLISH_HOST,
                    port: config.INGEST_PUBLISH_PORT!,
                  },
                }),
            ...(config.SRT_PUBLISH_PACING === undefined
              ? {}
              : { publishPacing: config.SRT_PUBLISH_PACING }),
            ...(config.SRT_PUBLISH_PEER_LATENCY_MS === undefined
              ? {}
              : { publishPeerLatencyMs: config.SRT_PUBLISH_PEER_LATENCY_MS }),
          },
          () => {
            const match = matches.active();
            if (!match) return null;
            const broadcast = matches.media.get(match.id).broadcast;
            return broadcast.desired === 'running' && broadcast.selection
              ? {
                  gameId: match.id,
                  generation: broadcast.generation,
                  selection: broadcast.selection,
                }
              : null;
          },
        )
      : undefined);

  const setupGuard = overrides.setupGuard ?? new RedeemGuard();
  const inviteGuard = overrides.inviteGuard ?? new RedeemGuard();
  const app = new Hono();

  const origins = config.CORS_ORIGINS.split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  app.use(
    '*',
    cors({
      origin: origins.includes('*') ? '*' : origins,
      allowMethods: ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
      allowHeaders: ['authorization', 'content-type'],
      maxAge: 600,
    }),
  );

  app.get('/healthz', (c) => c.json({ ok: true }));

  app.route(
    '/v1/matches',
    matchesRoutes(config, matches, ownerAccess(config, matches), relayLifecycle, observations),
  );
  app.route('/v1/worker', workerRoutes(config, matches, relayLifecycle, observations));
  app.route('/v1/setup', setupRoutes(config, matches, setupGuard));
  app.route('/v1/devices', deviceRoutes(config, matches));
  app.route('/v1/destinations', destinationRoutes(config, matches));
  app.route('/v1/invites', inviteRedeemRoutes(matches, inviteGuard));

  app.onError((err, c) => {
    log.error('unhandled_error', { msg: String(err) });
    return c.json({ error: 'internal' }, 500);
  });

  return {
    app,
    config,
    log,
    matches,
    relay,
    relayLifecycle,
    observations,
    setupGuard,
    inviteGuard,
  };
}
