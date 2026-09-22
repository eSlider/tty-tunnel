#!/bin/sh
# tty-tunnel gotty entrypoint.
#
# Builds the gotty command line and execs it. By default the command is an ssh
# session into the host (host.docker.internal) with the key the bootstrap has
# already authorized, so the public URL gives you a real shell on your machine
# in the browser.
#
# Env:
#   GOTTY_PORT            listen port                         (8080)
#   GOTTY_USER            basic-auth user                     (tty)
#   GOTTY_PASSWORD        basic-auth password                 (from .env, else generated)
#   GOTTY_WS_ORIGIN       Origin regex gotty accepts          (.*)
#   GOTTY_TITLE           browser tab title                   (tty-tunnel)
#   GOTTY_ENABLE_WEBGL    xterm.js WebGL renderer             (true)
#   GOTTY_RECONNECT_TIME  seconds between reconnects          (5)
#   GOTTY_REMOTE_COMMAND  command to run on the host, e.g.    (none -> login shell)
#                         "tmux new -A -s tty-tunnel"
#   GOTTY_COMMAND         full replacement for the default ssh argv
#   SSH_HOST/SSH_PORT/SSH_USER  ssh target on the host
#   KEYS_DIR              directory holding id_ed25519        (/keys)
#   PUID/PGID             owner for the generated credentials file

set -eu
umask 022

GOTTY_PORT="${GOTTY_PORT:-8080}"
GOTTY_USER="${GOTTY_USER:-tty}"
GOTTY_PASSWORD="${GOTTY_PASSWORD:-}"
GOTTY_WS_ORIGIN="${GOTTY_WS_ORIGIN:-.*}"
GOTTY_TITLE="${GOTTY_TITLE:-tty-tunnel}"
GOTTY_ENABLE_WEBGL="${GOTTY_ENABLE_WEBGL:-true}"
GOTTY_RECONNECT_TIME="${GOTTY_RECONNECT_TIME:-5}"
SSH_HOST="${SSH_HOST:-host.docker.internal}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-root}"
KEYS_DIR="${KEYS_DIR:-/keys}"
KEY_SRC="$KEYS_DIR/id_ed25519"
SSH_KEY="/root/.ssh/id_ed25519"
CRED_FILE="/config/gotty.env"
PUID="${PUID:-0}"
PGID="${PGID:-0}"

log() { printf '==> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }

# Never run with an empty password: take the generated one, else make it up.
if [ -z "$GOTTY_PASSWORD" ] && [ -f "$CRED_FILE" ]; then
  GOTTY_PASSWORD="$(sed -n 's/^GOTTY_PASSWORD=//p' "$CRED_FILE" | head -n 1)"
fi
if [ -z "$GOTTY_PASSWORD" ]; then
  GOTTY_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)"
  warn "GOTTY_PASSWORD was not set — generated a random one"
fi

if [ -d /config ] && [ -w /config ]; then
  printf 'GOTTY_USER=%s\nGOTTY_PASSWORD=%s\n' "$GOTTY_USER" "$GOTTY_PASSWORD" >"$CRED_FILE" 2>/dev/null || true
  chmod 600 "$CRED_FILE" 2>/dev/null || true
  if [ "$PUID" != "0" ]; then
    chown "$PUID:$PGID" "$CRED_FILE" 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------- command ----
if [ -n "${GOTTY_COMMAND:-}" ]; then
  # shellcheck disable=SC2086
  set -- $GOTTY_COMMAND
else
  if [ ! -f "$KEY_SRC" ]; then
    warn "no SSH key at $KEY_SRC — the host shell will not work."
    warn "authorize one with a normal run (./tty-tunnel.sh up) or set GOTTY_COMMAND."
  else
    install -m 600 "$KEY_SRC" "$SSH_KEY"
  fi
  set -- ssh -tt \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/root/.ssh/known_hosts \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3 \
    -o LogLevel=ERROR \
    -i "$SSH_KEY" \
    -p "$SSH_PORT" \
    "${SSH_USER}@${SSH_HOST}"
  if [ -n "${GOTTY_REMOTE_COMMAND:-}" ]; then
    # shellcheck disable=SC2086
    set -- "$@" $GOTTY_REMOTE_COMMAND
  fi
fi

export TERM=xterm-256color
export COLORTERM=truecolor

log "gotty on :$GOTTY_PORT  login: $GOTTY_USER / $GOTTY_PASSWORD"
log "command: $*"

exec gotty \
  -a 0.0.0.0 \
  -p "$GOTTY_PORT" \
  -w \
  -c "$GOTTY_USER:$GOTTY_PASSWORD" \
  --reconnect \
  --reconnect-time "$GOTTY_RECONNECT_TIME" \
  --ws-origin "$GOTTY_WS_ORIGIN" \
  --title-format "$GOTTY_TITLE" \
  --enable-webgl="$GOTTY_ENABLE_WEBGL" \
  "$@"
