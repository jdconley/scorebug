import { env } from 'cloudflare:test';
import { beforeEach, expect, it } from 'vitest';
import fixture from '../../../packages/protocol/fixtures/match-v1.json';
import { harness, invite, ownerWithTeam, type Harness } from './helpers.js';

type Credential = { gameId: string; deviceId: string; role: string; token: string };
let h: Harness;
beforeEach(() => {
  h = harness();
});

const creation = (id = 'game-1', deviceId = 'phone-a') => ({ ...fixture.creation, id, deviceId });

async function createMatch(token: string, teamId: string, id = 'game-1', deviceId = 'phone-a') {
  return h.json(`/v1/teams/${teamId}/matches`, creation(id, deviceId), {
    headers: h.auth(token),
  });
}

function point(credential: Credential, expectedRevision = 0) {
  return h.json(
    `/v1/matches/${credential.gameId}/commands`,
    {
      ...fixture.command,
      commandId: `point-${expectedRevision}`,
      gameId: credential.gameId,
      deviceId: credential.deviceId,
      expectedRevision,
      issuedAt: new Date().toISOString(),
    },
    { headers: h.auth(credential.token) },
  );
}

it('member creates and scores a match', async () => {
  const owner = await ownerWithTeam(h);
  const { code } = await invite(h, owner.token, owner.teamId);
  const member = await h.signIn('parent@example.com', { invite: code });
  const created = await createMatch(member.token, owner.teamId);
  expect(created.status).toBe(201);
  const body = (await created.json()) as { credential: Credential; snapshot: { id: string } };
  expect(body.credential.role).toBe('score');
  expect(body.snapshot.id).toBe('game-1');
  const scored = await point(body.credential);
  expect(scored.status).toBe(200);
  expect(await scored.json()).toMatchObject({
    accepted: true,
    snapshot: { revision: 1, score: { home: 1 } },
  });
  const read = await h.call('/v1/matches/game-1', { headers: h.auth(body.credential.token) });
  expect(await read.json()).toMatchObject({ snapshot: { revision: 1 } });
  const active = await h.call(`/v1/teams/${owner.teamId}/matches/active`, {
    headers: h.auth(owner.token),
  });
  expect(await active.json()).toMatchObject({ snapshot: { id: 'game-1' } });
});

it('retrying a create with the same id is idempotent', async () => {
  const owner = await ownerWithTeam(h);
  expect((await createMatch(owner.token, owner.teamId)).status).toBe(201);
  expect((await createMatch(owner.token, owner.teamId)).status).toBe(201);
});

it('second concurrent create sees active match', async () => {
  const owner = await ownerWithTeam(h);
  const [a, b] = await Promise.all([
    createMatch(owner.token, owner.teamId, 'game-a', 'phone-a'),
    createMatch(owner.token, owner.teamId, 'game-b', 'phone-b'),
  ]);
  const statuses = [a.status, b.status].sort();
  expect(statuses).toEqual([201, 409]);
  const loser = a.status === 409 ? a : b;
  const winner = a.status === 201 ? a : b;
  const winnerId = ((await winner.json()) as { snapshot: { id: string } }).snapshot.id;
  expect(await loser.json()).toMatchObject({
    error: 'match_in_flight',
    snapshot: { id: winnerId },
  });
  // The loser's match id is free again for the team.
  const loserId = winnerId === 'game-a' ? 'game-b' : 'game-a';
  const index = await env.DB.prepare('SELECT team_id FROM match_index WHERE game_id=?')
    .bind(loserId)
    .first();
  expect(index).toBeNull();
});

it('match id taken by another team', async () => {
  const a = await ownerWithTeam(h, 'a@example.com', 'Wildcats');
  const b = await ownerWithTeam(h, 'b@example.com', 'Hawks');
  expect((await createMatch(a.token, a.teamId, 'shared-id')).status).toBe(201);
  const taken = await createMatch(b.token, b.teamId, 'shared-id');
  expect(taken.status).toBe(409);
  expect(await taken.json()).toEqual({ error: 'match_id_taken' });
  // Team B's object never saw it, and team A's match is untouched.
  const bActive = await h.call(`/v1/teams/${b.teamId}/matches/active`, {
    headers: h.auth(b.token),
  });
  expect(await bActive.json()).toMatchObject({ snapshot: null });
});

it('non-member cannot see a team active match', async () => {
  const owner = await ownerWithTeam(h);
  await createMatch(owner.token, owner.teamId);
  const other = await h.signIn('other@example.com');
  const response = await h.call(`/v1/teams/${owner.teamId}/matches/active`, {
    headers: h.auth(other.token),
  });
  expect(response.status).toBe(404);
  expect(await response.json()).toEqual({ error: 'team_not_found' });
  expect((await h.call(`/v1/teams/${owner.teamId}/matches/active`)).status).toBe(401);
});

it('spoofed member header is overwritten', async () => {
  const owner = await ownerWithTeam(h);
  await createMatch(owner.token, owner.teamId);
  const other = await h.signIn('other@example.com');
  const spoofed = await h.call(`/v1/teams/${owner.teamId}/matches/active`, {
    headers: { ...h.auth(other.token), 'x-scorebug-member': owner.personId },
  });
  expect(spoofed.status).toBe(404);
  // Match-token routes drop the header: it can't mint credentials through join.
  const join = await h.json(
    '/v1/matches/game-1/join',
    { deviceId: 'thief', role: 'score' },
    { headers: { 'x-scorebug-member': owner.personId } },
  );
  expect(join.status).toBe(401);
});

