-- YouTube channel connections, the team channel, and the beta-wide live cap.

-- A grant waiting for the app to claim it: the callback stores it, and the signed-in app
-- redeems the single-use ticket. Only the SHA-256 of the ticket is kept.
CREATE TABLE youtube_grants(
  ticket_hash TEXT PRIMARY KEY,
  person_id TEXT NOT NULL REFERENCES people(id),
  refresh_token_enc TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

-- One per channel a person connected. Secrets (refresh token, ingest URL with its stream key)
-- are AES-GCM encrypted with a key derived from SERVER_SECRET.
CREATE TABLE youtube_connections(
  id TEXT PRIMARY KEY,
  person_id TEXT NOT NULL REFERENCES people(id),
  channel_id TEXT NOT NULL,
  channel_title TEXT NOT NULL,
  channel_thumbnail TEXT,
  refresh_token_enc TEXT NOT NULL,
  stream_id TEXT,
  ingest_enc TEXT,
  status TEXT NOT NULL CHECK(status IN ('ready','live_disabled','needs_reconnect')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(person_id, channel_id)
);
CREATE INDEX youtube_connections_person ON youtube_connections(person_id);

-- The owner's connection this team streams to; NULL until an owner picks one.
ALTER TABLE teams ADD COLUMN youtube_connection_id TEXT REFERENCES youtube_connections(id);

-- Matches with a running (or starting) match container. A team object renews its row every
-- alarm; rows not renewed for a few minutes no longer count against the cap.
CREATE TABLE live_slots(
  game_id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL,
  claimed_at INTEGER NOT NULL,
  renewed_at INTEGER NOT NULL
);
