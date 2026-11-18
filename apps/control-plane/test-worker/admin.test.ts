import { beforeEach, expect, it } from 'vitest';
import { count, harness, ownerWithTeam, type Harness } from './helpers.js';

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

it('non-admin is refused', async () => {
  const response = await adminSignIn('someone@example.com');
  expect(response.status).toBe(403);
  expect(response.headers.get('set-cookie') ?? '').not.toContain('sb_admin=');
  expect((await h.call('/admin', { headers: { cookie: 'sb_admin=forged' } })).status).toBe(302);
  // An admin sign-in by anyone else stores nothing.
  expect(await count('people')).toBe(0);
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

it('admin sees every team, escaped', async () => {
  await ownerWithTeam(h, 'coach@example.com', 'Wildcats <b>');
  const cookie = await adminCookie();
  const page = await h.call('/admin', { headers: { cookie } });
  expect(page.status).toBe(200);
  expect(page.headers.get('content-type')).toContain('text/html');
  const html = await page.text();
  expect(html).toContain('<h1>Scorebug admin</h1>');
  expect(html).toContain('Teams (1)');
  expect(html).toContain('Wildcats &lt;b&gt;');
  expect(html).not.toContain('Wildcats <b>');
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

it('the page sends its security headers', async () => {
  const cookie = await adminCookie();
  const page = await h.call('/admin', { headers: { cookie } });
  expect(page.headers.get('content-security-policy')).toContain("default-src 'none'");
  expect(page.headers.get('cache-control')).toBe('no-store');
  expect(page.headers.get('referrer-policy')).toBe('no-referrer');
});
