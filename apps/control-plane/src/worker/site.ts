// Scorebug's public web pages on https://scorebug.live: the home page, support, the privacy
// policy and terms (both needed for Google's OAuth verification), landing pages for team invite
// and match join links, and the apple-app-site-association file that makes those links open the
// app.
// Server-rendered, no client JS. Fonts and icons are static assets in ../../public.
import { formatInviteCode, normalizeInviteCode } from '@scorebug/protocol';
import { Hono, type Context } from 'hono';
import { html, raw } from 'hono/html';
import type { HtmlEscapedString } from 'hono/utils/html';
import type { AppEnv } from './env.js';
import { privacyBody, termsBody } from './site-legal.js';
import { normalizeTeamInviteCode } from './state.js';

export const CONTACT_EMAIL = 'jd.conley@gmail.com';
export const APP_ID = 'B222J9J7B8.live.scorebug.app';
const YOUTUBE_FEATURES = 'https://www.youtube.com/features';
const GOOGLE_PERMISSIONS = 'https://myaccount.google.com/permissions';

type Body = HtmlEscapedString | Promise<HtmlEscapedString>;

const CSP =
  "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; media-src 'self'; font-src 'self'; " +
  "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

const PUBLIC_HEADERS = {
  'Content-Security-Policy': CSP,
  'Cache-Control': 'public, max-age=300',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'X-Content-Type-Options': 'nosniff',
};

// Link pages carry a code in the URL: don't cache them, index them or leak them in a Referer.
const LINK_HEADERS = {
  ...PUBLIC_HEADERS,
  'Cache-Control': 'no-store',
  'Referrer-Policy': 'no-referrer',
  'X-Robots-Tag': 'noindex',
};

