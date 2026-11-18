import { env, runInDurableObject } from 'cloudflare:test';
import { beforeEach, expect, it } from 'vitest';
import fixture from '../../../packages/protocol/fixtures/match-v1.json';
import { count, harness, invite, ownerWithTeam, type Harness } from './helpers.js';

type Json = Record<string, any>;
let h: Harness;
beforeEach(() => {
  h = harness();
});

const deleteAccount = (token: string) =>
  h.call('/v1/me', { method: 'DELETE', headers: h.auth(token) });

const teamDetail = async (token: string, teamId: string) => {
  const response = await h.call(`/v1/teams/${teamId}`, { headers: h.auth(token) });
  return { status: response.status, body: (await response.json()) as Json };
};

/** The team object's own tables, as SQLite lists them. */
const objectTables = (teamId: string) =>
  runInDurableObject(env.TEAM.getByName(teamId), async (_, state) =>
    [
      ...state.storage.sql.exec<{ name: string }>(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE '\\_%' ESCAPE '\\'",
      ),
    ].map((row) => row.name),
  );

it('deletes the person, every session and a team only they were on, with its matches', async () => {
  const owner = await ownerWithTeam(h);
  const other = await h.signIn('owner@example.com');
  const created = await h.json(
    `/v1/teams/${owner.teamId}/matches`,
    { ...fixture.creation, id: 'game-1', deviceId: 'phone-a' },
    { headers: h.auth(owner.token) },
  );
  expect(created.status).toBe(201);
  expect(await objectTables(owner.teamId)).not.toEqual([]);

  const deleted = await deleteAccount(owner.token);
  expect(deleted.status).toBe(204);
  for (const token of [owner.token, other.token]) {
    expect((await h.call('/v1/me', { headers: h.auth(token) })).status).toBe(401);
    expect((await deleteAccount(token)).status).toBe(401);
  }
  for (const table of ['people', 'sessions', 'auth_tickets', 'teams', 'memberships', 'match_index'])
    expect(await count(table)).toBe(0);
  expect(await objectTables(owner.teamId)).toEqual([]);

  // Signing in again makes a new, empty account.
  const again = await h.signIn('owner@example.com');
  const me = (await (await h.call('/v1/me', { headers: h.auth(again.token) })).json()) as Json;
  expect(me.person.id).not.toBe(owner.personId);
  expect(me.teams).toEqual([]);
});

it('needs a session', async () => {
  expect((await h.call('/v1/me', { method: 'DELETE' })).status).toBe(401);
});

it('a team with other people keeps going: the longest-standing member becomes owner', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId);
  const first = await h.signIn('first@example.com', { invite: code });
  h.clock.now += 60_000;
  const second = await h.signIn('second@example.com', { invite: code });

  expect((await deleteAccount(owner.token)).status).toBe(204);
  const detail = await teamDetail(first.token, owner.teamId);
  expect(detail.status).toBe(200);
  expect(detail.body.role).toBe('owner');
  expect(detail.body.members.map((m: Json) => [m.email, m.role])).toEqual([
    ['first@example.com', 'owner'],
    ['second@example.com', 'member'],
  ]);
  expect((await teamDetail(second.token, owner.teamId)).body.role).toBe('member');
  expect(await count('people')).toBe(2);
});

it('another owner keeps the team as it is', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId);
  const member = await h.signIn('member@example.com', { invite: code });
  const coOwner = await h.signIn('co@example.com', { invite: code });
  await env.DB.prepare("UPDATE memberships SET role='owner' WHERE person_id=?")
    .bind(coOwner.personId)
    .run();

  expect((await deleteAccount(owner.token)).status).toBe(204);
  expect((await teamDetail(coOwner.token, owner.teamId)).body.role).toBe('owner');
  expect((await teamDetail(member.token, owner.teamId)).body.role).toBe('member');
});

it('a member leaves their teams, and invites to their email go with them', async () => {
  const owner = await ownerWithTeam(h);
  await invite(h, owner.token, owner.teamId, { email: 'parent@example.com' });
  const parent = await h.signIn('parent@example.com');
  expect((await teamDetail(parent.token, owner.teamId)).body.role).toBe('member');

  expect((await deleteAccount(parent.token)).status).toBe(204);
  const detail = await teamDetail(owner.token, owner.teamId);
  expect(detail.body.members.map((m: Json) => m.email)).toEqual(['owner@example.com']);
  expect(detail.body.invites).toEqual([]);
  // The invite is gone, so a new account with that email doesn't land back on the team.
  const again = await h.signIn('parent@example.com');
  const me = (await (await h.call('/v1/me', { headers: h.auth(again.token) })).json()) as Json;
  expect(me.teams).toEqual([]);
});
