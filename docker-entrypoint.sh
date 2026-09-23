#!/bin/sh
# Entrypoint wrapper for the office365-mcp container.
#
# Background: the upstream MSAL cache plugin (~/.mcp-office365/tokens.json)
# historically had no cross-process locking and wrote the file non-atomically.
# Microsoft refresh tokens are single-use (each refresh consumes the old one),
# so two containers racing a refresh used to destroy the login, and a killed
# mid-write could leave tokens.json truncated. The build now patches the cache
# (patch/upstream-cache-patch.mjs, upstream issue #129) with a refresh lock and
# atomic writes, so MULTIPLE containers may share ONE state dir/login.
#
# What this wrapper still does:
#   1. Startup validation of tokens.json — if it is corrupt but the rolling
#      backup is valid, the backup is restored before the server starts
#      (covers caches corrupted by pre-patch images).
#   2. A 60s background loop keeps tokens.json.bak rolling while the container
#      runs (same uid as the writer, so no host-side cron/permissions needed).
#   3. Detects a concurrent container on the same state dir and prints an
#      advisory: supported since image 1.3.0, dangerous with older images.
set -eu

STATE_DIR="/home/appuser/.mcp-office365"
TOKENS="$STATE_DIR/tokens.json"
BACKUP="$TOKENS.bak"
LOCK_FILE="$STATE_DIR/.instance.lock"

valid_json() {
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$1" 2>/dev/null
}

backup_atomically() {
    cp -f "$1" "$2.tmp.$$" 2>/dev/null && mv -f "$2.tmp.$$" "$2" 2>/dev/null || true
}

mkdir -p "$STATE_DIR"

# --- concurrency advisory ---------------------------------------------------
# Shared-mode note only: concurrent containers are safe with the refresh-locked
# cache, but a pre-1.3.0 container sharing this dir can still clobber the login.
exec 9>>"$LOCK_FILE"
if ! flock -n 9; then
    echo "office365-mcp: note — another office365-mcp container is using $STATE_DIR." >&2
    echo "office365-mcp: that is supported now (refresh-locked cache), but make sure" >&2
    echo "office365-mcp: it runs image >= 1.3.0; older images can still clobber the login." >&2
fi

# --- corrupt-cache self-heal --------------------------------------------------
if [ -f "$TOKENS" ]; then
    if valid_json "$TOKENS"; then
        backup_atomically "$TOKENS" "$BACKUP"
    elif [ -f "$BACKUP" ] && valid_json "$BACKUP"; then
        echo "office365-mcp: tokens.json is corrupt (likely truncated mid-write by an" >&2
        echo "office365-mcp: older image); restoring last good copy from tokens.json.bak." >&2
        cp -f "$BACKUP" "$TOKENS" 2>/dev/null || true
    else
        echo "office365-mcp: tokens.json is corrupt and no valid backup exists —" >&2
        echo "office365-mcp: re-run the device-code 'auth' step to sign in again." >&2
    fi
fi

# --- rolling backup while running ---------------------------------------------
if [ -f "$TOKENS" ]; then
    ( while sleep 60; do backup_atomically "$TOKENS" "$BACKUP"; done ) &
fi

exec mcp-office365 "$@"
