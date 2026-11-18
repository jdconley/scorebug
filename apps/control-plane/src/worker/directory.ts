import { randomUUID } from 'node:crypto';
import { normalizeEmail, randomToken, sha256Hex } from './state.js';

/** D1: everything that crosses teams. Emails are stored and compared normalized. */
export type Person = { id: string; email: string; name: string | null; picture: string | null };
export type TeamRole = 'owner' | 'member';
export type Team = {
  id: string;
  name: string;
  shortName: string;
  color: string;
  createdAt: string;
};
export type TeamInvite = {
  id: string;
  teamId: string;
  email: string | null;
  createdAt: string;
  expiresAt: string;
  revokedAt: string | null;
};
type PersonRow = {
  id: string;
  google_sub: string;
  email: string;
  name: string | null;
  picture: string | null;
};
type TeamRow = { id: string; name: string; short_name: string; color: string; created_at: number };
export type TeamInviteRow = {
  id: string;
  team_id: string;
  code_hash: string;
  email: string | null;
  created_by: string;
  created_at: number;
  expires_at: number;
  revoked_at: number | null;
};
export type Identity = {
  sub: string;
  email: string;
  name: string | null;
  picture: string | null;
};

export const TICKET_TTL_MS = 2 * 60 * 1000;
export const ADMIN_DEVICE_NAME = 'admin web';
const LAST_USED_RESOLUTION_MS = 60 * 1000;
const iso = (ms: number) => new Date(ms).toISOString();

export const personView = (row: PersonRow): Person => ({
  id: row.id,
  email: row.email,
  name: row.name,
  picture: row.picture,
});
export const teamView = (row: TeamRow): Team => ({
  id: row.id,
  name: row.name,
  shortName: row.short_name,
  color: row.color,
  createdAt: iso(row.created_at),
});
export const inviteView = (row: TeamInviteRow): TeamInvite => ({
  id: row.id,
  teamId: row.team_id,
  email: row.email,
  createdAt: iso(row.created_at),
  expiresAt: iso(row.expires_at),
  revokedAt: row.revoked_at === null ? null : iso(row.revoked_at),
});

export class Directory {
  constructor(
    readonly db: D1Database,
    readonly now: () => number = Date.now,
  ) {}

  // ----------------------------------------------------------------- people

  async person(id: string): Promise<Person | null> {
    const row = await this.db
      .prepare('SELECT * FROM people WHERE id=?')
      .bind(id)
      .first<PersonRow>();
    return row ? personView(row) : null;
  }

  async upsertPerson(identity: Identity): Promise<Person> {
    const now = this.now();
    const row = await this.db
      .prepare(
        `INSERT INTO people(id,google_sub,email,name,picture,created_at,last_seen_at) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(google_sub) DO UPDATE SET email=excluded.email, name=excluded.name,
          picture=excluded.picture, last_seen_at=excluded.last_seen_at
        RETURNING *`,
      )
      .bind(
        randomUUID(),
        identity.sub,
        normalizeEmail(identity.email),
        identity.name,
        identity.picture,
        now,
        now,
      )
      .first<PersonRow>();
    return personView(row!);
  }

  // --------------------------------------------------------------- sessions

  async createSession(personId: string, deviceName: string | null): Promise<string> {
    const token = randomToken();
    const now = this.now();
    await this.db
      .prepare(
        'INSERT INTO sessions(token_hash,person_id,device_name,created_at,last_used_at) VALUES(?,?,?,?,?)',
      )
      .bind(sha256Hex(token), personId, deviceName, now, now)
      .run();
    return token;
  }

  /** The person a session token belongs to, or null (unknown or revoked). */
  async sessionPerson(token: string): Promise<Person | null> {
    if (!token) return null;
    const hash = sha256Hex(token);
    const row = await this.db
      .prepare(
        `SELECT people.*, sessions.last_used_at AS session_used FROM sessions
        JOIN people ON people.id=sessions.person_id WHERE token_hash=? AND revoked_at IS NULL`,
      )
      .bind(hash)
      .first<PersonRow & { session_used: number }>();
    if (!row) return null;
    const now = this.now();
    if (now - row.session_used >= LAST_USED_RESOLUTION_MS)
      await this.db
        .prepare('UPDATE sessions SET last_used_at=? WHERE token_hash=?')
        .bind(now, hash)
        .run();
    return personView(row);
  }

