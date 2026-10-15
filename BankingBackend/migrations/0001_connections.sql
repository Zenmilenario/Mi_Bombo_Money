-- No bank passwords, transaction history, raw consent state or bearer tokens.
CREATE TABLE auth_requests (
    id TEXT PRIMARY KEY,
    state_hash TEXT NOT NULL UNIQUE,
    encrypted_data TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    claimed INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX auth_expiry ON auth_requests(expires_at);
CREATE TABLE connections (
    id TEXT PRIMARY KEY,
    mode TEXT NOT NULL CHECK(mode IN ('demo', 'sandbox')),
    encrypted_data TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE TABLE rate_limits (
    bucket TEXT PRIMARY KEY,
    count INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
