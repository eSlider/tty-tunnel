#!/bin/sh
# tty-tunnel-opencode entrypoint.
#
# Prepares the unprivileged `opencode` user, seeds OpenCode credentials/config
# from read-only host mounts (once), then either starts sshd (default) or
# launches the TUI directly (OPENCODE_MODE=tui, used by the standalone
# opencode.sh one-liner).
#
# Env:
#   OPENCODE_MODE            sshd (default) | tui
#   OPENCODE_USER/UID/GID    account used for OpenCode            (opencode/1000/1000)
#   OPENCODE_HOME            home for that account                (/home/opencode)
#   OPENCODE_WORKDIR         directory OpenCode starts in         (/workspace)
#   OPENCODE_SSH_PASSWORD    optional password for the account
#   OPENCODE_SEED            seed auth/config from /seed          (true)
#   KEYS_DIR                 dir with id_ed25519.pub for sshd     (/keys)

set -eu
umask 022

OPENCODE_MODE="${OPENCODE_MODE:-sshd}"
OPENCODE_USER="${OPENCODE_USER:-opencode}"
OPENCODE_UID="${OPENCODE_UID:-1000}"
OPENCODE_GID="${OPENCODE_GID:-1000}"
OPENCODE_HOME="${OPENCODE_HOME:-/home/opencode}"
OPENCODE_WORKDIR="${OPENCODE_WORKDIR:-/workspace}"
OPENCODE_SSH_PASSWORD="${OPENCODE_SSH_PASSWORD:-}"
OPENCODE_SEED="${OPENCODE_SEED:-true}"
KEYS_DIR="${KEYS_DIR:-/keys}"
SEED_CONFIG_DIR="${SEED_CONFIG_DIR:-/seed/config}"
SEED_DATA_DIR="${SEED_DATA_DIR:-/seed/data}"
MARKER="$OPENCODE_HOME/.tty-tunnel-seeded"

log() { printf '==> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }

# The bootstrap step may have generated the account password; pick it up so the
# container and etc/config.yml always agree.
if [ -z "$OPENCODE_SSH_PASSWORD" ] && [ -f /config/config.yml ]; then
  OPENCODE_SSH_PASSWORD="$(sed -n 's/^[[:space:]]*ssh_password:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' /config/config.yml | head -n 1)"
fi

# ------------------------------------------------------------------ user ----
if ! id "$OPENCODE_USER" >/dev/null 2>&1; then
  addgroup -g "$OPENCODE_GID" "$OPENCODE_USER" 2>/dev/null || true
  adduser -D -u "$OPENCODE_UID" -G "$OPENCODE_USER" -h "$OPENCODE_HOME" -s /usr/local/bin/opencode-shell "$OPENCODE_USER"
  log "created user $OPENCODE_USER ($OPENCODE_UID:$OPENCODE_GID)"
fi

if [ -n "$OPENCODE_SSH_PASSWORD" ]; then
  printf '%s:%s\n' "$OPENCODE_USER" "$OPENCODE_SSH_PASSWORD" | chpasswd
fi

mkdir -p "$OPENCODE_HOME/.ssh" "$OPENCODE_HOME/.config/opencode" \
  "$OPENCODE_HOME/.local/share/opencode" "$OPENCODE_HOME/.local/state/opencode" \
  "$OPENCODE_WORKDIR"
chmod 700 "$OPENCODE_HOME/.ssh"

# ------------------------------------------------------------------ seed ----
if [ "$OPENCODE_SEED" = "true" ] && [ ! -f "$MARKER" ]; then
  if [ -f "$SEED_DATA_DIR/auth.json" ]; then
    cp "$SEED_DATA_DIR/auth.json" "$OPENCODE_HOME/.local/share/opencode/auth.json"
    chmod 600 "$OPENCODE_HOME/.local/share/opencode/auth.json"
    log "seeded provider credentials from $SEED_DATA_DIR/auth.json"
  else
    warn "no auth.json to seed (log in with: opencode auth login)"
  fi

  if [ -d "$SEED_CONFIG_DIR" ] && [ -n "$(ls -A "$SEED_CONFIG_DIR" 2>/dev/null || true)" ]; then
    cp -a "$SEED_CONFIG_DIR/." "$OPENCODE_HOME/.config/opencode/"
    log "seeded opencode config from $SEED_CONFIG_DIR"
  fi

  if [ ! -f "$OPENCODE_HOME/.config/opencode/opencode.json" ]; then
    cat >"$OPENCODE_HOME/.config/opencode/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "update": "disable"
}
EOF
    log "wrote a minimal global config (self-update disabled)"
  fi

  : >"$MARKER"
fi

# ------------------------------------------------------------ ssh access ----
if [ "$OPENCODE_MODE" != "tui" ]; then
  if [ -f "$KEYS_DIR/id_ed25519.pub" ]; then
    AUTH_KEYS="$OPENCODE_HOME/.ssh/authorized_keys"
    if ! grep -qs 'tty-tunnel' "$AUTH_KEYS"; then
      cat "$KEYS_DIR/id_ed25519.pub" >>"$AUTH_KEYS"
      log "authorized the tty-tunnel key in $AUTH_KEYS"
    fi
  else
    warn "no key at $KEYS_DIR/id_ed25519.pub — Termix will not be able to connect yet"
  fi
fi

chown -R "$OPENCODE_UID:$OPENCODE_GID" "$OPENCODE_HOME" "$OPENCODE_WORKDIR" 2>/dev/null || true

# ------------------------------------------------------------------ run -----
if [ "$OPENCODE_MODE" = "tui" ]; then
  log "opencode $(su-exec "$OPENCODE_USER" opencode --version 2>/dev/null || echo '?')"
  cd "$OPENCODE_WORKDIR"
  exec env HOME="$OPENCODE_HOME" TERM="${TERM:-xterm-256color}" COLORTERM="${COLORTERM:-truecolor}" \
    su-exec "$OPENCODE_USER" opencode
fi

for type in ed25519 rsa; do
  key="/etc/ssh/ssh_host_${type}_key"
  [ -f "$key" ] || ssh-keygen -q -t "$type" -N '' -f "$key"
done

mkdir -p /run/sshd
log "opencode $(opencode --version) — sshd on port 22"
exec /usr/sbin/sshd -D -e