// The app's colors (ios/Sources/Scorebug/UI/Theme.swift) and its Barlow Condensed display face.
const STYLE = raw(`
  @font-face { font-family: "Barlow Condensed"; font-weight: 700; font-display: swap;
    src: url(/fonts/BarlowCondensed-Bold.woff2) format("woff2"); }
  :root { color-scheme: dark; --ground: #0b0d10; --surface: #16191e; --raised: #1b1f25;
    --line: #262a30; --text: #f2f4f7; --secondary: #9aa3ae; --muted: #c9ced6; --live: #e5372c;
    --blue: #2563eb; --orange: #f97316; --link: #8fb4ff;
    --display: "Barlow Condensed", "Arial Narrow", system-ui, sans-serif; }
  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body { margin: 0; background: var(--ground); color: var(--text);
    font: 17px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  a { color: var(--link); text-underline-offset: 2px; }
  .wrap { max-width: 720px; margin: 0 auto; padding: 0 20px; }
  header.site { border-bottom: 1px solid var(--line); }
  header.site .wrap { display: flex; align-items: center; gap: 12px; height: 64px; }
  .brand { display: flex; align-items: center; gap: 10px; color: var(--text); text-decoration: none;
    font: 700 26px/1 var(--display); letter-spacing: 0.04em; text-transform: uppercase; }
  .brand img { width: 34px; height: 34px; border-radius: 8px; }
  main { padding: 36px 0 56px; }
  h1, h2, h3 { font-family: var(--display); font-weight: 700; line-height: 1.05;
    letter-spacing: 0.01em; margin: 0; }
  h1 { font-size: clamp(40px, 11vw, 64px); text-transform: uppercase; margin-bottom: 16px; }
  h2 { font-size: 30px; text-transform: uppercase; margin: 40px 0 12px; }
  h3 { font-size: 22px; margin: 28px 0 8px; }
  p, ul { margin: 0 0 14px; } ul { padding-left: 22px; } li { margin-bottom: 6px; }
  .lede { font-size: 19px; color: var(--muted); margin-bottom: 28px; }
  .muted { color: var(--secondary); }
  .button { display: flex; align-items: center; justify-content: center; min-height: 58px;
    padding: 0 24px; border-radius: 16px; background: var(--text); color: var(--ground);
    text-decoration: none; font: 700 22px/1 var(--display); letter-spacing: 0.06em;
    text-transform: uppercase; }
  .button.secondary { background: var(--raised); color: var(--text); border: 1px solid var(--line); }
  .button.soon { color: var(--secondary); }
  .actions { display: grid; gap: 12px; margin: 24px 0 12px; }
  @media (min-width: 560px) { .actions { grid-template-columns: 1fr 1fr; } }
  figure { margin: 0 0 28px; }
  figure img, figure video { display: block; width: 100%; height: auto; border-radius: 16px;
    border: 1px solid var(--line); background: var(--surface); }
  figcaption { margin-top: 8px; font-size: 15px; color: var(--secondary); }
  .phones { display: flex; justify-content: center; align-items: flex-end; gap: 14px; margin: 16px 0 4px; }
  .phones img { display: block; width: 100%; height: auto; border: 1px solid var(--line); }
  .phones .phone { flex: 0 1 220px; } .phones .phone img { border-radius: 26px; }
  .phones .watch { flex: 0 1 150px; } .phones .watch img { border-radius: 34px; }
  ol.steps .shot { margin-top: 14px; }
  ol.steps .shot img, ol.steps .shot video { display: block; width: 100%; height: auto;
    border-radius: 12px; border: 1px solid var(--line); }
  .styles { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
    margin: 16px 0 8px; }
  .styles figure { margin: 0; } .styles img { border-radius: 10px; }
  ol.steps { list-style: none; padding: 0; margin: 0 0 8px; display: grid; gap: 12px; }
  ol.steps li { display: flex; gap: 16px; align-items: flex-start; margin: 0; padding: 18px;
    min-width: 0;
    background: var(--surface); border: 1px solid var(--line); border-radius: 16px; }
  ol.steps li > div { flex: 1; min-width: 0; }
  ol.steps .n { flex: none; width: 40px; font: 700 40px/0.9 var(--display); color: var(--secondary); }
  ol.steps h3 { margin: 0 0 4px; font-size: 24px; text-transform: uppercase; }
  ol.steps p { margin: 0; color: var(--muted); }
  .code { display: inline-block; margin: 4px 0 8px; padding: 10px 16px; border-radius: 12px;
    background: var(--raised); border: 1px solid var(--line);
    font: 700 38px/1 var(--display); letter-spacing: 0.14em; }
  .legal h1 { font-size: clamp(36px, 10vw, 52px); margin-bottom: 6px; }
  .legal h2 { font-size: 26px; margin-top: 32px; }
  .faq h2 { font-size: 26px; margin-top: 32px; }
  footer.site { border-top: 1px solid var(--line); padding: 24px 0 40px; color: var(--secondary);
    font-size: 15px; }
  footer.site nav { display: flex; flex-wrap: wrap; gap: 6px 20px; margin-bottom: 10px; }
  footer.site nav a { color: var(--muted); }
`);

function page(c: Context, opts: { title: string; description: string; path: string }, body: Body) {
  const canonical = `${c.env.PUBLIC_URL}${opts.path}`;
  return html`<!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="theme-color" content="#0b0d10" />
        <title>${opts.title}</title>
        <meta name="description" content="${opts.description}" />
        <link rel="canonical" href="${canonical}" />
        <link rel="icon" href="/favicon.ico" sizes="48x48" />
        <link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32" />
        <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
        <meta property="og:title" content="${opts.title}" />
        <meta property="og:description" content="${opts.description}" />
        <meta property="og:image" content="${c.env.PUBLIC_URL}/media/stream.jpg" />
        <style>
          ${STYLE}
        </style>
      </head>
      <body>
        <header class="site">
          <div class="wrap">
            <a class="brand" href="/"
              ><img src="/icon-192.png" alt="" width="34" height="34" />Scorebug</a
            >
          </div>
        </header>
        <main><div class="wrap">${body}</div></main>
        <footer class="site">
          <div class="wrap">
            <nav>
              <a href="/">Home</a><a href="/support">Support</a><a href="/privacy">Privacy policy</a
              ><a href="/terms">Terms</a><a href="mailto:${CONTACT_EMAIL}">Contact</a>
            </nav>
            <div>© 2026 Conley Chaos LLC</div>
          </div>
        </footer>
      </body>
    </html>`;
}

