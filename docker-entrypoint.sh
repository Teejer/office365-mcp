#!/bin/sh
# Entrypoint wrapper for the office365-mcp container.
#
# Why this exists: the upstream package's MSAL cache plugin
# (~/.mcp-office365/tokens.json) has no cross-process locking and writes the
# file non-atomically. Microsoft refresh tokens are single-use (each refresh
# consumes the old one), so if two containers share a mounted state dir, the
# losing refresh hits invalid_grant/bad_token, Entra can revoke the whole token
# family, and msal-node then persists a cache *without* the refresh token —
# silently logging every session out. A killed mid-write can also corrupt
# tokens.json, which the plugin's loader treats as "no cached account".
#
# This wrapper defends against both from the outside:
#   1. flock (non-blocking) on the state dir — a second container exits with a
#      clear message instead of racing the first one's token refreshes.
#   2. Startup validation of tokens.json — if it is corrupt but the rolling
#      backup is valid, the backup is restored before the server starts.
#   3. A 60s background loop keeps tokens.json.bak rolling while the container
#      runs (same uid as the writer, so no host-side cron/permissions needed).
set -eu

STATE_DIR="/home/appuser/.mcp-office365"
TOKENS="$STATE_DIR/tokens.json"
BACKUP="$TOKENS.bak"
LOCK_FILE="$STATE_DIR/.instance.lock"

valid_json() {
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$1" 2>/dev/null
}

mkdir -p "$STATE_DIR"

# --- single-instance lock -----------------------------------------------------
# The fd stays open across the exec (lock is held for the container's lifetime)
# and is shared across containers because the bind-mounted file is one inode.
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    echo "office365-mcp: another office365-mcp container is already using $STATE_DIR." >&2
    echo "Microsoft rotates refresh tokens on every refresh, and the token cache has" >&2
    echo "no cross-process locking: running both at once WILL eventually revoke the" >&2
    echo "saved login. Stop the other container (docker ps | grep office365-mcp) and" >&2
    echo "retry, or give the second session its own state dir + a fresh 'auth' login." >&2
    exit 1
fi

# --- corrupt-cache self-heal ----------------------------------------------------
if [ -f "$TOKENS" ]; then
    if valid_json "$TOKENS"; then
        cp -f "$TOKENS" "$BACKUP" 2>/dev/null || true
    elif [ -f "$BACKUP" ] && valid_json "$BACKUP"; then
        echo "office365-mcp: tokens.json is corrupt (likely killed mid-write);" >&2
        echo "office365-mcp: restoring last good copy from tokens.json.bak." >&2
        cp -f "$BACKUP" "$TOKENS" 2>/dev/null || true
    else
        echo "office365-mcp: tokens.json is corrupt and no valid backup exists —" >&2
        echo "office365-mcp: re-run the device-code 'auth' step to sign in again." >&2
    fi
fi

# --- rolling backup while running ------------------------------------------------
if [ -f "$TOKENS" ]; then
    ( while sleep 60; do cp -f "$TOKENS" "$BACKUP" 2>/dev/null || true; done ) &
fi

exec mcp-office365 "$@"
