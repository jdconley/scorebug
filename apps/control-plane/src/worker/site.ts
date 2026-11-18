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
  "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; font-src 'self'; " +
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
  .bug { background: var(--raised); border: 1px solid var(--line); border-radius: 18px;
    padding: 14px 18px; margin: 8px 0 32px; box-shadow: 0 18px 40px rgba(0,0,0,0.45);
    max-width: 420px; position: relative; }
  .bug .row { display: flex; align-items: center; gap: 14px; height: 64px; }
  .bug .chip { width: 10px; height: 44px; border-radius: 5px; }
  .bug .name { flex: 1; font: 700 30px/1 var(--display); letter-spacing: 0.04em; }
  .bug .score { font: 700 56px/1 var(--display); font-variant-numeric: tabular-nums; }
  .bug .row.dim .name, .bug .row.dim .score { color: var(--secondary); }
  .bug .live { position: absolute; top: -9px; right: -9px; width: 24px; height: 24px;
    border-radius: 50%; background: var(--live); box-shadow: 0 0 18px rgba(229,55,44,0.75); }
  ol.steps { list-style: none; padding: 0; margin: 0 0 8px; display: grid; gap: 12px; }
  ol.steps li { display: flex; gap: 16px; align-items: flex-start; margin: 0; padding: 18px;
    background: var(--surface); border: 1px solid var(--line); border-radius: 16px; }
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
        <meta property="og:image" content="${c.env.PUBLIC_URL}/icon-512.png" />
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
      <div class="bug" role="img" aria-label="A Scorebug scoreboard: Wildcats 25, Visitors 23">
        <div class="row">
          <span class="chip" style="background:var(--blue)"></span><span class="name">WILDCATS</span
          ><span class="score">25</span>
        </div>
        <div class="row dim">
          <span class="chip" style="background:var(--orange)"></span
          ><span class="name">VISITORS</span><span class="score">23</span>
        </div>
        <span class="live"></span>
      </div>
      <ol class="steps">
        <li>
          <span class="n">1</span>
          <div>
            <h3>Film on your iPhone</h3>
            <p>Set the phone on a tripod courtside and open Scorebug.</p>
          </div>
        </li>
        <li>
          <span class="n">2</span>
          <div>
            <h3>Keep score</h3>
            <p>
              Tap points on the same phone, on an Apple Watch, or hand scoring to a second phone in
              the stands.
            </p>
          </div>
        </li>
        <li>
          <span class="n">3</span>
          <div>
            <h3>Go live on YouTube</h3>
            <p>
              Scorebug puts the score on the video and streams it to the YouTube channel you pick.
            </p>
          </div>
        </li>
      </ol>
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
  site.get('/.well-known/apple-app-site-association', (c) => c.json(appleAppSiteAssociation));
  return site;
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
