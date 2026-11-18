import type { Context } from 'hono';
import type { PersonEnv } from './env.js';
import type { GoogleOAuth } from './google.js';
import { channels } from './youtube-routes.js';

/**
 * Deletes the signed-in person's account for good (DELETE /v1/me).
 *
 * - Teams with no one else on them are deleted, with their matches and channel binding.
 * - On teams with other people the person just leaves; if they were the only owner, the
 *   longest-standing member becomes the owner, so the team keeps working.
 * - Every match broadcasting to one of their YouTube channels stops first and its broadcast
 *   ends, while the stored token still works. Then Google's grants are revoked (best effort)
 *   and the stored tokens deleted.
 * - Sessions go last, with the person, so every token stops working.
 */
export async function deleteAccount(c: Context<PersonEnv>, google: GoogleOAuth): Promise<void> {
  const person = c.var.person;
  const dir = c.var.directory;
  const store = channels(c, dir.now);
  const [memberships, connections, streaming] = await Promise.all([
    dir.membershipsWithCounts(person.id),
    store.connections(person.id),
    store.teamsOnConnectionsOf(person.id),
  ]);
  const erase = memberships.filter((m) => m.members === 1).map((m) => m.teamId);
  const erased = new Set(erase);
  for (const teamId of erase) await c.env.TEAM.getByName(teamId).erase(teamId);
  if (connections.length > 0) {
    const ids = connections.map((connection) => connection.id);
    const teams = new Set([...memberships.map((m) => m.teamId), ...streaming]);
    for (const teamId of teams)
      if (!erased.has(teamId)) await c.env.TEAM.getByName(teamId).releaseConnections(teamId, ids);
  }
  for (const token of await store.refreshTokensFor(person.id)) {
    try {
      await google.revoke(token);
    } catch (error) {
      console.warn('google_revoke_failed', String(error));
    }
  }
  await dir.deletePerson(person, erase);
  console.log('account_deleted', erase.length);
}
