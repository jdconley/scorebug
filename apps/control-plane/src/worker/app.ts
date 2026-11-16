import { Hono } from 'hono';
import { adminCallback, adminRoutes } from './admin-page.js';
import { authRoutes, meRoutes } from './auth-routes.js';
import { Directory } from './directory.js';
import type { AppEnv, Env } from './env.js';
import type { GoogleOAuth } from './google.js';
import { matchForwardingRoutes } from './match-forwarding.js';
import { teamInviteRoutes, teamRoutes } from './team-routes.js';

export type WorkerDeps = { env: Env; google: GoogleOAuth; now?: () => number };

export function createWorkerApp(deps: WorkerDeps): Hono<AppEnv> {
  const now = deps.now ?? Date.now;
  const app = new Hono<AppEnv>();
  app.use('*', async (c, next) => {
    c.set('directory', new Directory(c.env.DB, now));
    await next();
    if (c.res.headers.get('content-type')?.startsWith('application/json'))
      c.header('Cache-Control', 'no-store');
  });
  app.get('/healthz', (c) => c.json({ ok: true }));
  app.route('/v1/auth', authRoutes(deps.google, adminCallback));
  app.route('/admin', adminRoutes());
  app.route('/v1/me', meRoutes());
  app.route('/', matchForwardingRoutes());
  app.route('/v1/teams', teamRoutes());
  app.route('/v1/team-invites', teamInviteRoutes());
  app.notFound((c) => c.json({ error: 'not_found' }, 404));
  app.onError((error, c) => {
    console.error('unhandled_error', String(error));
    return c.json({ error: 'internal' }, 500);
  });
  return app;
}
