-- Beta list for the screenshot tour: both can create teams.
INSERT OR IGNORE INTO beta_access(email, can_create_teams, added_by, added_at) VALUES
  ('jd@example.com', 1, 'tour', 0),
  ('coach@example.com', 1, 'tour', 0);