/** The App Store button, or "Coming soon" until APP_STORE_URL is set. */
function appStoreButton(c: Context<AppEnv>) {
  const url = c.env.APP_STORE_URL?.trim();
  return url
    ? html`<a class="button" href="${url}">Get Scorebug on the App Store</a>`
    : html`<span class="button secondary soon">Coming soon to the App Store</span>`;
}

/**
 * An image from public/media (scripts/build-site-media.sh): WebP with a JPEG fallback, at 1x
 * and 2x. `width` and `height` are the 1x size, so the page doesn't jump while it loads.
 */
function picture(
  name: string,
  alt: string,
  width: number,
  height: number,
  type: 'jpg' | 'png' = 'jpg',
) {
  const src = (ext: string) => `/media/${name}.${ext} 1x, /media/${name}@2x.${ext} 2x`;
  return type === 'png'
    ? html`<picture
        ><source type="image/webp" srcset="/media/${name}.webp" />
        <img
          src="/media/${name}.png"
          alt="${alt}"
          width="${width}"
          height="${height}"
          loading="lazy"
      /></picture>`
    : html`<picture
        ><source type="image/webp" srcset="${src('webp')}" />
        <img
          src="/media/${name}.jpg"
          srcset="${src('jpg')}"
          alt="${alt}"
          width="${width}"
          height="${height}"
          loading="lazy"
      /></picture>`;
}

/** A silent looping clip from public/media. */
const clip = (name: string, label: string, width: number, height: number) =>
  html`<video
    src="/media/${name}.mp4"
    poster="/media/${name}.jpg"
    width="${width}"
    height="${height}"
    autoplay
    muted
    loop
    playsinline
    preload="metadata"
    aria-label="${label}"
  ></video>`;

const home = (c: Context<AppEnv>) =>
  page(
    c,
    {
      title: 'Scorebug: live volleyball on YouTube, with the score on screen',
      description:
        'Film youth volleyball on your iPhone, keep score on the phone, an Apple Watch or a second phone, and stream to YouTube with the score on screen.',
      path: '/',
    },
    html`<h1>Your games, live on YouTube, score on screen</h1>
      <p class="lede">
        Scorebug streams youth volleyball from an iPhone to your team's YouTube channel, with a live
        scoreboard on the video.
      </p>
      <figure>
        ${clip('stream', 'A volleyball court on a YouTube stream, with the Scorebug scoreboard counting up to 25–22', 1280, 720)}
        <figcaption>What your family sees on YouTube: the score is part of the video.</figcaption>
      </figure>
      <div class="actions">${appStoreButton(c)}</div>
      <ol class="steps">
        <li>
          <span class="n">1</span>
          <div>
            <h3>Film on your iPhone</h3>
            <p>
              Set the phone on a tripod courtside, name the teams and tap Go Live. Every match is
              also recorded on the phone, in 1080p or 4K.
            </p>
            <div class="shot">
              ${picture('app-live', 'Scorebug filming a match: live, with the score at the top', 640, 294)}
            </div>
          </div>
        </li>
        <li>
          <span class="n">2</span>
          <div>
            <h3>Keep score</h3>
            <p>
              Tap the left or right of the screen while you film, score from an Apple Watch, or hand
              scoring to a second phone in the stands. Scorebug checks with you before a set ends.
            </p>
            <div class="phones">
              <div class="phone">
                ${picture('app-scorer', 'A second phone keeping score: Wildcats 22, Mustangs 19', 220, 478)}
              </div>
              <div class="watch">
                ${picture('watch', 'The Apple Watch app: tap a team to add a point', 150, 183, 'png')}
              </div>
            </div>
          </div>
        </li>
        <li>
          <span class="n">3</span>
          <div>
            <h3>Go live on YouTube</h3>
            <p>
              Scorebug draws the score onto the video and streams it to the YouTube channel your
              team picks, as an unlisted broadcast. Share the watch link with a tap.
            </p>
            <div class="shot">
              ${clip('app', 'Scoring the end of a set in Scorebug while live', 1280, 591)}
            </div>
          </div>
        </li>
      </ol>
      <h2>Pick a scoreboard</h2>
      <p>Three looks for the stream, all in your team colors.</p>
      <div class="styles">
        <figure>
          ${picture('style-bar', 'A compact scoreboard in the top corner', 320, 180)}
          <figcaption>Bar</figcaption>
        </figure>
        <figure>
          ${picture('style-lowerThird', 'Team names and the score across the bottom', 320, 180)}
          <figcaption>Lower third</figcaption>
        </figure>
        <figure>
          ${picture('style-setCard', 'Every set’s score in the top corner', 320, 180)}
          <figcaption>Set card</figcaption>
        </figure>
      </div>
      <h2>Get Scorebug</h2>
      <p>
        Scorebug is free. You need an iPhone, a Google account, and a YouTube channel that can live
        stream. An Apple Watch is optional.
      </p>
      <div class="actions">${appStoreButton(c)}</div>
      <p class="muted">
        Questions? See <a href="/support">support</a>, the <a href="/privacy">privacy policy</a> and
        the <a href="/terms">terms of service</a>.
      </p>`,
  );

