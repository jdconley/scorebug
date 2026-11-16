import { beforeEach, expect, it } from 'vitest';
import { harness, ownerWithTeam, type Harness } from './helpers.js';

let h: Harness;
beforeEach(() => {
  h = harness();
});

const cookieValue = (setCookie: string, name: string) =>
  setCookie.match(new RegExp(`${name}=([^;]*)`))?.[1] ?? '';

/** GET /admin → Google → callback, as a browser carrying the verifier cookie. */
async function adminSignIn(email: string, opts: { dropVerifier?: boolean } = {}) {
  const page = await h.call('/admin');
  expect(page.status).toBe(302);
  const start = new URL(page.headers.get('location')!, 'https://scorebug.live');
  expect(start.pathname).toBe('/v1/auth/google/start');
  expect(start.searchParams.get('purpose')).toBe('admin');
  const verifier = cookieValue(page.headers.get('set-cookie') ?? '', 'sb_admin_verifier');
  expect(verifier).not.toBe('');
  const google = await h.call(`${start.pathname}${start.search}`);
  const state = new URL(google.headers.get('location')!).searchParams.get('state')!;
  const code = h.google.grant({ email });
  return h.call(`/v1/auth/google/callback?${new URLSearchParams({ code, state })}`, {
    headers: opts.dropVerifier ? {} : { cookie: `sb_admin_verifier=${verifier}` },
  });
}

async function adminCookie(email = 'admin@example.com') {
  const response = await adminSignIn(email);
  expect(response.status).toBe(200);
  return `sb_admin=${cookieValue(response.headers.get('set-cookie') ?? '', 'sb_admin')}`;
}

const form = (cookie: string, body: Record<string, string>, origin = 'https://scorebug.live') =>
  h.call('/admin/beta', {
    method: 'POST',
    headers: { cookie, origin, 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
  });

it('non-admin is refused', async () => {
  const response = await adminSignIn('someone@example.com');
  expect(response.status).toBe(403);
  expect(response.headers.get('set-cookie') ?? '').not.toContain('sb_admin=');
  expect((await h.call('/admin', { headers: { cookie: 'sb_admin=forged' } })).status).toBe(302);
});

it('admin sign-in needs the browser that started it', async () => {
  const response = await adminSignIn('admin@example.com', { dropVerifier: true });
  expect(response.status).toBe(403);
});

it('an app session token is not an admin cookie', async () => {
  await ownerWithTeam(h, 'admin@example.com');
  const { token } = await h.signIn('admin@example.com');
  expect((await h.call('/admin', { headers: { cookie: `sb_admin=${token}` } })).status).toBe(302);
});

it('admin adds an email', async () => {
  const cookie = await adminCookie();
  const added = await form(cookie, { email: ' New.Coach@Example.com ', canCreateTeams: 'on' });
  expect(added.status).toBe(303);
  expect(added.headers.get('location')).toBe('/admin');
  const page = await h.call('/admin', { headers: { cookie } });
  expect(page.status).toBe(200);
  expect(page.headers.get('content-type')).toContain('text/html');
  const html = await page.text();
  expect(html).toContain('new.coach@example.com');
  const { redirect } = await h.callback('new.coach@example.com');
  expect(redirect.searchParams.get('status')).toBe('ok');
});

it('admin removes an email and sees teams', async () => {
  const owner = await ownerWithTeam(h, 'coach@example.com', 'Wildcats <b>');
  const cookie = await adminCookie();
  const before = await (await h.call('/admin', { headers: { cookie } })).text();
  expect(before).toContain('Wildcats &lt;b&gt;');
  expect(before).not.toContain('Wildcats <b>');
  const removed = await h.call('/admin/beta/remove', {
    method: 'POST',
    headers: {
      cookie,
      origin: 'https://scorebug.live',
      'content-type': 'application/x-www-form-urlencoded',
    },
    body: 'email=coach%40example.com',
  });
  expect(removed.status).toBe(303);
  const after = await (await h.call('/admin', { headers: { cookie } })).text();
  expect(after).not.toContain('<td>coach@example.com</td>');
  // Still a team member, so the person keeps getting in.
  expect(owner.teamId).toBeTruthy();
  const { redirect } = await h.callback('coach@example.com');
  expect(redirect.searchParams.get('status')).toBe('ok');
});

it('cross-origin post is refused', async () => {
  const cookie = await adminCookie();
  const response = await form(cookie, { email: 'x@example.com' }, 'https://evil.example');
  expect(response.status).toBe(403);
  const missing = await h.call('/admin/beta', {
    method: 'POST',
    headers: { cookie, 'content-type': 'application/x-www-form-urlencoded' },
    body: 'email=x%40example.com',
  });
  expect(missing.status).toBe(403);
  expect((await form('sb_admin=nope', { email: 'x@example.com' })).status).toBe(403);
});

it('cookie is scoped to /admin', async () => {
  const response = await adminSignIn('admin@example.com');
  const setCookie = response.headers.get('set-cookie') ?? '';
  const admin = setCookie.split(/,(?=\s*sb_)/).find((c) => c.trim().startsWith('sb_admin='))!;
  expect(admin).toContain('Path=/admin');
  expect(admin).toContain('HttpOnly');
  expect(admin).toContain('Secure');
  expect(admin).toContain('SameSite=Strict');
  expect(admin).toContain('Max-Age=43200');
});

it('the page keeps the Origin header on its own form posts', async () => {
  const cookie = await adminCookie();
  const page = await h.call('/admin', { headers: { cookie } });
  // no-referrer would make browsers send `Origin: null` on the form posts.
  expect(page.headers.get('referrer-policy')).toBe('same-origin');
});