  /** An admin web session: made by the admin sign-in, unrevoked and younger than `maxAgeMs`. */
  async adminSessionPerson(token: string, maxAgeMs: number): Promise<Person | null> {
    if (!token) return null;
    const row = await this.db
      .prepare(
        `SELECT people.* FROM sessions JOIN people ON people.id=sessions.person_id
        WHERE token_hash=? AND revoked_at IS NULL AND device_name=? AND sessions.created_at>?`,
      )
      .bind(sha256Hex(token), ADMIN_DEVICE_NAME, this.now() - maxAgeMs)
      .first<PersonRow>();
    return row ? personView(row) : null;
  }

  async revokeSession(token: string): Promise<void> {
    await this.db
      .prepare('UPDATE sessions SET revoked_at=? WHERE token_hash=? AND revoked_at IS NULL')
      .bind(this.now(), sha256Hex(token))
      .run();
  }

  // ---------------------------------------------------------------- tickets

  async createTicket(personId: string, challenge: string): Promise<string> {
    const ticket = randomToken();
    await this.db
      .prepare(
        'INSERT INTO auth_tickets(ticket_hash,challenge,person_id,expires_at) VALUES(?,?,?,?)',
      )
      .bind(sha256Hex(ticket), challenge, personId, this.now() + TICKET_TTL_MS)
      .run();
    return ticket;
  }

  /** Single use: marks the ticket used and returns its person, or null. */
  async redeemTicket(ticket: string, challenge: string): Promise<string | null> {
    const now = this.now();
    const row = await this.db
      .prepare(
        `UPDATE auth_tickets SET used_at=? WHERE ticket_hash=? AND challenge=? AND used_at IS NULL
        AND expires_at>? RETURNING person_id`,
      )
      .bind(now, sha256Hex(ticket), challenge, now)
      .first<{ person_id: string }>();
    // Expired and used tickets are useless; drop them now and then.
    await this.db
      .prepare('DELETE FROM auth_tickets WHERE expires_at<?')
      .bind(now - 24 * 60 * 60 * 1000)
      .run();
    return row?.person_id ?? null;
  }

  // ------------------------------------------------------------------ teams

  async teamsFor(personId: string): Promise<(Team & { role: TeamRole })[]> {
    const { results } = await this.db
      .prepare(
        `SELECT teams.*, memberships.role FROM memberships JOIN teams ON teams.id=memberships.team_id
        WHERE memberships.person_id=? ORDER BY teams.created_at, teams.id`,
      )
      .bind(personId)
      .all<TeamRow & { role: TeamRole }>();
    return results.map((row) => ({ ...teamView(row), role: row.role }));
  }

  async createTeam(
    personId: string,
    fields: { name: string; shortName: string; color: string },
  ): Promise<Team> {
    const id = randomUUID();
    const now = this.now();
    await this.db.batch([
      this.db
        .prepare('INSERT INTO teams(id,name,short_name,color,created_at) VALUES(?,?,?,?,?)')
        .bind(id, fields.name, fields.shortName, fields.color, now),
      this.db
        .prepare("INSERT INTO memberships(team_id,person_id,role,created_at) VALUES(?,?,'owner',?)")
        .bind(id, personId, now),
    ]);
    return (await this.team(id))!;
  }

  async team(id: string): Promise<Team | null> {
    const row = await this.db.prepare('SELECT * FROM teams WHERE id=?').bind(id).first<TeamRow>();
    return row ? teamView(row) : null;
  }

  async updateTeam(
    id: string,
    patch: {
      name?: string | undefined;
      shortName?: string | undefined;
      color?: string | undefined;
    },
  ): Promise<Team> {
    await this.db
      .prepare(
        'UPDATE teams SET name=coalesce(?,name), short_name=coalesce(?,short_name), color=coalesce(?,color) WHERE id=?',
      )
      .bind(patch.name ?? null, patch.shortName ?? null, patch.color ?? null, id)
      .run();
    return (await this.team(id))!;
  }

  async membership(teamId: string, personId: string): Promise<TeamRole | null> {
    const row = await this.db
      .prepare('SELECT role FROM memberships WHERE team_id=? AND person_id=?')
      .bind(teamId, personId)
      .first<{ role: TeamRole }>();
    return row?.role ?? null;
  }

