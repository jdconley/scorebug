import { randomInt, randomUUID } from 'node:crypto';
import { Hono, type MiddlewareHandler } from 'hono';
import { createMiddleware } from 'hono/factory';
import { z } from 'zod';
import { INVITE_CODE_ALPHABET } from '@scorebug/protocol';
import { teamColor, teamName, teamShortName } from '../routes/matches.js';
import { defaultShortName } from '../scoring.js';
import { requirePerson } from './auth-routes.js';
import type { Team, TeamRole } from './directory.js';
import type { PersonEnv } from './env.js';
import { invalid, limited, readJson, serverTime } from './http.js';
import { channels, teamYouTubeView } from './youtube-routes.js';
import {
  normalizeEmail,
  normalizeTeamInviteCode,
  routeCodeHash,
  TEAM_INVITE_CODE_LENGTH,
} from './state.js';

export type { Team, TeamRole };
export type TeamEnv = {
  Bindings: PersonEnv['Bindings'];
  Variables: PersonEnv['Variables'] & { team: Team; role: TeamRole };
};

export const DEFAULT_TEAM_COLOR = '#2563EB';
const DAY_MS = 24 * 60 * 60 * 1000;
const MAX_LIVE_INVITES = 50;

/** `:teamId` membership: 404 team_not_found for non-members (and unknown teams), 403
 * owner_required when `role` is 'owner' and the person is a member. */
export function requireMember(role?: 'owner'): MiddlewareHandler<TeamEnv> {
  return createMiddleware<TeamEnv>(async (c, next) => {
    const dir = c.var.directory;
    const teamId = c.req.param('teamId') ?? '';
    const membership = await dir.membership(teamId, c.var.person.id);
    const team = membership ? await dir.team(teamId) : null;
    if (!membership || !team) return c.json({ error: 'team_not_found' }, 404);
    if (role === 'owner' && membership !== 'owner') return c.json({ error: 'owner_required' }, 403);
    c.set('team', team);
    c.set('role', membership);
    await next();
  });
}

const formatCode = (code: string) =>
  `${code.slice(0, TEAM_INVITE_CODE_LENGTH / 2)}-${code.slice(TEAM_INVITE_CODE_LENGTH / 2)}`;

