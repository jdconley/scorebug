import { env } from 'cloudflare:test';
import { createWorkerApp } from '../src/worker/app.js';
import { FakeGoogle } from './fake-google.js';

const ORIGIN = 'https://scorebug.live';

export function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}
export async function pkce(): Promise<{ verifier: string; challenge: string }> {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return { verifier, challenge: b64url(new Uint8Array(digest)) };
}

let ipCounter = 0;
/** A fresh client IP per call, so the per-IP rate limits do not leak between tests. */
export const freshIp = () => `198.51.100.${(ipCounter++ % 250) + 1}`;

export type Harness = ReturnType<typeof harness>;

export function harness() {
  const google = new FakeGoogle();
  const clock = { now: Date.now() };
  const app = createWorkerApp({ env, google, now: () => clock.now });
  const ip = freshIp();
  const call = (path: string, init: RequestInit = {}) => {
    const headers = new Headers(init.headers);
    if (!headers.has('cf-connecting-ip')) headers.set('cf-connecting-ip', ip);
    return app.fetch(
      new Request(new URL(path, ORIGIN), { ...init, headers, redirect: 'manual' }),
      env,
    );
  };
  const json = (path: string, body: unknown, init: RequestInit = {}) =>
    call(path, {
      method: 'POST',
      ...init,
      headers: { 'content-type': 'application/json', ...(init.headers ?? {}) },
      body: JSON.stringify(body),
    });
  const auth = (token: string) => ({ authorization: `Bearer ${token}` });

  /** Runs start → Google → callback and returns the app redirect. */
  async function callback(
    email: string,
    opts: { invite?: string; emailVerified?: boolean; sub?: string; challenge?: string } = {},
  ) {
    const challenge = opts.challenge ?? (await pkce()).challenge;
    const query = new URLSearchParams({ challenge });
    if (opts.invite) query.set('invite', opts.invite);
    const start = await call(`/v1/auth/google/start?${query}`);
    if (start.status !== 302) throw new Error(`start returned ${start.status}`);
    const state = new URL(start.headers.get('location')!).searchParams.get('state')!;
    const code = google.grant({
      email,
      ...(opts.emailVerified === undefined ? {} : { emailVerified: opts.emailVerified }),
      ...(opts.sub === undefined ? {} : { sub: opts.sub }),
    });
    const response = await call(`/v1/auth/google/callback?${new URLSearchParams({ code, state })}`);
    const location = response.headers.get('location') ?? '';
    return { response, location, redirect: new URL(location), state };
  }

  /** Full sign-in. Throws unless it ends with a session token. */
  async function signIn(email: string, opts: { invite?: string; sub?: string } = {}) {
    const { verifier, challenge } = await pkce();
    const { redirect } = await callback(email, { ...opts, challenge });
    if (redirect.searchParams.get('status') !== 'ok')
      throw new Error(`sign-in for ${email}: ${redirect.toString()}`);
    const response = await json('/v1/auth/session', {
      ticket: redirect.searchParams.get('ticket'),
      verifier,
      deviceName: 'Test iPhone',
    });
    if (response.status !== 200) throw new Error(`session: ${response.status}`);
    const body = (await response.json()) as { token: string; person: { id: string } };
    return { token: body.token, personId: body.person.id };
  }

  return { app, google, clock, call, json, auth, callback, signIn };
}

export async function allow(email: string, canCreateTeams = true) {
  await env.DB.prepare(
    'INSERT INTO beta_access(email,can_create_teams,added_by,added_at) VALUES(?,?,?,?)',
  )
    .bind(email.trim().toLowerCase(), canCreateTeams ? 1 : 0, 'test', Date.now())
    .run();
}

export async function count(table: string): Promise<number> {
  const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>();
  return row?.n ?? 0;
}

type Json = Record<string, unknown>;
/** A signed-in owner with a team, for tests that need one. */
export async function ownerWithTeam(h: Harness, email = 'owner@example.com', name = 'Wildcats') {
  await allow(email);
  const owner = await h.signIn(email);
  const created = await h.json('/v1/teams', { name }, { headers: h.auth(owner.token) });
  if (created.status !== 201) throw new Error(`create team: ${created.status}`);
  const { team } = (await created.json()) as { team: { id: string } };
  return { ...owner, teamId: team.id };
}

export async function invite(h: Harness, token: string, teamId: string, body: Json = {}) {
  const response = await h.json(`/v1/teams/${teamId}/invites`, body, { headers: h.auth(token) });
  if (response.status !== 201) throw new Error(`invite: ${response.status}`);
  return (await response.json()) as { invite: { id: string }; code: string; link: string };
}
