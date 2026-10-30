-- Preserve the existing encrypted demo/sandbox sessions. Production uses a separate D1.
CREATE TABLE connections_next (
    id TEXT PRIMARY KEY,
    mode TEXT NOT NULL CHECK(mode IN ('demo', 'sandbox', 'production')),
    encrypted_data TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
INSERT INTO connections_next SELECT * FROM connections;
DROP TABLE connections;
ALTER TABLE connections_next RENAME TO connections;
