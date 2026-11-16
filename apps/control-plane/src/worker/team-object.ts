import { DurableObject } from 'cloudflare:workers';
import { Hono } from 'hono';
import { createMiddleware } from 'hono/factory';
import { normalizeInviteCode } from '@scorebug/protocol';
import type { Config } from '../config.js';
import { MatchStore } from '../matches-store.js';
import { RedeemGuard } from '../rate-limit.js';
import { inviteRedeemRoutes } from '../routes/account.js';
import { matchesRoutes, type MatchAccess } from '../routes/matches.js';
import { durableObjectSql } from '../sql-durable.js';
import type { Env } from './env.js';
import { routeCodeHash } from './state.js';

/** Set only by the Worker, after it checked team membership. Stripped from client requests. */
export const MEMBER_HEADER = 'x-scorebug-member';
/** Set by the Worker on every forwarded request: the team this object belongs to. */
export const TEAM_HEADER = 'x-scorebug-team';
export const MATCH_CODE_PURPOSE = 'route-code';

/**
 * Trusted member access. The object is reachable only through the Worker, which overwrites
 * MEMBER_HEADER with the signed-in member (or removes it on match-token routes).
 */
export function memberAccess(env: Env, team: () => string | null): MatchAccess {
  const member = (header: string | undefined) =>
    header && /^[A-Za-z0-9_-]{1,128}$/.test(header) ? `member:${header}` : undefined;
  return {
    bootstrap: createMiddleware(async (c, next) => {
      if (!member(c.req.header(MEMBER_HEADER)))
        return c.json({ error: 'unauthorized', role: 'member' }, 401);
      await next();
    }),
    issuer: (c) => member(c.req.header(MEMBER_HEADER)),
    joinLink: (code) => `${env.PUBLIC_URL}/join/${code}`,
    onInvite: {
      async issued({ inviteId, code, gameId, expiresAt }) {
        const teamId = team();
        const normalized = normalizeInviteCode(code);
        if (!teamId || !normalized) throw new Error('match code routing needs a team and a code');
        // Codes are unique per team object only; across teams an expired row may hold the
        // same hash and is replaced. A live collision fails, and the caller revokes the code.
        const result = await env.DB.prepare(
          `INSERT INTO match_codes(code_hash,invite_id,team_id,game_id,expires_at) VALUES(?,?,?,?,?)
          ON CONFLICT(code_hash) DO UPDATE SET invite_id=excluded.invite_id, team_id=excluded.team_id,
            game_id=excluded.game_id, expires_at=excluded.expires_at WHERE match_codes.expires_at<=?`,
        )
          .bind(
            routeCodeHash(env.SERVER_SECRET, MATCH_CODE_PURPOSE, normalized),
            inviteId,
            teamId,
            gameId,
            Date.parse(expiresAt),
            Date.now(),
          )
          .run();
        if (result.meta.changes === 0) throw new Error('match code already routed by another team');
      },
      async revoked({ inviteId }) {
        await env.DB.prepare('DELETE FROM match_codes WHERE invite_id=?').bind(inviteId).run();
      },
    },
  };
}

/** One per team, named by the team ID: the team's matches, scoring and media state. */
export class TeamObject extends DurableObject<Env> {
  private readonly app: Hono;
  readonly store: MatchStore;
  /** This object's team: its name, else what the Worker said (one object is one team). */
  private team: string | null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.team = ctx.id.name ?? null;
    this.store = new MatchStore(durableObjectSql(ctx.storage), env.SERVER_SECRET);
    // Only the fields the match routes read; the rest belong to the self-hosted server.
    const config = { PUBLIC_URL: env.PUBLIC_URL } as Config;
    const app = new Hono();
    app.route(
      '/v1/matches',
      matchesRoutes(
        config,
        this.store,
        memberAccess(env, () => this.team),
      ),
    );
    app.route('/v1/invites', inviteRedeemRoutes(this.store, new RedeemGuard()));
    app.notFound((c) => c.json({ error: 'not_found' }, 404));
    this.app = app;
  }

  override async fetch(request: Request): Promise<Response> {
    this.team ??= request.headers.get(TEAM_HEADER);
    return this.app.fetch(request);
  }
}
