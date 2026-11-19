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

const APP_STORE_URL = 'https://apps.apple.com/app/scorebug/id1234567890';

/** The site as served once APP_STORE_URL is set. */
async function withAppStore(path: string) {
  const live = { ...env, APP_STORE_URL };
  const app = createWorkerApp({ env: live, google: new FakeGoogle() });
  return (await app.fetch(new Request(`https://scorebug.live${path}`), live)).text();
}

const BETA_WORDS = /beta|invite-only|request access|testflight/i;

describe('home page', () => {
  it('says what Scorebug is and links to the policies', async () => {
    const { body } = await htmlPage('/');
    expect(body).toContain('Scorebug is free');
    expect(body).toContain('Film on your iPhone');
    expect(body).toMatch(/Apple Watch/);
    expect(body).toMatch(/YouTube/);
    // Google verification follows these links from the home page.
    expect(body).toContain('href="/privacy"');
    expect(body).toContain('href="/terms"');
    expect(body).toContain('href="/support"');
    expect(body).toContain('href="/favicon.ico"');
    expect(body).toContain('href="/apple-touch-icon.png"');
    expect(body).not.toMatch(BETA_WORDS);
  });

  it('shows the stream, the app and the styles from public/media', async () => {
    const { response, body } = await htmlPage('/');
    expect(response.headers.get('content-security-policy')).toContain("media-src 'self'");
    const media = [...body.matchAll(/\/media\/([\w@-]+\.\w+)/g)].map((m) => m[1]);
    expect(new Set(media)).toEqual(
      new Set([
        'stream.mp4',
        'stream.jpg',
        'app.mp4',
        'app.jpg',
        'watch.webp',
        'watch.png',
        ...['app-live', 'app-scorer', 'style-bar', 'style-lowerThird', 'style-setCard'].flatMap(
          (name) => ['webp', 'jpg'].flatMap((ext) => [`${name}.${ext}`, `${name}@2x.${ext}`]),
        ),
      ]),
    );
    expect(body).toMatch(/<video[^>]*src="\/media\/stream\.mp4"[^>]*muted/);
    expect(body).toContain('content="https://scorebug.live/media/stream.jpg"');
  });

  it('says Coming soon until the App Store link is set', async () => {
    const { body } = await htmlPage('/');
    expect(body).toContain('Coming soon to the App Store');
    expect(body).not.toContain('apps.apple.com');
  });

  it('links to the App Store once it is set', async () => {
    const body = await withAppStore('/');
    expect(body).toContain(
      `<a class="button" href="${APP_STORE_URL}">Get Scorebug on the App Store</a>`,
    );
    expect(body).not.toContain('Coming soon');
  });
});

describe('support page', () => {
  it('answers what you need, second-phone scoring, deletion and contact', async () => {
    const { body } = await htmlPage('/support');
    expect(body).toContain('Support');
    expect(body).toMatch(/iPhone/);
    expect(body).toMatch(/Apple Watch/);
    expect(body).toMatch(/up to 24 hours/);
    expect(body).toContain('href="https://www.youtube.com/features"');
    expect(body).toContain('Invite scorer');
    expect(body).toContain('Join with a code');
    expect(body).toContain('<strong>Delete account</strong>');
    expect(body).toMatch(/within 30\s+days/);
    expect(body).toContain('href="https://myaccount.google.com/permissions"');
    expect(body).toContain('mailto:jd.conley@gmail.com');
    expect(body).not.toMatch(BETA_WORDS);
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
    expect(body).toContain('<strong>Delete account</strong>');
    expect(body).toMatch(/longest-standing member becomes owner/);
    expect(body).toContain('mailto:jd.conley@gmail.com');
    expect(body).toContain('Last updated November 18, 2026');
    expect(body).not.toMatch(BETA_WORDS);
  });
});

describe('terms of service', () => {
  it('covers the free service, the right to stream, YouTube terms, use and termination', async () => {
    const { body } = await htmlPage('/terms');
    expect(body).toContain('Terms of service');
    expect(body).toContain('Scorebug is free.');
    expect(body).toMatch(/may change, break, or stop/);
    expect(body).toMatch(/post the new version on this page/);
    expect(body).not.toMatch(BETA_WORDS);
    expect(body).toMatch(/"as is"/);
    expect(body).toMatch(/right to film and stream/);
    expect(body).toMatch(/minors/);
    expect(body).toContain('href="https://www.youtube.com/t/terms"');
    expect(body).toContain('Acceptable use');
    expect(body).toContain('Ending access');
  });
});

describe('link pages', () => {
  it('shows a team invite with its code and where to get the app', async () => {
    const { response, body } = await htmlPage('/invite/abcd-efgh');
    expect(body).toContain('Open in the Scorebug app');
    expect(body).toContain('ABCD-EFGH');
    expect(body).toContain('Coming soon to the App Store');
    expect(body).not.toMatch(BETA_WORDS);
    expect(await withAppStore('/invite/abcd-efgh')).toContain('Get Scorebug on the App Store');
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(response.headers.get('referrer-policy')).toBe('no-referrer');
    expect(response.headers.get('x-robots-tag')).toBe('noindex');
  });

  it('shows a match join link with its code', async () => {
    const { body } = await htmlPage('/join/ABCDEF');
    expect(body).toContain('Open in the Scorebug app');
    expect(body).toContain('ABC-DEF');
    expect(body).toContain('Keep score for a match');
    expect(await withAppStore('/join/ABCDEF')).toContain(`href="${APP_STORE_URL}"`);
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
  for (const path of ['/', '/support', '/privacy', '/terms', '/invite/ABCDEFGH'])
    expect((await app.fetch(new Request(`https://scorebug.live${path}`), weak)).status).toBe(200);
  const me = await app.fetch(new Request('https://scorebug.live/v1/me'), weak);
  expect(me.status).toBe(503);
});

describe('media clips', () => {
  it('answers byte ranges, which Safari needs to play video', async () => {
    const whole = await get('/media/stream.mp4');
    expect(whole.status).toBe(200);
    expect(whole.headers.get('accept-ranges')).toBe('bytes');
    const size = (await whole.arrayBuffer()).byteLength;
    expect(size).toBeGreaterThan(1000);

    const first = await SELF.fetch('https://scorebug.live/media/stream.mp4', {
      headers: { Range: 'bytes=0-1' },
    });
    expect(first.status).toBe(206);
    expect(first.headers.get('content-range')).toBe(`bytes 0-1/${size}`);
    expect((await first.arrayBuffer()).byteLength).toBe(2);

    const open = await SELF.fetch('https://scorebug.live/media/stream.mp4', {
      headers: { Range: 'bytes=100-' },
    });
    expect(open.headers.get('content-range')).toBe(`bytes 100-${size - 1}/${size}`);
    await open.arrayBuffer();

    const past = await SELF.fetch('https://scorebug.live/media/stream.mp4', {
      headers: { Range: `bytes=${size}-` },
    });
    expect(past.status).toBe(416);
    await past.arrayBuffer();
  });

  it('404s a clip that does not exist', async () => {
    const response = await get('/media/nope.mp4');
    expect(response.status).toBe(404);
    await response.arrayBuffer();
  });
});
