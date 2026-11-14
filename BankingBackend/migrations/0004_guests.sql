-- Invited people kept in the database, so adding one no longer needs a redeploy (npm run guests -- add <id> --db).
-- Only their Supabase ID, in lower case. SUPABASE_GUEST_IDS keeps working alongside.
CREATE TABLE guests (
  id TEXT PRIMARY KEY CHECK (length(id) = 36 AND id = lower(id)),
  added_at INTEGER NOT NULL
);
