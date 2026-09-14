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

export type AppDeps = {
  config: Config;
  store: GameStore;
  bus: HomeBus;
  log: Logger;
  matches: MatchStore;
};

export function createApp(
  config: Config,
  overrides: Partial<AppDeps> = {},
): AppDeps & { app: Hono } {
  const log = overrides.log ?? createLogger(config.LOG_LEVEL);
  const store = overrides.store ?? new GameStore();
  const bus = overrides.bus ?? new HomeBus(log);
  const matches = overrides.matches ?? new MatchStore(config.DATABASE_PATH, config.PHONE_TOKEN);

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
  app.route('/v1/matches', matchesRoutes(config, matches));
  app.route('/internal', internalRoutes({ config, store, log }));

  app.onError((err, c) => {
    log.error('unhandled_error', { msg: String(err) });
    return c.json({ error: 'internal' }, 500);
  });

  return { app, config, store, bus, log, matches };
}
