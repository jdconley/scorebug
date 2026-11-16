import { Hono, type Context } from 'hono';
import { deleteCookie, getCookie, setCookie } from 'hono/cookie';
import { html, raw } from 'hono/html';
import type { HtmlEscapedString } from 'hono/utils/html';
import { z } from 'zod';
import { isAdmin, type AdminCallback } from './auth-routes.js';
import { ADMIN_DEVICE_NAME, type Person } from './directory.js';
import type { AppEnv } from './env.js';
import { normalizeEmail, randomToken, sha256Base64url } from './state.js';

const ADMIN_COOKIE = 'sb_admin';
const VERIFIER_COOKIE = 'sb_admin_verifier';
const CALLBACK_PATH = '/v1/auth/google/callback';
const ADMIN_MAX_AGE_S = 12 * 60 * 60;

const SECURITY_HEADERS = {
  'Content-Security-Policy':
    "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
  'Cache-Control': 'no-store',
  // Not no-referrer: that makes browsers send `Origin: null` on this page's form posts.
  'Referrer-Policy': 'same-origin',
  'X-Content-Type-Options': 'nosniff',
};

const STYLE = raw(`
  :root { color-scheme: light dark; --bg: #f6f7f9; --card: #fff; --ink: #14171c; --muted: #5d6673;
    --line: #dde1e6; --accent: #2563eb; --danger: #b42318; }
  @media (prefers-color-scheme: dark) { :root { --bg: #0f1216; --card: #171b21; --ink: #e8ebef;
    --muted: #98a2b0; --line: #2a3039; --accent: #6b9bff; --danger: #ff8a7a; } }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  main { max-width: 860px; margin: 0 auto; padding: 32px 16px 64px; }
  h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 16px; margin: 0 0 12px; }
  p.lede { color: var(--muted); margin: 0 0 24px; }
  section { background: var(--card); border: 1px solid var(--line); border-radius: 12px;
    padding: 20px; margin-bottom: 20px; overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 8px 10px 8px 0; border-bottom: 1px solid var(--line);
    vertical-align: middle; }
  th { color: var(--muted); font-weight: 600; font-size: 13px; }
  tr:last-child td { border-bottom: 0; }
  form.add { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 16px; }
  input[type=email] { flex: 1 1 240px; padding: 8px 10px; border: 1px solid var(--line);
    border-radius: 8px; background: var(--bg); color: var(--ink); font: inherit; }
  button { font: inherit; border-radius: 8px; padding: 7px 14px; cursor: pointer;
    border: 1px solid var(--accent); background: var(--accent); color: #fff; }
  button.remove { background: transparent; color: var(--danger); border-color: var(--line); }
  .note { color: var(--muted); font-size: 13px; }
  .empty { color: var(--muted); }
`);

function page(title: string, body: HtmlEscapedString | Promise<HtmlEscapedString>) {
  return html`<!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>${title}</title>
        <style>
          ${STYLE}
        </style>
      </head>
      <body>
        <main>${body}</main>
      </body>
    </html>`;
}

const respond = (c: Context, status: 200 | 403, body: ReturnType<typeof page>) =>
  c.html(body, status, SECURITY_HEADERS);

const refused = (c: Context, message: string) =>
  respond(
    c,
    403,
    page(
      'Scorebug admin',
      html`<h1>Not available</h1>
        <p class="lede">${message}</p>`,
    ),
  );

async function adminPerson(c: Context<AppEnv>): Promise<Person | null> {
  const token = getCookie(c, ADMIN_COOKIE) ?? '';
  const person = await c.var.directory.adminSessionPerson(token, ADMIN_MAX_AGE_S * 1000);
  return person && isAdmin(c.env, person.email) ? person : null;
}

/**
 * The callback for purpose `admin`. The browser proves it started this sign-in with the
 * verifier cookie set by GET /admin. A same-origin page then moves on to /admin, because a
 * SameSite=Strict cookie set during Google's cross-site redirect would not ride a 302.
 */
export const adminCallback: AdminCallback = async (c, state, outcome) => {
  const verifier = getCookie(c, VERIFIER_COOKIE) ?? '';
  deleteCookie(c, VERIFIER_COOKIE, { path: CALLBACK_PATH, secure: true });
  if (!verifier || sha256Base64url(verifier) !== state.challenge)
    return refused(c, 'Start again from the admin page in this browser.');
  if (outcome.status !== 'ok' || !isAdmin(c.env, outcome.person.email))
    return refused(c, 'This Google account is not a Scorebug admin.');
  const token = await c.var.directory.createSession(outcome.person.id, ADMIN_DEVICE_NAME);
  setCookie(c, ADMIN_COOKIE, token, {
    secure: true,
    httpOnly: true,
    sameSite: 'Strict',
    path: '/admin',
    maxAge: ADMIN_MAX_AGE_S,
  });
  return respond(
    c,
    200,
    page(
      'Scorebug admin',
      html`<meta http-equiv="refresh" content="0;url=/admin" />
        <p><a href="/admin">Continue to the admin page</a></p>`,
    ),
  );
};

