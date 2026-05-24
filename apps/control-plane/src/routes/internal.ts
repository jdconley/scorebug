import { Hono } from 'hono';
import { bearer } from '../auth.js';
import type { Config } from '../config.js';
import type { Logger } from '../logger.js';
import type { GameStore } from '../state.js';

/**
 * MediaMTX webhook target. `runOnReady` curls here when a path becomes ready.
 * Body shape is whatever MediaMTX sends; we only need the path name to find the game.
 */
export function internalRoutes(deps: { config: Config; store: GameStore; log: Logger }) {
  const { config, store, log } = deps;
  const app = new Hono();
  app.use('*', bearer(config.INTERNAL_TOKEN, 'internal'));

  app.post('/stream-ready', async (c) => {
    const body = await c.req.json().catch(() => ({}) as Record<string, unknown>);
    const path = typeof body.path === 'string' ? body.path : undefined;
    const gameId = path?.replace(/^game_/, '');
    if (!gameId) {
      log.warn('stream_ready_missing_path', { body });
      return c.json({ ok: false }, 400);
    }
    const s = store.get(gameId);
    if (!s) {
      log.warn('stream_ready_unknown_game', { gameId });
      return c.json({ ok: false }, 404);
    }
    store.setStatus(gameId, 'live');
    log.info('stream_ready', { gameId });
    return c.json({ ok: true });
  });

  return app;
}
