#!/bin/sh
# tty-tunnel bootstrap — runs once, before the tunnel is started.
#
# 1. waits for Termix to become healthy
# 2. creates the first (admin) user with a generated password
# 3. closes self-registration
# 4. generates an SSH keypair and seeds a "Local host" entry in Termix
# 5. persists credentials to etc/config.yml and .env
#
# It is idempotent: if Termix already has users it does nothing and never
# overwrites existing credentials.

set -eu
umask 0077

TERMIX_URL="${TERMIX_URL:-http://termix:8080}"
TERMIX_LOCAL_URL="${TERMIX_LOCAL_URL:-http://localhost:8080}"
ADMIN_USER="${TERMIX_ADMIN_USER:-admin}"
SSH_USER="${SSH_USER:-root}"
SSH_HOST="${SSH_HOST:-host.docker.internal}"
SSH_PORT="${SSH_PORT:-22}"
AUTHORIZE_SSH_KEY="${AUTHORIZE_SSH_KEY:-true}"

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
CONFIG_DIR="${CONFIG_DIR:-$WORKSPACE_DIR/etc}"
KEY_DIR="${KEY_DIR:-$WORKSPACE_DIR/var/ssh}"
HOST_SSH_DIR="${HOST_SSH_DIR:-/host-ssh}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

ENV_FILE="$WORKSPACE_DIR/.env"
CONFIG_FILE="$CONFIG_DIR/config.yml"
JAR="$(mktemp)"

log() { printf '==> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }

trap 'rm -f "$JAR"' EXIT

# ---------------------------------------------------------------- health ----
log "waiting for Termix at $TERMIX_URL"
i=0
until curl -fsS -o /dev/null "$TERMIX_URL/health" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 150 ]; then
    warn "Termix did not become healthy in time"
    exit 1
  fi
  sleep 2
done

# ------------------------------------------------------------ initialized ---
setup_required=""
i=0
while [ "$i" -lt 15 ]; do
  setup_required="$(curl -fsS "$TERMIX_URL/users/setup-required" 2>/dev/null | jq -r '.setup_required' 2>/dev/null || true)"
  [ -n "$setup_required" ] && break
  i=$((i + 1))
  sleep 2
done

if [ "$setup_required" != "true" ]; then
  log "Termix is already initialised — nothing to do (credentials in etc/config.yml)"
  exit 0
fi

# ------------------------------------------------------------- password ----
gen_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24
}
ADMIN_PASSWORD="$(gen_password)"
[ -n "$ADMIN_PASSWORD" ] || { warn "could not generate a password"; exit 1; }

log "creating admin user '$ADMIN_USER'"
curl -fsS -X POST "$TERMIX_URL/users/create" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username:$u,password:$p}')" >/dev/null

log "logging in"
curl -fsS -c "$JAR" -X POST "$TERMIX_URL/users/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username:$u,password:$p}')" >/dev/null

TOKEN="$(awk '$6 == "jwt" { print $7 }' "$JAR" | tail -n 1)"
if [ -z "$TOKEN" ]; then
  warn "login did not return a session token"
  exit 1
fi

log "closing self-registration"
curl -fsS -X PATCH "$TERMIX_URL/users/registration-allowed" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"allowed":false}' >/dev/null

# ------------------------------------------------------------- ssh key -----
mkdir -p "$KEY_DIR"
if [ ! -f "$KEY_DIR/id_ed25519" ]; then
  log "generating SSH keypair in var/ssh"
  ssh-keygen -q -t ed25519 -N '' -C "tty-tunnel first-run key" -f "$KEY_DIR/id_ed25519"
fi
chmod 600 "$KEY_DIR/id_ed25519"
chmod 644 "$KEY_DIR/id_ed25519.pub"