  async members(
    teamId: string,
  ): Promise<{ personId: string; name: string | null; email: string; role: TeamRole }[]> {
    const { results } = await this.db
      .prepare(
        `SELECT people.id, people.name, people.email, memberships.role FROM memberships
        JOIN people ON people.id=memberships.person_id WHERE team_id=?
        ORDER BY memberships.role DESC, memberships.created_at, people.id`,
      )
      .bind(teamId)
      .all<{ id: string; name: string | null; email: string; role: TeamRole }>();
    return results.map((r) => ({ personId: r.id, name: r.name, email: r.email, role: r.role }));
  }

  /**
   * Removes a membership unless it would leave the team without an owner. One statement, so
   * two owners leaving at once can't both succeed. Email invites for the person on this team
   * are revoked too, so their next sign-in does not put them back.
   */
  async removeMember(
    teamId: string,
    personId: string,
  ): Promise<'removed' | 'not_found' | 'last_owner'> {
    const result = await this.db
      .prepare(
        `DELETE FROM memberships WHERE team_id=?1 AND person_id=?2 AND (role='member' OR
        (SELECT COUNT(*) FROM memberships WHERE team_id=?1 AND role='owner')>1)`,
      )
      .bind(teamId, personId)
      .run();
    if (result.meta.changes > 0) {
      await this.db
        .prepare(
          `UPDATE team_invites SET revoked_at=? WHERE team_id=? AND revoked_at IS NULL
          AND email=(SELECT email FROM people WHERE id=?)`,
        )
        .bind(this.now(), teamId, personId)
        .run();
      return 'removed';
    }
    return (await this.membership(teamId, personId)) ? 'last_owner' : 'not_found';
  }

  /** The person's teams, with how many members and owners each has. */
  async membershipsWithCounts(
    personId: string,
  ): Promise<{ teamId: string; role: TeamRole; members: number; owners: number }[]> {
    const { results } = await this.db
      .prepare(
        `SELECT m.team_id, m.role,
          (SELECT COUNT(*) FROM memberships x WHERE x.team_id=m.team_id) AS members,
          (SELECT COUNT(*) FROM memberships x WHERE x.team_id=m.team_id AND x.role='owner') AS owners
        FROM memberships m WHERE m.person_id=?`,
      )
      .bind(personId)
      .all<{ team_id: string; role: TeamRole; members: number; owners: number }>();
    return results.map((r) => ({
      teamId: r.team_id,
      role: r.role,
      members: r.members,
      owners: r.owners,
    }));
  }

  /**
   * Deletes a person and everything D1 holds about them, in one transaction: their sessions,
   * sign-in tickets, YouTube grants and connections (teams streaming to one lose their channel),
   * invites bound to their email, and their memberships. `eraseTeams` (teams with no one else on
   * them) go too, with their invites and match routing. On every other team they owned alone,
   * the longest-standing member becomes the owner.
   */
  async deletePerson(person: Person, eraseTeams: string[]): Promise<void> {
    const db = this.db;
    const id = person.id;
    const erase = eraseTeams.flatMap((teamId) => [
      db.prepare('DELETE FROM team_invites WHERE team_id=?').bind(teamId),
      db.prepare('DELETE FROM match_codes WHERE team_id=?').bind(teamId),
      db.prepare('DELETE FROM match_index WHERE team_id=?').bind(teamId),
      db.prepare('DELETE FROM live_slots WHERE team_id=?').bind(teamId),
      db.prepare('DELETE FROM memberships WHERE team_id=?').bind(teamId),
      db.prepare('DELETE FROM teams WHERE id=?').bind(teamId),
    ]);
    await db.batch([
      ...erase,
      db
        .prepare(
          `UPDATE memberships SET role='owner'
          WHERE person_id=(SELECT heir.person_id FROM memberships heir
            WHERE heir.team_id=memberships.team_id AND heir.person_id<>?1
            ORDER BY heir.created_at, heir.person_id LIMIT 1)
          AND team_id IN (SELECT mine.team_id FROM memberships mine
            WHERE mine.person_id=?1 AND mine.role='owner' AND NOT EXISTS(
              SELECT 1 FROM memberships other WHERE other.team_id=mine.team_id
              AND other.role='owner' AND other.person_id<>?1))`,
        )
        .bind(id),
      db.prepare('DELETE FROM memberships WHERE person_id=?').bind(id),
      db.prepare('DELETE FROM team_invites WHERE email=?').bind(normalizeEmail(person.email)),
      db
        .prepare(
          `UPDATE teams SET youtube_connection_id=NULL WHERE youtube_connection_id IN
          (SELECT id FROM youtube_connections WHERE person_id=?)`,
        )
        .bind(id),
      db.prepare('DELETE FROM youtube_connections WHERE person_id=?').bind(id),
      db.prepare('DELETE FROM youtube_grants WHERE person_id=?').bind(id),
      db.prepare('DELETE FROM auth_tickets WHERE person_id=?').bind(id),
      db.prepare('DELETE FROM sessions WHERE person_id=?').bind(id),
      db.prepare('DELETE FROM people WHERE id=?').bind(id),
    ]);
  }

