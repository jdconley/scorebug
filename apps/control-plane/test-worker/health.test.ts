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
    'match_codes',
    'match_index',
    'memberships',
    'people',
    'sessions',
    'team_invites',
    'teams',
  ]);
});
