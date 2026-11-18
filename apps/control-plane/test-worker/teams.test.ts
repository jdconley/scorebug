import { env } from 'cloudflare:test';
import { beforeEach, expect, it } from 'vitest';
import { harness, invite, ownerWithTeam, type Harness } from './helpers.js';

let h: Harness;
beforeEach(() => {
  h = harness();
});

async function expectNoTeams(token: string) {
  const me = await h.call('/v1/me', { headers: h.auth(token) });
  expect(((await me.json()) as { teams: unknown[] }).teams).toEqual([]);
}

it('owner creates a team', async () => {
  const { token } = await h.signIn('owner@example.com');
  const response = await h.json(
    '/v1/teams',
    { name: '  Wildcats 14U  ' },
    { headers: h.auth(token) },
  );
  expect(response.status).toBe(201);
  const body = (await response.json()) as { team: { id: string }; role: string };
  expect(body).toMatchObject({
    team: { name: 'Wildcats 14U', shortName: 'Wildcats', color: '#2563EB' },
    role: 'owner',
  });
  const me = await h.call('/v1/me', { headers: h.auth(token) });
  expect(((await me.json()) as { teams: unknown[] }).teams).toEqual([
    {
      id: body.team.id,
      name: 'Wildcats 14U',
      shortName: 'Wildcats',
      color: '#2563EB',
      role: 'owner',
    },
  ]);
  const detail = await h.call(`/v1/teams/${body.team.id}`, { headers: h.auth(token) });
  expect(await detail.json()).toMatchObject({
    role: 'owner',
    members: [{ email: 'owner@example.com', role: 'owner' }],
    invites: [],
  });
});

it('rejects invalid team fields', async () => {
  const { token } = await h.signIn('owner@example.com');
  for (const body of [
    { name: '' },
    { name: 'A', color: 'blue' },
    { name: 'A', shortName: '123456789' },
  ])
    expect((await h.json('/v1/teams', body, { headers: h.auth(token) })).status).toBe(400);
});

it('anyone signed in can create a team', async () => {
  const { token } = await h.signIn('parent@example.com');
  const response = await h.json('/v1/teams', { name: 'Club 12' }, { headers: h.auth(token) });
  expect(response.status).toBe(201);
  expect(await response.json()).toMatchObject({ team: { name: 'Club 12' }, role: 'owner' });
});

it('owner renames a team', async () => {
  const owner = await ownerWithTeam(h);
  const response = await h.call(`/v1/teams/${owner.teamId}`, {
    method: 'PATCH',
    headers: { ...h.auth(owner.token), 'content-type': 'application/json' },
    body: JSON.stringify({ name: 'Wildcats 15U', color: '#112233' }),
  });
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({
    team: { name: 'Wildcats 15U', shortName: 'Wildcats', color: '#112233' },
  });
});

it('non-member gets 404 for a team', async () => {
  const owner = await ownerWithTeam(h);
  const other = await h.signIn('other@example.com');
  const response = await h.call(`/v1/teams/${owner.teamId}`, { headers: h.auth(other.token) });
  expect(response.status).toBe(404);
  expect(await response.json()).toEqual({ error: 'team_not_found' });
  expect((await h.call('/v1/teams/not-a-team', { headers: h.auth(other.token) })).status).toBe(404);
});

it('member cannot invite', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId);
  const member = await h.signIn('parent@example.com', { invite: code });
  const response = await h.json(
    `/v1/teams/${owner.teamId}/invites`,
    {},
    { headers: h.auth(member.token) },
  );
  expect(response.status).toBe(403);
  expect(await response.json()).toEqual({ error: 'owner_required' });
  const detail = await h.call(`/v1/teams/${owner.teamId}`, { headers: h.auth(member.token) });
  const body = (await detail.json()) as { role: string; invites?: unknown };
  expect(body.role).toBe('member');
  expect(body.invites).toBeUndefined();
});

it('link invite joins the team at sign-in', async () => {
  const owner = await ownerWithTeam(h);
  const created = await invite(h, owner.token, owner.teamId);
  expect(created.code).toMatch(/^[2-9A-Z]{4}-[2-9A-Z]{4}$/);
  expect(created.link).toBe(`https://scorebug.live/invite/${created.code.replace('-', '')}`);
  const { redirect } = await h.callback('parent@example.com', { invite: created.code });
  expect(redirect.searchParams.get('status')).toBe('ok');
  const member = await h.signIn('parent@example.com');
  const me = await h.call('/v1/me', { headers: h.auth(member.token) });
  expect(await me.json()).toMatchObject({ teams: [{ id: owner.teamId, role: 'member' }] });
  const detail = await h.call(`/v1/teams/${owner.teamId}`, { headers: h.auth(owner.token) });
  const body = (await detail.json()) as { invites: Record<string, unknown>[] };
  expect(body.invites).toHaveLength(1);
  expect(JSON.stringify(body.invites)).not.toContain(created.code.replace('-', ''));
  expect(body.invites[0]).not.toHaveProperty('code');
  expect(body.invites[0]).not.toHaveProperty('codeHash');
});

it('email invite auto-accepts on first sign-in', async () => {
  const owner = await ownerWithTeam(h);
  await invite(h, owner.token, owner.teamId, { email: ' Parent@Example.com ' });
  const member = await h.signIn('parent@example.com');
  const me = await h.call('/v1/me', { headers: h.auth(member.token) });
  expect(await me.json()).toMatchObject({ teams: [{ id: owner.teamId, role: 'member' }] });
});

