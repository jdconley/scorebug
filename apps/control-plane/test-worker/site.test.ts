import { env, SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { createWorkerApp } from '../src/worker/app.js';
import { FakeGoogle } from './fake-google.js';

const get = (path: string) => SELF.fetch(`https://scorebug.live${path}`, { redirect: 'manual' });

async function htmlPage(path: string, status = 200) {
  const response = await get(path);
  expect(response.status).toBe(status);
  expect(response.headers.get('content-type')).toMatch(/^text\/html; charset=utf-8/i);
  expect(response.headers.get('content-security-policy')).toContain("default-src 'none'");
  expect(response.headers.get('x-content-type-options')).toBe('nosniff');
  return { response, body: await response.text() };
}

describe('home page', () => {
  it('says what Scorebug is and links to the policies', async () => {
    const { body } = await htmlPage('/');
    expect(body).toContain('Private beta');
    expect(body).toContain('Film on your iPhone');
    expect(body).toMatch(/Apple Watch/);
    expect(body).toMatch(/YouTube/);
    // Google verification follows these links from the home page.
    expect(body).toContain('href="/privacy"');
    expect(body).toContain('href="/terms"');
    expect(body).toContain('href="mailto:jd.conley@gmail.com?subject=Scorebug%20beta%20access"');
    expect(body).toContain('Request access');
    expect(body).toContain('href="/favicon.ico"');
    expect(body).toContain('href="/apple-touch-icon.png"');
  });
});

describe('privacy policy', () => {
  it('covers the operator, data, YouTube use, revocation and deletion', async () => {
    const { body } = await htmlPage('/privacy');
    expect(body).toContain('Privacy policy');
    expect(body).toContain('Conley Chaos LLC');
    expect(body).toMatch(/name, email address, profile picture/);
    expect(body).toContain('YouTube API Services');
    expect(body).toMatch(/live broadcasts/);
    expect(body).toContain('href="https://policies.google.com/privacy"');
    expect(body).toContain('href="https://myaccount.google.com/permissions"');
    expect(body).toContain('href="https://www.youtube.com/t/terms"');
    expect(body).toContain('Limited Use');
    expect(body).toMatch(/doesn't record or store the video/);
    expect(body).toContain('mailto:jd.conley@gmail.com');
  });
});

describe('terms of service', () => {
  it('covers the beta, the right to stream, YouTube terms, use and termination', async () => {
    const { body } = await htmlPage('/terms');
    expect(body).toContain('Terms of service');
    expect(body).toMatch(/free, invite-only beta/);
    expect(body).toMatch(/"as is"/);
    expect(body).toMatch(/right to film and stream/);
    expect(body).toMatch(/minors/);
    expect(body).toContain('href="https://www.youtube.com/t/terms"');
    expect(body).toContain('Acceptable use');
    expect(body).toContain('Ending access');
  });
});

describe('link pages', () => {
  it('shows a team invite with its code, TestFlight and request access', async () => {
    const { response, body } = await htmlPage('/invite/abcd-efgh');
    expect(body).toContain('Open in the Scorebug app');
    expect(body).toContain('ABCD-EFGH');
    expect(body).toContain('https://apps.apple.com/app/testflight/id899247664');
    expect(body).toContain('Request access');
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(response.headers.get('referrer-policy')).toBe('no-referrer');
    expect(response.headers.get('x-robots-tag')).toBe('noindex');
  });

  it('shows a match join link with its code', async () => {
    const { body } = await htmlPage('/join/ABCDEF');
    expect(body).toContain('Open in the Scorebug app');
    expect(body).toContain('ABC-DEF');
    expect(body).toContain('Keep score for a match');
  });

  it('says a malformed link is incomplete, without echoing it', async () => {
    const { body } = await htmlPage('/invite/%3Cscript%3E', 404);
    expect(body).toContain('complete. Ask');
    expect(body).not.toContain('<script>');
    const join = await htmlPage('/join/TOO-LONG-CODE', 404);
    expect(join.body).not.toContain('TOOLONGCODE');
  });
});

describe('apple-app-site-association', () => {
  it('serves applinks for invite and join paths as JSON', async () => {
    const response = await get('/.well-known/apple-app-site-association');
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toMatch(/^application\/json/);
    const body = (await response.json()) as {
      applinks: { details: { appIDs: string[]; components: { '/': string }[] }[] };
    };
    expect(body.applinks.details).toHaveLength(1);
    expect(body.applinks.details[0]!.appIDs).toEqual(['B222J9J7B8.live.scorebug.app']);
    expect(body.applinks.details[0]!.components.map((c) => c['/'])).toEqual([
      '/invite/*',
      '/join/*',
    ]);
  });
});

describe('static assets', () => {
  it.each([
    ['/favicon.ico', /^image\/(x-icon|vnd\.microsoft\.icon)/],
    ['/favicon-32.png', /^image\/png/],
    ['/apple-touch-icon.png', /^image\/png/],
    ['/icon-192.png', /^image\/png/],
    ['/icon-512.png', /^image\/png/],
    ['/fonts/BarlowCondensed-Bold.woff2', /^font\/woff2/],
  ])('serves %s', async (path, type) => {
    // Cloudflare serves files in public/ before the Worker runs; the test pool doesn't route
    // SELF through that layer, so ask the assets binding directly.
    const response = await env.ASSETS.fetch(`https://scorebug.live${path}`);
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toMatch(type);
    expect((await response.arrayBuffer()).byteLength).toBeGreaterThan(500);
  });
});

it('keeps the existing routes', async () => {
  expect((await get('/healthz')).status).toBe(200);
  const me = await get('/v1/me');
  expect(me.status).toBe(401);
  expect((await get('/admin')).status).toBe(302);
  const missing = await get('/nope');
  expect(missing.status).toBe(404);
  expect(await missing.json()).toEqual({ error: 'not_found' });
});

it('serves the public pages even when SERVER_SECRET is missing', async () => {
  const weak = { ...env, SERVER_SECRET: '' };
  const app = createWorkerApp({ env: weak, google: new FakeGoogle() });
  for (const path of ['/', '/privacy', '/terms', '/invite/ABCDEFGH'])
    expect((await app.fetch(new Request(`https://scorebug.live${path}`), weak)).status).toBe(200);
  const me = await app.fetch(new Request('https://scorebug.live/v1/me'), weak);
  expect(me.status).toBe(503);
});