it('teams are isolated', async () => {
  const a = await ownerWithTeam(h, 'a@example.com', 'Wildcats');
  const b = await ownerWithTeam(h, 'b@example.com', 'Hawks');
  const aBody = (await (await createMatch(a.token, a.teamId, 'game-a')).json()) as {
    credential: Credential;
  };
  await createMatch(b.token, b.teamId, 'game-b', aBody.credential.deviceId);
  const crossed = await h.call('/v1/matches/game-b', {
    headers: h.auth(aBody.credential.token),
  });
  expect(crossed.status).toBe(401);
  const unknown = await h.call('/v1/matches/nope', { headers: h.auth(aBody.credential.token) });
  expect(unknown.status).toBe(404);
  expect(await unknown.json()).toEqual({ error: 'match_not_found' });
});

it('match join code works without an account', async () => {
  const owner = await ownerWithTeam(h);
  await createMatch(owner.token, owner.teamId);
  const minted = await h.json(
    `/v1/teams/${owner.teamId}/matches/game-1/invites`,
    {},
    { headers: h.auth(owner.token) },
  );
  expect(minted.status).toBe(201);
  const { code, link } = (await minted.json()) as { code: string; link: string };
  expect(link.startsWith('https://scorebug.live/join/')).toBe(true);
  const redeemed = await h.json('/v1/invites/redeem', { code, deviceId: 'helper-phone' });
  expect(redeemed.status).toBe(200);
  const body = (await redeemed.json()) as { credential: Credential };
  expect(body.credential).toMatchObject({ gameId: 'game-1', role: 'score' });
  const stored = await env.DB.prepare('SELECT code_hash FROM match_codes').first<{
    code_hash: string;
  }>();
  expect(stored?.code_hash).toMatch(/^[a-f0-9]{64}$/);
});

it('revoked match code stops routing', async () => {
  const owner = await ownerWithTeam(h);
  await createMatch(owner.token, owner.teamId);
  const minted = (await (
    await h.json(
      `/v1/teams/${owner.teamId}/matches/game-1/invites`,
      {},
      { headers: h.auth(owner.token) },
    )
  ).json()) as { code: string; invite: { id: string } };
  const revoked = await h.call(
    `/v1/teams/${owner.teamId}/matches/game-1/invites/${minted.invite.id}`,
    { method: 'DELETE', headers: h.auth(owner.token) },
  );
  expect(revoked.status).toBe(200);
  const redeemed = await h.json('/v1/invites/redeem', { code: minted.code, deviceId: 'helper' });
  expect(redeemed.status).toBe(404);
  expect(await redeemed.json()).toEqual({ error: 'invite_invalid' });
  expect((await h.json('/v1/invites/redeem', { code: 'bad', deviceId: 'x' })).status).toBe(404);
});

it('recording report is accepted', async () => {
  const owner = await ownerWithTeam(h);
  await createMatch(owner.token, owner.teamId);
  const joined = await h.json(
    `/v1/teams/${owner.teamId}/matches/game-1/join`,
    { deviceId: 'camera-phone', role: 'capture' },
    { headers: h.auth(owner.token) },
  );
  expect(joined.status).toBe(200);
  const { credential } = (await joined.json()) as { credential: Credential };
  expect(credential.role).toBe('capture');
  const report = await h.json(
    '/v1/matches/game-1/media/recordings',
    {
      recordingId: 'rec-1',
      sequence: 0,
      status: 'recording',
      startedAt: new Date().toISOString(),
    },
    { headers: h.auth(credential.token) },
  );
  expect(report.status).toBe(200);
  expect(await report.json()).toMatchObject({ recording: { recordingId: 'rec-1' } });
});

it('a refused create keeps the claim of a match that exists', async () => {
  const owner = await ownerWithTeam(h);
  expect((await createMatch(owner.token, owner.teamId)).status).toBe(201);
  // As if a concurrent same-ID create won the race without this request's claim.
  await env.DB.prepare('DELETE FROM match_index').run();
  const different = await h.json(
    `/v1/teams/${owner.teamId}/matches`,
    { ...creation(), rules: { ...fixture.creation.rules, pointsToWin: 21 } },
    { headers: h.auth(owner.token) },
  );
  expect(different.status).toBe(409);
  expect(await different.json()).toMatchObject({ error: 'match_id_reused' });
  const row = await env.DB.prepare('SELECT team_id FROM match_index WHERE game_id=?')
    .bind('game-1')
    .first<{ team_id: string }>();
  expect(row?.team_id).toBe(owner.teamId);
});

it('a join code collides across teams only while the other team holds it live', async () => {
  const { memberAccess } = await import('../src/worker/team-object.js');
  const routeFor = (team: string) => memberAccess(env, () => team).onInvite!;
  const later = new Date(Date.now() + 60_000).toISOString();
  const issue = (team: string, inviteId: string, expiresAt = later) =>
    routeFor(team).issued({ inviteId, code: 'ABC234', gameId: `${team}-game`, expiresAt });
  await issue('team-a', 'invite-a');
  await expect(issue('team-b', 'invite-b')).rejects.toThrow('another team');
  await env.DB.prepare("UPDATE match_codes SET expires_at=1 WHERE invite_id='invite-a'").run();
  await issue('team-b', 'invite-b');
  const row = await env.DB.prepare('SELECT team_id, invite_id FROM match_codes').first();
  expect(row).toEqual({ team_id: 'team-b', invite_id: 'invite-b' });
});