authorized=false
if [ "$AUTHORIZE_SSH_KEY" = "true" ]; then
  KEY_AUTH="$HOST_SSH_DIR/authorized_keys"
  if [ -d "$HOST_SSH_DIR" ]; then
    if grep -qs 'tty-tunnel first-run key' "$KEY_AUTH"; then
      authorized=true
      log "SSH key already present in $KEY_AUTH"
    elif cat "$KEY_DIR/id_ed25519.pub" >>"$KEY_AUTH" 2>/dev/null; then
      authorized=true
      log "authorized key in $KEY_AUTH"
    else
      warn "could not write $KEY_AUTH (set HOST_SSH_DIR or AUTHORIZE_SSH_KEY=false)"
    fi
    if [ -f "$KEY_AUTH" ] && [ "$(stat -c %u "$KEY_AUTH" 2>/dev/null || echo "$PUID")" != "$PUID" ]; then
      chown "$PUID:$PGID" "$KEY_AUTH" 2>/dev/null || true
      chmod 600 "$KEY_AUTH" 2>/dev/null || true
    fi
  else
    warn "HOST_SSH_DIR ($HOST_SSH_DIR) is not available, skipping key authorization"
  fi
else
  log "AUTHORIZE_SSH_KEY=false, not touching the host's authorized_keys"
fi

# ------------------------------------------------------------- ssh host ----
ssh_host_created=false
host_payload="$(jq -n \
  --arg name "Local host" \
  --arg ip "$SSH_HOST" \
  --argjson port "$SSH_PORT" \
  --arg username "$SSH_USER" \
  --arg key "$(cat "$KEY_DIR/id_ed25519")" \
  '{connectionType:"ssh",name:$name,ip:$ip,port:$port,username:$username,
    authType:"key",keyType:"ed25519",key:$key,
    enableTerminal:true,enableFileManager:true,enableDocker:true,
    tags:["tty-tunnel"]}')"

if curl -fsS -X POST "$TERMIX_URL/host/db/host" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$host_payload" >/dev/null; then
  ssh_host_created=true
  log "seeded Termix host preset: $SSH_USER@$SSH_HOST:$SSH_PORT"
else
  warn "could not seed the Termix host preset (Termix is still usable, add a host manually)"
fi

# ------------------------------------------------------------- persist -----
mkdir -p "$CONFIG_DIR"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat >"$CONFIG_FILE" <<EOF
# tty-tunnel first-run configuration — generated $created_at
# Private file (chmod 600), gitignored. Delete it together with var/termix to
# start over from scratch.
termix:
  url: "$TERMIX_LOCAL_URL"
  admin_user: "$ADMIN_USER"
  admin_password: "$ADMIN_PASSWORD"
  registration_open: false
  created_at: "$created_at"
ssh:
  host: "$SSH_HOST"
  port: $SSH_PORT
  user: "$SSH_USER"
  private_key: "var/ssh/id_ed25519"
  authorized_on_host: $authorized
  host_created_in_termix: $ssh_host_created
EOF

set_env() {
  key="$1"
  value="$2"
  [ -f "$ENV_FILE" ] || : >"$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    tmp="$(mktemp)"
    sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" >"$tmp"
    cat "$tmp" >"$ENV_FILE"
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
}

set_env TERMIX_ADMIN_USER "$ADMIN_USER"
set_env TERMIX_ADMIN_PASSWORD "$ADMIN_PASSWORD"
set_env SSH_USER "$SSH_USER"

chmod 600 "$CONFIG_FILE" 2>/dev/null || true
chmod 600 "$ENV_FILE" 2>/dev/null || true
chown "$PUID:$PGID" "$CONFIG_FILE" "$ENV_FILE" 2>/dev/null || true
chown "$PUID:$PGID" "$KEY_DIR/id_ed25519" "$KEY_DIR/id_ed25519.pub" 2>/dev/null || true

printf '\n'
printf '  tty-tunnel is initialised\n'
printf '  ----------------------------------------------------------\n'
printf '  Termix     : %s\n' "$TERMIX_LOCAL_URL"
printf '  admin user : %s\n' "$ADMIN_USER"
printf '  admin pass : %s\n' "$ADMIN_PASSWORD"
printf '  saved in   : etc/config.yml and .env\n'
printf '  SSH preset : %s@%s:%s (key authorized: %s)\n' "$SSH_USER" "$SSH_HOST" "$SSH_PORT" "$authorized"
printf '  ----------------------------------------------------------\n'
printf '\n'
