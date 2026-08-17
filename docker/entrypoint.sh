#!/bin/sh
# DeepSeek Harness container entrypoint.
#
# Runs as root to initialise mounted volumes, then drops privileges to the
# unprivileged `dsh` user via gosu before exec'ing the built CLI artifact
# (apps/cli/lib/bin.js — the artifact plane, never src/bin.ts). When the
# container is already started as non-root, volume init is best-effort and
# the CLI is exec'd directly.
#
# LAN access: when DSH_ALLOW_CIDR is set, nginx is started (bound to
# 0.0.0.0:$DSH_WEB_PORT, restricted to the CIDR) proxying to the app on
# 127.0.0.1:3081. The app keeps its safe 127.0.0.1 bind; nginx enforces the
# allowlist. When unset, the app starts directly on $DSH_WEB_PORT (loopback
# only; use network_mode: host to reach it from the host).
set -eu

APP_DIR="${DSH_HOME:-/app}"
SESSIONS_DIR="${DSH_SESSIONS_DIR:-$APP_DIR/.sessions}"
STORAGES_DIR="${DSH_STORAGES_DIR:-$APP_DIR/.storages}"
DSH_UID="${DSH_UID:-1001}"
CLI_BIN="$APP_DIR/apps/cli/lib/bin.js"
WEB_PORT="${DSH_WEB_PORT:-3080}"
# Internal loopback port the app binds when nginx fronts it. Fixed so the
# nginx.conf upstream never needs runtime substitution.
INTERNAL_PORT=3081
NGINX_TEMPLATE="$APP_DIR/docker/nginx.conf"

ensure_dirs() {
    mkdir -p "$SESSIONS_DIR" "$STORAGES_DIR" 2>/dev/null || true
}

# Substitute placeholders in the nginx template and start nginx in daemon mode.
# Returns immediately; nginx master stays in the background. The app (exec'd
# next) becomes PID 1, so when it exits the container stops and Docker reaps nginx.
start_nginx() {
    cidr="$1"
    conf=/tmp/nginx.conf
    sed -e "s|__LISTEN_PORT__|${WEB_PORT}|g" \
        -e "s|__ALLOW_CIDR__|${cidr}|g" \
        "$NGINX_TEMPLATE" > "$conf"
    nginx -t -c "$conf" >/dev/null 2>&1
    nginx -c "$conf"
}

# When no launcher args are given, inject --profile from $DSH_PROFILE so the
# container boots without an explicit command. Explicit args always override.
# --host is never injected: 0.0.0.0 is rejected by the web app for safety.
if [ "$#" -eq 0 ] && [ -n "${DSH_PROFILE:-}" ]; then
    set -- --profile "$DSH_PROFILE"
    if [ -n "${DSH_ALLOW_CIDR:-}" ]; then
        # nginx fronts the external port; app binds the internal loopback port.
        set -- "$@" --port "$INTERNAL_PORT"
    else
        if [ -n "${DSH_WEB_PORT:-}" ]; then
            set -- "$@" --port "$WEB_PORT"
        fi
    fi
fi

if [ "$(id -u)" = "0" ]; then
    ensure_dirs
    chown -R "$DSH_UID:$DSH_UID" "$SESSIONS_DIR" "$STORAGES_DIR" 2>/dev/null || true
    if [ -n "${DSH_ALLOW_CIDR:-}" ]; then
        start_nginx "$DSH_ALLOW_CIDR"
    fi
    exec gosu "$DSH_UID" node "$CLI_BIN" "$@"
else
    ensure_dirs
    if [ -n "${DSH_ALLOW_CIDR:-}" ]; then
        start_nginx "$DSH_ALLOW_CIDR"
    fi
    exec node "$CLI_BIN" "$@"
fi
