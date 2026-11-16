import { Hono } from 'hono';
import type { AppEnv, Env } from './env.js';
import type { GoogleOAuth } from './google.js';

export type WorkerDeps = { env: Env; google: GoogleOAuth; now?: () => number };

export function createWorkerApp(_deps: WorkerDeps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  app.use('*', async (c, next) => {
    await next();
    if (c.res.headers.get('content-type')?.startsWith('application/json'))
      c.header('Cache-Control', 'no-store');
  });
  app.get('/healthz', (c) => c.json({ ok: true }));
  app.notFound((c) => c.json({ error: 'not_found' }, 404));
  app.onError((error, c) => {
    console.error('unhandled_error', String(error));
    return c.json({ error: 'internal' }, 500);
  });
  return app;
}
