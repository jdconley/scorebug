import { env, SELF } from 'cloudflare:test';
import { expect, it } from 'vitest';

it('serves the health check', async () => {
  const response = await SELF.fetch('https://scorebug.live/healthz');
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ ok: true });
  expect(response.headers.get('cache-control')).toBe('no-store');
});

it('applies the D1 schema', async () => {
  const { results } = await env.DB.prepare(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE '\\_%' ESCAPE '\\' AND name NOT LIKE 'd1_%' AND name NOT LIKE 'sqlite_%' ORDER BY name",
  ).all<{ name: string }>();
  expect(results.map((r) => r.name)).toEqual([
    'auth_tickets',
    'beta_access',
    'live_slots',
    'match_codes',
    'match_index',
    'memberships',
    'people',
    'sessions',
    'team_invites',
    'teams',
    'youtube_connections',
    'youtube_grants',
  ]);
});

it('refuses to serve with a short SERVER_SECRET', async () => {
  const { createWorkerApp } = await import('../src/worker/app.js');
  const { FakeGoogle } = await import('./fake-google.js');
  const weak = { ...env, SERVER_SECRET: 'too-short' };
  const app = createWorkerApp({ env: weak, google: new FakeGoogle() });
  const me = await app.fetch(new Request('https://scorebug.live/v1/me'), weak);
  expect(me.status).toBe(503);
  expect(await me.json()).toEqual({ error: 'server_misconfigured' });
  const health = await app.fetch(new Request('https://scorebug.live/healthz'), weak);
  expect(health.status).toBe(200);
});