/** Mounted at /v1/teams. */
export function teamRoutes() {
  const app = new Hono<TeamEnv>();
  app.use('*', requirePerson() as unknown as MiddlewareHandler<TeamEnv>);

  const create = z
    .object({
      name: teamName,
      shortName: teamShortName.optional(),
      color: teamColor.optional(),
    })
    .strict();
  app.post('/', async (c) => {
    const input = await readJson(c, create);
    if (!input) return invalid(c);
    const dir = c.var.directory;
    if (!(await dir.betaAccess(c.var.person.email))?.canCreateTeams)
      return c.json({ error: 'cannot_create_teams' }, 403);
    const team = await dir.createTeam(c.var.person.id, {
      name: input.name,
      shortName: input.shortName ?? defaultShortName(input.name),
      color: input.color ?? DEFAULT_TEAM_COLOR,
    });
    return c.json({ team, role: 'owner', serverTime: serverTime() }, 201);
  });

  app.get('/:teamId', requireMember(), async (c) => {
    const dir = c.var.directory;
    const team = c.var.team;
    const owner = c.var.role === 'owner';
    const [members, invites, youtube] = await Promise.all([
      dir.members(team.id),
      owner ? dir.teamInvites(team.id) : Promise.resolve(undefined),
      channels(c, dir.now).teamConnection(team.id),
    ]);
    return c.json({
      team,
      role: c.var.role,
      members,
      youtube: teamYouTubeView(youtube),
      ...(invites ? { invites } : {}),
      serverTime: serverTime(),
    });
  });

  const patch = z
    .object({
      name: teamName.optional(),
      shortName: teamShortName.optional(),
      color: teamColor.optional(),
    })
    .strict()
    .refine((value) => Object.values(value).some((v) => v !== undefined));
  app.patch('/:teamId', requireMember('owner'), async (c) => {
    const input = await readJson(c, patch);
    if (!input) return invalid(c);
    const team = await c.var.directory.updateTeam(c.var.team.id, input);
    return c.json({ team, serverTime: serverTime() });
  });

  /** The owner picks one of their own connections (or null) as the team's channel. */
  const channel = z.object({ connectionId: z.uuid().nullable() }).strict();
  app.put('/:teamId/youtube', requireMember('owner'), async (c) => {
    const input = await readJson(c, channel);
    if (!input) return invalid(c);
    const store = channels(c, c.var.directory.now);
    if (input.connectionId !== null) {
      const row = await store.connection(input.connectionId);
      if (!row || row.person_id !== c.var.person.id)
        return c.json({ error: 'connection_not_found' }, 404);
    }
    await store.setTeamChannel(c.var.team.id, input.connectionId);
    return c.json({
      youtube: teamYouTubeView(await store.teamConnection(c.var.team.id)),
      serverTime: serverTime(),
    });
  });

  const newInvite = z
    .object({
      email: z.string().trim().max(254).pipe(z.email()).optional(),
      expiresInDays: z.number().int().min(1).max(30).optional(),
    })
    .strict();
  app.post('/:teamId/invites', requireMember('owner'), async (c) => {
    const input = await readJson(c, newInvite, true);
    if (!input) return invalid(c);
    const dir = c.var.directory;
    if ((await dir.liveInviteCount(c.var.team.id)) >= MAX_LIVE_INVITES)
      return c.json({ error: 'invite_limit' }, 409);
    const now = dir.now();
    for (let attempt = 0; attempt < 8; attempt++) {
      let code = '';
      for (let i = 0; i < TEAM_INVITE_CODE_LENGTH; i++)
        code += INVITE_CODE_ALPHABET[randomInt(INVITE_CODE_ALPHABET.length)];
      const id = randomUUID();
      const inserted = await dir.insertInvite({
        id,
        team_id: c.var.team.id,
        code_hash: routeCodeHash(c.env.SERVER_SECRET, 'team-invite', code),
        email: input.email ? normalizeEmail(input.email) : null,
        created_by: c.var.person.id,
        created_at: now,
        expires_at: now + (input.expiresInDays ?? 14) * DAY_MS,
      });
      if (!inserted) continue;
      const invite = (await dir.teamInvites(c.var.team.id)).find((i) => i.id === id)!;
      return c.json(
        {
          invite,
          code: formatCode(code),
          link: `${c.env.PUBLIC_URL}/invite/${code}`,
          serverTime: serverTime(),
        },
        201,
      );
    }
    return c.json({ error: 'invite_code_exhausted' }, 503);
  });

  app.delete('/:teamId/invites/:inviteId', requireMember('owner'), async (c) => {
    const invite = await c.var.directory.revokeInvite(c.var.team.id, c.req.param('inviteId'));
    return invite
      ? c.json({ invite, serverTime: serverTime() })
      : c.json({ error: 'invite_not_found' }, 404);
  });

  app.delete('/:teamId/members/:personId', requireMember(), async (c) => {
    const target = c.req.param('personId');
    if (target !== c.var.person.id && c.var.role !== 'owner')
      return c.json({ error: 'owner_required' }, 403);
    const result = await c.var.directory.removeMember(c.var.team.id, target);
    if (result === 'last_owner') return c.json({ error: 'last_owner' }, 409);
    if (result === 'not_found') return c.json({ error: 'member_not_found' }, 404);
    return c.body(null, 204);
  });
  return app;
}

/** Mounted at /v1/team-invites. */
export function teamInviteRoutes() {
  const app = new Hono<PersonEnv>();
  app.post('/accept', requirePerson(), async (c) => {
    const rateLimited = await limited(c, c.env.REDEEM_LIMIT, 'redeem');
    if (rateLimited) return rateLimited;
    const input = await readJson(c, z.object({ code: z.string().max(32) }).strict());
    if (!input) return invalid(c);
    const code = normalizeTeamInviteCode(input.code);
    const dir = c.var.directory;
    const row = code
      ? await dir.liveInviteByHash(routeCodeHash(c.env.SERVER_SECRET, 'team-invite', code))
      : null;
    if (!row) return c.json({ error: 'invite_invalid' }, 404);
    if (row.email !== null && row.email !== normalizeEmail(c.var.person.email))
      return c.json({ error: 'invite_email_mismatch' }, 403);
    await dir.join(row.team_id, c.var.person.id);
    const [team, role] = await Promise.all([
      dir.team(row.team_id),
      dir.membership(row.team_id, c.var.person.id),
    ]);
    return c.json({ team, role, serverTime: serverTime() });
  });
  return app;
}
