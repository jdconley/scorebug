import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { normalizeInviteCode } from '@scorebug/protocol';
import { requirePerson } from './auth-routes.js';
import type { AppEnv, Env, PersonEnv } from './env.js';
import { invalid, limited } from './http.js';
import { routeCodeHash } from './state.js';
import { MATCH_CODE_PURPOSE, MEMBER_HEADER, TEAM_HEADER } from './team-object.js';
import { requireMember, type TeamEnv } from './team-routes.js';

const MATCH_ID = /^[A-Za-z0-9_-]{1,128}$/;

/** Forward to the team's object. MEMBER_HEADER is always replaced (or removed). */
async function forward(
  env: Env,
  request: Request,
  teamId: string,
  init: { path?: string; member?: string | null; body?: string } = {},
): Promise<Response> {
  const url = new URL(request.url);
  if (init.path !== undefined) url.pathname = init.path;
  const headers = new Headers(request.headers);
  headers.delete(MEMBER_HEADER);
  if (init.member) headers.set(MEMBER_HEADER, init.member);
  headers.set(TEAM_HEADER, teamId);
  const hasBody = request.method !== 'GET' && request.method !== 'HEAD';
  const forwarded = new Request(url, {
    method: request.method,
    headers,
    ...(hasBody ? { body: init.body ?? (await request.text()) } : {}),
  });
  return env.TEAM.getByName(teamId).fetch(forwarded);
}

async function teamOf(env: Env, gameId: string): Promise<string | null> {
  if (!MATCH_ID.test(gameId)) return null;
  const row = await env.DB.prepare('SELECT team_id FROM match_index WHERE game_id=?')
    .bind(gameId)
    .first<{ team_id: string }>();
  return row?.team_id ?? null;
}

/**
 * Creating a match claims its client-chosen ID for the team in D1 first, so another team can
 * never route to it. A retry by the same team continues; a claim this request made is
 * released again if the team object refuses the create.
 */
async function create(c: Context<TeamEnv>, member: string): Promise<Response> {
  const text = await c.req.text();
  let id: unknown;
  try {
    id = (JSON.parse(text) as { id?: unknown }).id;
  } catch {
    return invalid(c);
  }
  if (typeof id !== 'string' || !MATCH_ID.test(id) || id === 'active') return invalid(c);
  const teamId = c.var.team.id;
  const claim = await c.env.DB.prepare(
    'INSERT INTO match_index(game_id,team_id,created_at) VALUES(?,?,?) ON CONFLICT(game_id) DO NOTHING',
  )
    .bind(id, teamId, c.var.directory.now())
    .run();
  const claimed = claim.meta.changes > 0;
  if (!claimed && (await teamOf(c.env, id)) !== teamId)
    return c.json({ error: 'match_id_taken' }, 409);
  const response = await forward(c.env, c.req.raw, teamId, {
    path: '/v1/matches',
    member,
    body: text,
  });
  if (claimed && response.status !== 201)
    await c.env.DB.prepare('DELETE FROM match_index WHERE game_id=? AND team_id=?')
      .bind(id, teamId)
      .run();
  return response;
}

/** Mounted before /v1/teams so member match routes reach the team object. */
export function matchForwardingRoutes() {
  const app = new Hono<AppEnv>();

  const teamMatches = new Hono<TeamEnv>();
  teamMatches.use('*', requirePerson() as unknown as MiddlewareHandler<TeamEnv>, requireMember());
  teamMatches.all('/*', async (c) => {
    const member = c.var.person.id;
    const teamId = c.var.team.id;
    const prefix = `/v1/teams/${teamId}/matches`;
    const rest = new URL(c.req.url).pathname.slice(prefix.length);
    if (c.req.method === 'POST' && (rest === '' || rest === '/')) return create(c, member);
    return forward(c.env, c.req.raw, teamId, { path: `/v1/matches${rest}`, member });
  });
  app.route('/v1/teams/:teamId/matches', teamMatches);

  // Match-token routes: the credential is checked by the team object; no member identity.
  const byMatch = async (c: Context<AppEnv>) => {
    const teamId = await teamOf(c.env, c.req.param('id') ?? '');
    if (!teamId) return c.json({ error: 'match_not_found' }, 404);
    return forward(c.env, c.req.raw, teamId, { member: null });
  };
  app.all('/v1/matches/:id', byMatch);
  app.all('/v1/matches/:id/*', byMatch);

  // Match join codes: no account needed, the code is the capability.
  app.post('/v1/invites/redeem', async (c) => {
    const rateLimited = await limited(c, c.env.REDEEM_LIMIT, 'redeem');
    if (rateLimited) return rateLimited;
    const text = await c.req.text();
    let code: unknown;
    try {
      code = (JSON.parse(text) as { code?: unknown }).code;
    } catch {
      return invalid(c);
    }
    const normalized = typeof code === 'string' ? normalizeInviteCode(code) : null;
    const row = normalized
      ? await c.env.DB.prepare('SELECT team_id FROM match_codes WHERE code_hash=? AND expires_at>?')
          .bind(
            routeCodeHash(c.env.SERVER_SECRET, MATCH_CODE_PURPOSE, normalized),
            c.var.directory.now(),
          )
          .first<{ team_id: string }>()
      : null;
    if (!row) return c.json({ error: 'invite_invalid' }, 404);
    return forward(c.env, c.req.raw, row.team_id, { member: null, body: text });
  });
  return app;
}

export type { PersonEnv };
