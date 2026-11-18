import { env } from 'cloudflare:test';
import { beforeEach, expect, it } from 'vitest';
import { count, harness, pkce, type Harness } from './helpers.js';

let h: Harness;
beforeEach(() => {
  h = harness();
});

it('full sign-in issues a session', async () => {
  const { verifier, challenge } = await pkce();
  const start = await h.call(`/v1/auth/google/start?challenge=${challenge}`);
  expect(start.status).toBe(302);
  const authorize = h.google.authorizeCalls.at(-1)!;
  expect(authorize.scopes).toEqual(['openid', 'email', 'profile']);
  expect(authorize.prompt).toBe('select_account');
  expect(authorize.redirectUri).toBe('https://scorebug.live/v1/auth/google/callback');

  const { redirect } = await h.callback('coach@example.com', { challenge });
  expect(`${redirect.protocol}//${redirect.host}`).toBe('scorebug://auth');
  expect(redirect.searchParams.get('status')).toBe('ok');
  const session = await h.json('/v1/auth/session', {
    ticket: redirect.searchParams.get('ticket'),
    verifier,
    deviceName: 'iPhone',
  });
  expect(session.status).toBe(200);
  const body = (await session.json()) as { token: string; person: { email: string } };
  expect(body.person.email).toBe('coach@example.com');
  expect(body.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
  const stored = await env.DB.prepare('SELECT token_hash FROM sessions').first<{
    token_hash: string;
  }>();
  expect(stored?.token_hash).toMatch(/^[a-f0-9]{64}$/);
  expect(stored?.token_hash).not.toContain(body.token);

  const me = await h.call('/v1/me', { headers: h.auth(body.token) });
  expect(me.status).toBe(200);
  expect(me.headers.get('cache-control')).toBe('no-store');
  expect(await me.json()).toMatchObject({
    person: { email: 'coach@example.com' },
    teams: [],
  });
});

it('any verified Google account signs in, with no invite', async () => {
  const { redirect } = await h.callback('stranger@example.com');
  expect(redirect.searchParams.get('status')).toBe('ok');
  expect(redirect.searchParams.get('ticket')).toMatch(/^[A-Za-z0-9_-]{43}$/);
  expect(await count('people')).toBe(1);
});

it('stores mixed-case Google emails normalized', async () => {
  const { redirect } = await h.callback('  Parent@Example.COM');
  expect(redirect.searchParams.get('status')).toBe('ok');
  const { token } = await h.signIn('Parent@Example.com');
  const me = await h.call('/v1/me', { headers: h.auth(token) });
  expect(await me.json()).toMatchObject({ person: { email: 'parent@example.com' } });
});

it('rejects unverified email', async () => {
  const { redirect } = await h.callback('coach@example.com', { emailVerified: false });
  expect(redirect.toString()).toBe('scorebug://auth?status=error');
  expect(await count('people')).toBe(0);
  expect(await count('auth_tickets')).toBe(0);
});

it('cancelled consent redirects to app', async () => {
  const start = await h.call(`/v1/auth/google/start?challenge=${(await pkce()).challenge}`);
  const state = new URL(start.headers.get('location')!).searchParams.get('state')!;
  const response = await h.call(`/v1/auth/google/callback?error=access_denied&state=${state}`);
  expect(response.status).toBe(302);
  expect(response.headers.get('location')).toBe('scorebug://auth?status=cancelled');
});

it('tampered state is rejected', async () => {
  const start = await h.call(`/v1/auth/google/start?challenge=${(await pkce()).challenge}`);
  const state = new URL(start.headers.get('location')!).searchParams.get('state')!;
  const [payload, mac] = state.split('.');
  const tampered = `${payload!.slice(0, -2)}AA.${mac}`;
  const code = h.google.grant({ email: 'coach@example.com' });
  const response = await h.call(`/v1/auth/google/callback?code=${code}&state=${tampered}`);
  expect(response.headers.get('location')).toBe('scorebug://auth?status=error');
  expect(await count('people')).toBe(0);
});

it('start rejects a malformed challenge', async () => {
  const response = await h.call('/v1/auth/google/start?challenge=short');
  expect(response.status).toBe(400);
});

it('ticket is single use', async () => {
  const { verifier, challenge } = await pkce();
  const { redirect } = await h.callback('coach@example.com', { challenge });
  const ticket = redirect.searchParams.get('ticket');
  const first = await h.json('/v1/auth/session', { ticket, verifier, deviceName: 'iPhone' });
  expect(first.status).toBe(200);
  const second = await h.json('/v1/auth/session', { ticket, verifier, deviceName: 'iPhone' });
  expect(second.status).toBe(401);
  expect(await second.json()).toEqual({ error: 'ticket_invalid' });
});

it('ticket needs the matching verifier', async () => {
  const { challenge } = await pkce();
  const other = await pkce();
  const { redirect } = await h.callback('coach@example.com', { challenge });
  const response = await h.json('/v1/auth/session', {
    ticket: redirect.searchParams.get('ticket'),
    verifier: other.verifier,
    deviceName: 'iPhone',
  });
  expect(response.status).toBe(401);
  expect(await response.json()).toEqual({ error: 'ticket_invalid' });
});

it('ticket expires after 2 minutes', async () => {
  const { verifier, challenge } = await pkce();
  const { redirect } = await h.callback('coach@example.com', { challenge });
  h.clock.now += 121_000;
  const response = await h.json('/v1/auth/session', {
    ticket: redirect.searchParams.get('ticket'),
    verifier,
    deviceName: 'iPhone',
  });
  expect(response.status).toBe(401);
});

it('sign out revokes the token', async () => {
  const { token } = await h.signIn('coach@example.com');
  const out = await h.call('/v1/auth/session', { method: 'DELETE', headers: h.auth(token) });
  expect(out.status).toBe(204);
  const me = await h.call('/v1/me', { headers: h.auth(token) });
  expect(me.status).toBe(401);
});

it('me needs a session', async () => {
  expect((await h.call('/v1/me')).status).toBe(401);
  expect((await h.call('/v1/me', { headers: h.auth('nope') })).status).toBe(401);
});

it('a returning person keeps one people row', async () => {
  const first = await h.signIn('coach@example.com');
  const second = await h.signIn('coach@example.com');
  expect(second.personId).toBe(first.personId);
  expect(await count('people')).toBe(1);
});

it('auth routes are rate limited per client IP', async () => {
  const headers = { 'cf-connecting-ip': '203.0.113.77' };
  const statuses: number[] = [];
  for (let i = 0; i < 25; i++)
    statuses.push((await h.call('/v1/auth/google/start?challenge=x', { headers })).status);
  expect(statuses).toContain(429);
});