type LinkKind = 'invite' | 'join';

const LINK_COPY: Record<LinkKind, { title: string; what: string; invalid: string }> = {
  invite: {
    title: "You're invited to a team",
    what: 'This link adds you to a team on Scorebug, so you can film and keep score for its matches.',
    invalid: "This team invite link isn't complete. Ask the person who sent it for a new one.",
  },
  join: {
    title: 'Keep score for a match',
    what: 'This link lets you keep score for a match on Scorebug. You don’t need an account.',
    invalid: "This match link isn't complete. Ask the person filming for a new one.",
  },
};

const formatCode = (kind: LinkKind, code: string) =>
  kind === 'join' ? formatInviteCode(code) : `${code.slice(0, 4)}-${code.slice(4)}`;

function linkPage(c: Context<AppEnv>, kind: LinkKind, code: string | null) {
  const copy = LINK_COPY[kind];
  const body = code
    ? html`<h1>Open in the Scorebug app</h1>
        <p class="lede">${copy.what}</p>
        <p>
          With Scorebug installed, tapping the link opens it in the app. If it opened here instead,
          open Scorebug and enter this code:
        </p>
        <div class="code">${formatCode(kind, code)}</div>
        <h2>Don't have the app?</h2>
        <p>Scorebug is free on iPhone. Install it, then come back to this link.</p>
        <div class="actions">${appStoreButton(c)}</div>`
    : html`<h1>Open in the Scorebug app</h1>
        <p class="lede">${copy.invalid}</p>
        <div class="actions"><a class="button secondary" href="/">About Scorebug</a></div>`;
  return c.html(
    page(c, { title: `${copy.title} · Scorebug`, description: copy.what, path: `/${kind}` }, body),
    code ? 200 : 404,
    LINK_HEADERS,
  );
}

const support = (c: Context<AppEnv>) =>
  page(
    c,
    {
      title: 'Support · Scorebug',
      description:
        'What you need to stream with Scorebug, how a second phone keeps score, and how to delete your data.',
      path: '/support',
    },
    html`<article class="faq">
      <h1>Support</h1>
      <p class="lede">
        Answers to common questions. For anything else, email
        <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a>.
      </p>

      <h2>What do I need?</h2>
      <ul>
        <li>An iPhone to film, on a tripod courtside.</li>
        <li>A Google account to sign in.</li>
        <li>
          A YouTube channel with live streaming turned on. Turn it on at
          <a href="${YOUTUBE_FEATURES}">youtube.com/features</a> well before your first match: the
          first time, YouTube can take up to 24 hours to enable it.
        </li>
        <li>An Apple Watch, if you want to keep score from your wrist. It's optional.</li>
      </ul>

      <h2>Does it cost anything?</h2>
      <p>Scorebug is free. See the <a href="/terms">terms</a>.</p>

      <h2>Who can see the stream?</h2>
      <p>
        Matches go live on the YouTube channel your team picks, as unlisted broadcasts: anyone with
        the link can watch. You can change a broadcast's visibility in YouTube Studio.
      </p>

      <h2>How does a second phone keep score?</h2>
      <p>
        On the phone that's filming, tap <strong>Invite scorer</strong>. It shows a QR code and a
        short match code. Point the second phone's camera at the QR code, or open Scorebug on it,
        tap <strong>Join with a code</strong> and type the code. Scoring someone's match with a code
        needs no account, and the code works only for that match.
      </p>

      <h2>How do I add people to my team?</h2>
      <p>
        Team owners invite people from the team screen in the app, by email or with an invite link.
        People you invite can film, score and go live with the team.
      </p>

      <h2>How do I delete my account and data?</h2>
      <p>
        In the app, open Settings and tap <strong>Delete account</strong>. Your account, your
        YouTube connections and teams only you are on are deleted right away; teams with other
        people keep going without you. Recordings on your iPhone stay there. Can't use the app?
        Email <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a> from the address you sign in
        with, and we delete it within 30 days. You can also remove Scorebug's access to your Google
        account and YouTube channel at any time at
        <a href="${GOOGLE_PERMISSIONS}">myaccount.google.com/permissions</a>. The
        <a href="/privacy">privacy policy</a> has the details.
      </p>

      <h2>Contact</h2>
      <p>Conley Chaos LLC · <a href="mailto:${CONTACT_EMAIL}">${CONTACT_EMAIL}</a></p>
    </article>`,
  );

