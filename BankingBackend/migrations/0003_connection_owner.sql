-- Several invited users: each connection records a digest of its owner's Supabase ID.
-- Existing rows keep NULL and remain the configured owner's, so nobody has to reconnect.
ALTER TABLE connections ADD COLUMN owner TEXT;
CREATE INDEX connections_owner ON connections(owner, mode, expires_at);
