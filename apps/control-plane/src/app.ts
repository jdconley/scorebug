import { WorkerObservations } from './worker-observations.js';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import type { Config } from './config.js';
import { HomeBus } from './home-bus.js';
import { createLogger, type Logger } from './logger.js';
import { GameStore } from './state.js';
import { gamesRoutes } from './routes/games.js';
import { internalRoutes } from './routes/internal.js';
import { MatchStore } from './matches-store.js';
import { matchesRoutes } from './routes/matches.js';
import { workerRoutes } from './routes/media.js';
import { IngestRelay } from './ingest.js';
import { RelayLifecycle, type RelayAdapter } from './relay-lifecycle.js';

export type AppDeps = {
  config: Config;
  observations: WorkerObservations;
  store: GameStore;
  bus: HomeBus;
  log: Logger;
  matches: MatchStore;
  relay: RelayAdapter | undefined;
  relayLifecycle: RelayLifecycle | undefined;
};

export function createApp(
  config: Config,
  overrides: Partial<AppDeps> = {},
): AppDeps & { app: Hono } {
  const log = overrides.log ?? createLogger(config.LOG_LEVEL);
  const store = overrides.store ?? new GameStore();
  const bus = overrides.bus ?? new HomeBus(log);
  const matches = overrides.matches ?? new MatchStore(config.DATABASE_PATH, config.PHONE_TOKEN);
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
            installationSecret: config.PHONE_TOKEN,
            host: config.INGEST_HOST,
            port: config.INGEST_PORT,
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

  const app = new Hono();

  const origins = config.CORS_ORIGINS.split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  app.use(
    '*',
    cors({
      origin: origins.includes('*') ? '*' : origins,
      allowMethods: ['GET', 'POST', 'OPTIONS'],
      allowHeaders: ['authorization', 'content-type'],
      maxAge: 600,
    }),
  );

  app.get('/healthz', (c) => c.json({ ok: true, home: bus.isConnected() }));

  app.route('/games', gamesRoutes({ config, store, bus, log }));
  app.route('/v1/matches', matchesRoutes(config, matches, relayLifecycle, observations));
  app.route('/v1/worker', workerRoutes(config, matches, relayLifecycle, observations));
  app.route('/internal', internalRoutes({ config, store, log }));

  app.onError((err, c) => {
    log.error('unhandled_error', { msg: String(err) });
    return c.json({ error: 'internal' }, 500);
  });

  return { app, config, store, bus, log, matches, relay, relayLifecycle, observations };
}