export function siteRoutes() {
  const site = new Hono<AppEnv>();
  site.get('/', (c) => c.html(home(c), 200, PUBLIC_HEADERS));
  site.get('/support', (c) => c.html(support(c), 200, PUBLIC_HEADERS));
  site.get('/privacy', (c) =>
    c.html(
      page(
        c,
        {
          title: 'Privacy policy · Scorebug',
          description: 'What Scorebug collects, how it uses YouTube, and how to remove your data.',
          path: '/privacy',
        },
        html`<article class="legal">${privacyBody(CONTACT_EMAIL)}</article>`,
      ),
      200,
      PUBLIC_HEADERS,
    ),
  );
  site.get('/terms', (c) =>
    c.html(
      page(
        c,
        {
          title: 'Terms of service · Scorebug',
          description: 'The terms for using Scorebug.',
          path: '/terms',
        },
        html`<article class="legal">${termsBody(CONTACT_EMAIL)}</article>`,
      ),
      200,
      PUBLIC_HEADERS,
    ),
  );
  site.get('/invite/:code', (c) =>
    linkPage(c, 'invite', normalizeTeamInviteCode(c.req.param('code'))),
  );
  site.get('/join/:code', (c) => linkPage(c, 'join', normalizeInviteCode(c.req.param('code'))));
  // Safari plays video only from byte ranges, which static assets don't answer, so the clips
  // come through here (wrangler.jsonc: run_worker_first for /media/*.mp4).
  site.get('/media/:file{[\\w-]+\\.mp4}', (c) => mediaClip(c));
  site.get('/.well-known/apple-app-site-association', (c) => c.json(appleAppSiteAssociation));
  return site;
}

/** A clip from public/media, whole or as the one byte range the request asks for. */
async function mediaClip(c: Context<AppEnv>) {
  const asset = await c.env.ASSETS.fetch(new URL(c.req.path, c.req.url));
  if (!asset.ok) return c.json({ error: 'not_found' }, 404);
  const body = new Uint8Array(await asset.arrayBuffer());
  const headers = {
    'Content-Type': 'video/mp4',
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'public, max-age=86400',
    'X-Content-Type-Options': 'nosniff',
  };
  const range = /^bytes=(\d*)-(\d*)$/.exec(c.req.header('Range') ?? '');
  if (!range || (range[1] === '' && range[2] === '')) return c.body(body, 200, headers);
  const size = body.length;
  const start = range[1] === '' ? Math.max(0, size - Number(range[2])) : Number(range[1]);
  const end = range[1] === '' || range[2] === '' ? size - 1 : Math.min(Number(range[2]), size - 1);
  if (start > end || start >= size)
    return c.body(null, 416, { ...headers, 'Content-Range': `bytes */${size}` });
  return c.body(body.slice(start, end + 1), 206, {
    ...headers,
    'Content-Range': `bytes ${start}-${end}/${size}`,
  });
}

export const appleAppSiteAssociation = {
  applinks: {
    details: [
      {
        appIDs: [APP_ID],
        components: [{ '/': '/invite/*' }, { '/': '/join/*' }],
        // The pre-iOS 13 keys, which newer iOS ignores when `components` is present.
        appID: APP_ID,
        paths: ['/invite/*', '/join/*'],
      },
    ],
  },
};
