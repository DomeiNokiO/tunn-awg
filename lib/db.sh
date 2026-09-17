#!/usr/bin/env bash
# SQLite schema init.

db_init() {
    mkdir -p "$(dirname "$TUNN_DB")"
    sqlite3 "$TUNN_DB" >/dev/null <<'EOF'
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type TEXT NOT NULL CHECK(type IN ('wg','l2tp')),
    name TEXT NOT NULL,
    ip TEXT DEFAULT '',
    pubkey TEXT DEFAULT '',
    created_at TEXT DEFAULT (datetime('now')),
    expires_at TEXT,
    quota_bytes INTEGER DEFAULT 0,
    used_bytes INTEGER DEFAULT 0,
    suspended INTEGER DEFAULT 0,
    notes TEXT DEFAULT '',
    UNIQUE(type, name)
);

CREATE TABLE IF NOT EXISTS ppp_sessions (
    iface TEXT PRIMARY KEY,
    peer_ip TEXT,
    rx INTEGER DEFAULT 0,
    tx INTEGER DEFAULT 0,
    seen_at TEXT
);

CREATE TABLE IF NOT EXISTS port_forwards (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    proto TEXT NOT NULL,
    vps_port INTEGER NOT NULL,
    dest TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS admin_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT DEFAULT (datetime('now')),
    admin_id INTEGER,
    action TEXT,
    args TEXT
);

CREATE TABLE IF NOT EXISTS peer_state (
    key TEXT PRIMARY KEY,
    online INTEGER DEFAULT 0,
    last_change TEXT
);
EOF
    chmod 640 "$TUNN_DB"
}