  async teamsWithCounts(): Promise<(Team & { members: number; owners: number })[]> {
    const { results } = await this.db
      .prepare(
        `SELECT teams.*, COUNT(memberships.person_id) AS members,
          SUM(CASE WHEN memberships.role='owner' THEN 1 ELSE 0 END) AS owners
        FROM teams LEFT JOIN memberships ON memberships.team_id=teams.id
        GROUP BY teams.id ORDER BY teams.created_at, teams.id`,
      )
      .all<TeamRow & { members: number; owners: number }>();
    return results.map((row) => ({ ...teamView(row), members: row.members, owners: row.owners }));
  }

  // ----------------------------------------------------------- team invites

  /** Unexpired, unrevoked invites bound to this email. */
  async emailInvites(email: string): Promise<TeamInviteRow[]> {
    const { results } = await this.db
      .prepare('SELECT * FROM team_invites WHERE email=? AND revoked_at IS NULL AND expires_at>?')
      .bind(normalizeEmail(email), this.now())
      .all<TeamInviteRow>();
    return results;
  }

  /** An unexpired, unrevoked invite for a code hash, or null. */
  liveInviteByHash(codeHash: string): Promise<TeamInviteRow | null> {
    return this.db
      .prepare(
        'SELECT * FROM team_invites WHERE code_hash=? AND revoked_at IS NULL AND expires_at>?',
      )
      .bind(codeHash, this.now())
      .first<TeamInviteRow>();
  }

  async teamInvites(teamId: string): Promise<TeamInvite[]> {
    const { results } = await this.db
      .prepare('SELECT * FROM team_invites WHERE team_id=? ORDER BY created_at DESC, id')
      .bind(teamId)
      .all<TeamInviteRow>();
    return results.map(inviteView);
  }

  async liveInviteCount(teamId: string): Promise<number> {
    const row = await this.db
      .prepare(
        'SELECT COUNT(*) AS n FROM team_invites WHERE team_id=? AND revoked_at IS NULL AND expires_at>?',
      )
      .bind(teamId, this.now())
      .first<{ n: number }>();
    return row?.n ?? 0;
  }

  /** False when the code hash is already taken (the caller retries with a new code). */
  async insertInvite(row: Omit<TeamInviteRow, 'revoked_at'>): Promise<boolean> {
    const result = await this.db
      .prepare(
        `INSERT INTO team_invites(id,team_id,code_hash,email,created_by,created_at,expires_at)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(code_hash) DO NOTHING`,
      )
      .bind(
        row.id,
        row.team_id,
        row.code_hash,
        row.email,
        row.created_by,
        row.created_at,
        row.expires_at,
      )
      .run();
    return result.meta.changes > 0;
  }

  async revokeInvite(teamId: string, inviteId: string): Promise<TeamInvite | null> {
    await this.db
      .prepare(
        'UPDATE team_invites SET revoked_at=? WHERE team_id=? AND id=? AND revoked_at IS NULL',
      )
      .bind(this.now(), teamId, inviteId)
      .run();
    const row = await this.db
      .prepare('SELECT * FROM team_invites WHERE team_id=? AND id=?')
      .bind(teamId, inviteId)
      .first<TeamInviteRow>();
    return row ? inviteView(row) : null;
  }

  /** Joins as a member; an existing membership (and its role) is kept. */
  async join(teamId: string, personId: string): Promise<void> {
    await this.db
      .prepare(
        "INSERT INTO memberships(team_id,person_id,role,created_at) VALUES(?,?,'member',?) ON CONFLICT DO NOTHING",
      )
      .bind(teamId, personId, this.now())
      .run();
  }
}