it('email invite rejects another email', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId, { email: 'parent@example.com' });
  // A link carrying someone else's invite signs a stranger in without joining the team.
  const stranger = await h.signIn('stranger@example.com', { invite: code });
  await expectNoTeams(stranger.token);
  const other = await h.signIn('other@example.com');
  const response = await h.json(
    '/v1/team-invites/accept',
    { code },
    { headers: h.auth(other.token) },
  );
  expect(response.status).toBe(403);
  expect(await response.json()).toEqual({ error: 'invite_email_mismatch' });
});

it('accept joins an existing person and is idempotent', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId);
  const parent = await h.signIn('parent@example.com');
  for (let i = 0; i < 2; i++) {
    const response = await h.json(
      '/v1/team-invites/accept',
      { code },
      { headers: h.auth(parent.token) },
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ team: { id: owner.teamId }, role: 'member' });
  }
  const owners = await h.json(
    '/v1/team-invites/accept',
    { code },
    { headers: h.auth(owner.token) },
  );
  expect(await owners.json()).toMatchObject({ role: 'owner' });
});

it('revoked invite is invalid', async () => {
  const owner = await ownerWithTeam(h);
  const created = await invite(h, owner.token, owner.teamId);
  const revoked = await h.call(`/v1/teams/${owner.teamId}/invites/${created.invite.id}`, {
    method: 'DELETE',
    headers: h.auth(owner.token),
  });
  expect(revoked.status).toBe(200);
  expect(
    ((await revoked.json()) as { invite: { revokedAt: string | null } }).invite.revokedAt,
  ).not.toBeNull();
  const parent = await h.signIn('parent@example.com', { invite: created.code });
  await expectNoTeams(parent.token);
  const other = await h.signIn('other@example.com');
  const response = await h.json(
    '/v1/team-invites/accept',
    { code: created.code },
    { headers: h.auth(other.token) },
  );
  expect(response.status).toBe(404);
  expect(await response.json()).toEqual({ error: 'invite_invalid' });
});

it('expired invite is invalid', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId, { expiresInDays: 1 });
  h.clock.now += 24 * 60 * 60 * 1000 + 1;
  const parent = await h.signIn('parent@example.com', { invite: code });
  await expectNoTeams(parent.token);
});

it('invite expiry must be 1-30 days', async () => {
  const owner = await ownerWithTeam(h);
  for (const expiresInDays of [0, 31])
    expect(
      (
        await h.json(
          `/v1/teams/${owner.teamId}/invites`,
          { expiresInDays },
          { headers: h.auth(owner.token) },
        )
      ).status,
    ).toBe(400);
});

it('last owner cannot leave', async () => {
  const owner = await ownerWithTeam(h);
  const response = await h.call(`/v1/teams/${owner.teamId}/members/${owner.personId}`, {
    method: 'DELETE',
    headers: h.auth(owner.token),
  });
  expect(response.status).toBe(409);
  expect(await response.json()).toEqual({ error: 'last_owner' });
});

it('member can leave', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId, { email: 'parent@example.com' });
  const member = await h.signIn('parent@example.com', { invite: code });
  const response = await h.call(`/v1/teams/${owner.teamId}/members/${member.personId}`, {
    method: 'DELETE',
    headers: h.auth(member.token),
  });
  expect(response.status).toBe(204);
  expect(
    (await h.call(`/v1/teams/${owner.teamId}`, { headers: h.auth(member.token) })).status,
  ).toBe(404);
  // Leaving revokes the email invite: signing in again does not rejoin.
  const again = await h.signIn('parent@example.com');
  await expectNoTeams(again.token);
  await expectNoTeams(member.token);
});

it('a member cannot remove someone else', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId);
  const member = await h.signIn('parent@example.com', { invite: code });
  const response = await h.call(`/v1/teams/${owner.teamId}/members/${owner.personId}`, {
    method: 'DELETE',
    headers: h.auth(member.token),
  });
  expect(response.status).toBe(403);
});

it('owner removes a member', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId);
  const member = await h.signIn('parent@example.com', { invite: code });
  const response = await h.call(`/v1/teams/${owner.teamId}/members/${member.personId}`, {
    method: 'DELETE',
    headers: h.auth(owner.token),
  });
  expect(response.status).toBe(204);
  const rows = await env.DB.prepare('SELECT COUNT(*) AS n FROM memberships').first<{ n: number }>();
  expect(rows?.n).toBe(1);
});

it('one person on two teams sees both in /v1/me', async () => {
  const a = await ownerWithTeam(h, 'a@example.com', 'Wildcats');
  const b = await ownerWithTeam(h, 'b@example.com', 'Hawks');
  const inviteA = await invite(h, a.token, a.teamId);
  const inviteB = await invite(h, b.token, b.teamId);
  await h.signIn('parent@example.com', { invite: inviteA.code });
  const parent = await h.signIn('parent@example.com', { invite: inviteB.code });
  const me = await h.call('/v1/me', { headers: h.auth(parent.token) });
  const teams = ((await me.json()) as { teams: { id: string; role: string }[] }).teams;
  expect(teams.map((t) => [t.id, t.role]).sort()).toEqual(
    [
      [a.teamId, 'member'],
      [b.teamId, 'member'],
    ].sort(),
  );
});
