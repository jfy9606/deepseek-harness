#!/bin/sh
# DeepSeek Harness container entrypoint.
#
# Runs as root to initialise mounted volumes, then drops privileges to the
# unprivileged `dsh` user via gosu before exec'ing the built CLI artifact
# (apps/cli/lib/bin.js — the artifact plane, never src/bin.ts). When the
# container is already started as non-root, volume init is best-effort and
# the CLI is exec'd directly.
set -eu

APP_DIR="${DSH_HOME:-/app}"
SESSIONS_DIR="${DSH_SESSIONS_DIR:-$APP_DIR/.sessions}"
STORAGES_DIR="${DSH_STORAGES_DIR:-$APP_DIR/.storages}"
DSH_UID="${DSH_UID:-1001}"
CLI_BIN="$APP_DIR/apps/cli/lib/bin.js"

# When no launcher args are given, inject --profile from $DSH_PROFILE so the
# container boots without an explicit command. Explicit args always override.
if [ "$#" -eq 0 ] && [ -n "${DSH_PROFILE:-}" ]; then
    set -- --profile "$DSH_PROFILE"
fi

ensure_dirs() {
    mkdir -p "$SESSIONS_DIR" "$STORAGES_DIR" 2>/dev/null || true
}

if [ "$(id -u)" = "0" ]; then
    ensure_dirs
    chown -R "$DSH_UID:$DSH_UID" "$SESSIONS_DIR" "$STORAGES_DIR" 2>/dev/null || true
    exec gosu "$DSH_UID" node "$CLI_BIN" "$@"
else
    ensure_dirs
    exec node "$CLI_BIN" "$@"
fi