const email = z.string().trim().max(254).pipe(z.email());

/** Mounted at /admin. JD's private beta list. Server-rendered, no client JS. */
export function adminRoutes() {
  const app = new Hono<AppEnv>();

  app.get('/', async (c) => {
    const person = await adminPerson(c);
    if (!person) {
      const verifier = randomToken();
      setCookie(c, VERIFIER_COOKIE, verifier, {
        secure: true,
        httpOnly: true,
        // Lax: it must ride Google's top-level redirect back to the callback.
        sameSite: 'Lax',
        path: CALLBACK_PATH,
        maxAge: 10 * 60,
      });
      const query = new URLSearchParams({ purpose: 'admin', challenge: sha256Base64url(verifier) });
      return c.redirect(`/v1/auth/google/start?${query}`, 302);
    }
    const dir = c.var.directory;
    const [beta, teams] = await Promise.all([dir.listBeta(), dir.teamsWithCounts()]);
    const date = (iso: string) => iso.slice(0, 10);
    return respond(
      c,
      200,
      page(
        'Scorebug admin',
        html`<h1>Scorebug private beta</h1>
          <p class="lede">Signed in as ${person.email}</p>
          <section>
            <h2>Beta list (${beta.length})</h2>
            <form class="add" method="post" action="/admin/beta">
              <input type="email" name="email" placeholder="name@example.com" required />
              <label
                ><input type="checkbox" name="canCreateTeams" checked /> Can create teams</label
              >
              <button type="submit">Add</button>
            </form>
            ${beta.length === 0
              ? html`<p class="empty">Nobody yet.</p>`
              : html`<table>
                  <thead>
                    <tr>
                      <th>Email</th>
                      <th>Can create teams</th>
                      <th>Added</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    ${beta.map(
                      (row) =>
                        html`<tr>
                          <td>${row.email}</td>
                          <td>${row.canCreateTeams ? 'Yes' : 'No'}</td>
                          <td>${date(row.addedAt)}</td>
                          <td>
                            <form method="post" action="/admin/beta/remove">
                              <input type="hidden" name="email" value="${row.email}" />
                              <button class="remove" type="submit">Remove</button>
                            </form>
                          </td>
                        </tr>`,
                    )}
                  </tbody>
                </table>`}
            <p class="note">
              Removing an email stops new sign-ins only for people on no team. Existing sessions
              keep working.
            </p>
          </section>
          <section>
            <h2>Teams (${teams.length})</h2>
            ${teams.length === 0
              ? html`<p class="empty">No teams yet.</p>`
              : html`<table>
                  <thead>
                    <tr>
                      <th>Team</th>
                      <th>Short name</th>
                      <th>Members</th>
                      <th>Owners</th>
                      <th>Created</th>
                    </tr>
                  </thead>
                  <tbody>
                    ${teams.map(
                      (team) =>
                        html`<tr>
                          <td>${team.name}</td>
                          <td>${team.shortName}</td>
                          <td>${team.members}</td>
                          <td>${team.owners}</td>
                          <td>${date(team.createdAt)}</td>
                        </tr>`,
                    )}
                  </tbody>
                </table>`}
          </section>`,
      ),
    );
  });

  /** Same-origin form posts from a signed-in admin only. */
  async function guarded(c: Context<AppEnv>): Promise<{ form: FormData } | Response> {
    if (c.req.header('origin') !== c.env.PUBLIC_URL) return refused(c, 'Cross-site request.');
    const person = await adminPerson(c);
    if (!person) return refused(c, 'Sign in again.');
    try {
      return { form: await c.req.raw.formData() };
    } catch {
      return c.text('invalid_request', 400);
    }
  }

  app.post('/beta', async (c) => {
    const result = await guarded(c);
    if (result instanceof Response) return result;
    const parsed = email.safeParse(result.form.get('email') ?? '');
    if (!parsed.success) return c.text('invalid_email', 400);
    const person = (await adminPerson(c))!;
    await c.var.directory.addBeta(
      normalizeEmail(parsed.data),
      result.form.get('canCreateTeams') !== null,
      person.email,
    );
    return c.redirect('/admin', 303);
  });

  app.post('/beta/remove', async (c) => {
    const result = await guarded(c);
    if (result instanceof Response) return result;
    const value = result.form.get('email');
    if (typeof value !== 'string' || !value) return c.text('invalid_email', 400);
    await c.var.directory.removeBeta(value);
    return c.redirect('/admin', 303);
  });
  return app;
}
