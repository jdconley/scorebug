-- Everything that crosses teams. Each team's matches live in its TeamObject.
CREATE TABLE people(
  id TEXT PRIMARY KEY,
  google_sub TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL,
  name TEXT,
  picture TEXT,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);
CREATE INDEX people_email ON people(email);

-- The private beta list. Emails are stored trimmed and lowercased.
CREATE TABLE beta_access(
  email TEXT PRIMARY KEY,
  can_create_teams INTEGER NOT NULL DEFAULT 1,
  added_by TEXT NOT NULL,
  added_at INTEGER NOT NULL
);

-- Only the SHA-256 hex of a session token is stored.
CREATE TABLE sessions(
  token_hash TEXT PRIMARY KEY,
  person_id TEXT NOT NULL REFERENCES people(id),
  device_name TEXT,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX sessions_person ON sessions(person_id);

-- Single-use sign-in tickets, bound to the SHA-256 of the app's verifier.
CREATE TABLE auth_tickets(
  ticket_hash TEXT PRIMARY KEY,
  challenge TEXT NOT NULL,
  person_id TEXT NOT NULL REFERENCES people(id),
  expires_at INTEGER NOT NULL,
  used_at INTEGER
);

CREATE TABLE teams(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  short_name TEXT NOT NULL,
  color TEXT NOT NULL,
  created_by TEXT NOT NULL REFERENCES people(id),
  created_at INTEGER NOT NULL
);

CREATE TABLE memberships(
  team_id TEXT NOT NULL REFERENCES teams(id),
  person_id TEXT NOT NULL REFERENCES people(id),
  role TEXT NOT NULL CHECK(role IN ('owner','member')),
  created_at INTEGER NOT NULL,
  PRIMARY KEY(team_id, person_id)
);
CREATE INDEX memberships_person ON memberships(person_id);

CREATE TABLE team_invites(
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id),
  code_hash TEXT NOT NULL UNIQUE,
  email TEXT,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX team_invites_team ON team_invites(team_id);
CREATE INDEX team_invites_email ON team_invites(email);

-- Routes match-token traffic to the team object that owns the match.
CREATE TABLE match_index(
  game_id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id),
  created_at INTEGER NOT NULL
);

-- Routes match join codes (no account needed) to their team object.
CREATE TABLE match_codes(
  code_hash TEXT PRIMARY KEY,
  invite_id TEXT NOT NULL UNIQUE,
  team_id TEXT NOT NULL,
  game_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
