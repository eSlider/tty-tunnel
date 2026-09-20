#!/bin/sh
# tty-tunnel bootstrap — runs once, before the tunnel is started.
#
# 1. waits for Termix to become healthy
# 2. creates the first (admin) user with a generated password
# 3. closes self-registration
# 4. generates an SSH keypair and seeds a "Local host" entry in Termix
# 5. (OPENCODE_ENABLED) seeds the isolated OpenCode container as a Termix host
#    and a default workspace with a single "opencode" terminal tab
# 6. persists credentials to etc/config.yml and .env
#
# It is idempotent and never overwrites existing credentials.

set -eu
umask 0077

TERMIX_URL="${TERMIX_URL:-http://termix:8080}"
TERMIX_LOCAL_URL="${TERMIX_LOCAL_URL:-http://localhost:8080}"
ADMIN_USER="${TERMIX_ADMIN_USER:-admin}"
SSH_USER="${SSH_USER:-root}"
SSH_HOST="${SSH_HOST:-host.docker.internal}"
SSH_PORT="${SSH_PORT:-22}"
AUTHORIZE_SSH_KEY="${AUTHORIZE_SSH_KEY:-true}"

OPENCODE_ENABLED="${OPENCODE_ENABLED:-0}"
OPENCODE_HOST="${OPENCODE_HOST:-opencode}"
OPENCODE_SSH_USER="${OPENCODE_SSH_USER:-opencode}"
OPENCODE_SSH_PORT="${OPENCODE_SSH_PORT:-22}"
OPENCODE_WORKDIR="${OPENCODE_WORKDIR:-/workspace}"
OPENCODE_SSH_PASSWORD="${OPENCODE_SSH_PASSWORD:-}"
OPENCODE_WORKSPACE="${OPENCODE_WORKSPACE:-opencode}"

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
is_true() { case "${1:-}" in 1 | true | yes | on) return 0 ;; *) return 1 ;; esac; }

trap 'rm -f "$JAR"' EXIT

gen_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24
}

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

yaml_value() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" \
    "$CONFIG_FILE" 2>/dev/null | head -n 1
}

api() {
  # api <method> <path> [json] — prints the response body
  method="$1"
  path="$2"
  body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "$TERMIX_URL$path" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body"
  else
    curl -fsS -X "$method" "$TERMIX_URL$path" -H "Authorization: Bearer $TOKEN"
  fi
}

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

setup_required=""
i=0
while [ "$i" -lt 15 ]; do
  setup_required="$(curl -fsS "$TERMIX_URL/users/setup-required" 2>/dev/null | jq -r '.setup_required' 2>/dev/null || true)"
  [ -n "$setup_required" ] && break
  i=$((i + 1))
  sleep 2
done

# ------------------------------------------------------------------ ssh -----
KEY_EXISTED=true
[ -f "$KEY_DIR/id_ed25519" ] || KEY_EXISTED=false
mkdir -p "$KEY_DIR"
if [ "$KEY_EXISTED" = "false" ]; then
  log "generating SSH keypair in var/ssh"
  ssh-keygen -q -t ed25519 -N '' -C "tty-tunnel first-run key" -f "$KEY_DIR/id_ed25519"
fi
chmod 600 "$KEY_DIR/id_ed25519"
chmod 644 "$KEY_DIR/id_ed25519.pub"

authorized=false
authorize_host_key() {
  if ! is_true "$AUTHORIZE_SSH_KEY"; then
    log "AUTHORIZE_SSH_KEY=false, not touching the host's authorized_keys"
    return 0
  fi
  KEY_AUTH="$HOST_SSH_DIR/authorized_keys"
  if [ ! -d "$HOST_SSH_DIR" ]; then
    warn "HOST_SSH_DIR ($HOST_SSH_DIR) is not available, skipping key authorization"
    return 0
  fi
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
}

# ------------------------------------------------------------- admin -------
FIRST_RUN=false
TOKEN=""
OPENCODE_SEEDED=false

if [ "$setup_required" = "true" ]; then
  FIRST_RUN=true
  ADMIN_PASSWORD="$(gen_password)"
  [ -n "$ADMIN_PASSWORD" ] || {
    warn "could not generate a password"
    exit 1
  }

  log "creating admin user '$ADMIN_USER'"
  curl -fsS -X POST "$TERMIX_URL/users/create" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username:$u,password:$p}')" >/dev/null

  authorize_host_key
else
  log "Termix is already initialised"
  ADMIN_PASSWORD="${TERMIX_ADMIN_PASSWORD:-}"
  [ -n "$ADMIN_PASSWORD" ] || ADMIN_PASSWORD="$(yaml_value admin_password)"
  [ -n "$ADMIN_PASSWORD" ] || ADMIN_PASSWORD="$(sed -n 's/^TERMIX_ADMIN_PASSWORD=//p' "$ENV_FILE" 2>/dev/null | head -n 1)"
  [ -n "$ADMIN_PASSWORD" ] || warn "no stored admin password found; OpenCode seeding may be skipped"
  if [ "$KEY_EXISTED" = "false" ]; then
    authorize_host_key
  fi
fi

# ----------------------------------------------------------------- login ----
if [ -n "$ADMIN_PASSWORD" ]; then
  if curl -fsS -c "$JAR" -X POST "$TERMIX_URL/users/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username:$u,password:$p}')" >/dev/null; then
    TOKEN="$(awk '$6 == "jwt" { print $7 }' "$JAR" | tail -n 1)"
  fi
  [ -n "$TOKEN" ] || warn "could not log in as '$ADMIN_USER'"
fi

if [ "$FIRST_RUN" = "true" ] && [ -n "$TOKEN" ]; then
  log "closing self-registration"
  api PATCH /users/registration-allowed '{"allowed":false}' >/dev/null
fi

# ------------------------------------------------------------- ssh host ----
ssh_host_created=false
if [ "$FIRST_RUN" = "true" ] && [ -n "$TOKEN" ]; then
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

  if api POST /host/db/host "$host_payload" >/dev/null; then
    ssh_host_created=true
    log "seeded Termix host preset: $SSH_USER@$SSH_HOST:$SSH_PORT"
  else
    warn "could not seed the Termix host preset (Termix is still usable, add a host manually)"
  fi
fi

# -------------------------------------------------------------- opencode ----
if is_true "$OPENCODE_ENABLED"; then
  if [ -z "$TOKEN" ]; then
    warn "skipping OpenCode seeding: no Termix session"
  elif [ ! -f "$KEY_DIR/id_ed25519" ]; then
    warn "skipping OpenCode seeding: no SSH key"
  else
    if [ -z "$OPENCODE_SSH_PASSWORD" ]; then
      OPENCODE_SSH_PASSWORD="$(gen_password)"
      set_env OPENCODE_SSH_PASSWORD "$OPENCODE_SSH_PASSWORD"
      log "generated a password for the opencode account"
    fi

    oc_sync=""
    if hosts="$(api GET /host/db/host 2>/dev/null)"; then
      oc_sync="$(printf '%s' "$hosts" | jq -r --arg n "$OPENCODE_HOST" '[.[]? | select(.name == $n)][0].syncId // empty')"
    fi

    if [ -z "$oc_sync" ]; then
      log "seeding Termix host preset: $OPENCODE_SSH_USER@$OPENCODE_HOST:$OPENCODE_SSH_PORT"
      oc_payload="$(jq -n \
        --arg name "$OPENCODE_HOST" \
        --arg ip "$OPENCODE_HOST" \
        --argjson port "$OPENCODE_SSH_PORT" \
        --arg username "$OPENCODE_SSH_USER" \
        --arg key "$(cat "$KEY_DIR/id_ed25519")" \
        '{connectionType:"ssh",name:$name,ip:$ip,port:$port,username:$username,
          authType:"key",keyType:"ed25519",key:$key,
          enableTerminal:true,enableFileManager:true,
          tags:["tty-tunnel","opencode"]}')"
      oc_sync="$(api POST /host/db/host "$oc_payload" | jq -r '.syncId // empty')"
    else
      log "OpenCode host already present in Termix"
    fi

    if [ -z "$oc_sync" ]; then
      warn "could not resolve the OpenCode host in Termix"
    else
      ws_id=""
      if workspaces="$(api GET /workspaces 2>/dev/null)"; then
        ws_id="$(printf '%s' "$workspaces" | jq -r --arg n "$OPENCODE_WORKSPACE" '[.[]? | select(.name == $n)][0].id // empty')"
      fi

      if [ -z "$ws_id" ]; then
        log "creating the default workspace '$OPENCODE_WORKSPACE' with one opencode tab"
        slot="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "opencode-slot")"
        payload="$(jq -n \
          --arg slot "$slot" \
          --arg sync "$oc_sync" \
          --arg host "$OPENCODE_HOST" \
          '{tabs:[{slotId:$slot,type:"terminal",hostSyncId:$sync,
                    hostNameSnapshot:$host,label:"opencode"}],
            activeSlotId:$slot,splitMode:"none",
            paneTabIds:[$slot,null,null,null,null,null],
            rowSizes:[100],rowColSizes:[[100]]}')"
        ws_id="$(api POST /workspaces \
          "$(jq -n --arg name "$OPENCODE_WORKSPACE" --argjson payload "$payload" \
            '{name:$name,color:"#f39044",icon:"terminal",payload:$payload}')" |
          jq -r '.id // empty')"
      else
        log "workspace '$OPENCODE_WORKSPACE' already exists"
      fi

      if [ -n "$ws_id" ]; then
        if api POST "/workspaces/$ws_id/set-default" >/dev/null; then
          OPENCODE_SEEDED=true
          log "workspace '$OPENCODE_WORKSPACE' is the default: it opens on login"
        else
          warn "could not set the default workspace"
        fi
      else
        warn "could not create the OpenCode workspace"
      fi
    fi
  fi
fi

# ------------------------------------------------------------- persist -----
mkdir -p "$CONFIG_DIR"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
  printf '# tty-tunnel first-run configuration — generated %s\n' "$created_at"
  printf '# Private file (chmod 600), gitignored. Delete it together with var/termix to\n'
  printf '# start over from scratch.\n'
  printf 'termix:\n'
  printf '  url: "%s"\n' "$TERMIX_LOCAL_URL"
  printf '  admin_user: "%s"\n' "$ADMIN_USER"
  if [ -n "$ADMIN_PASSWORD" ]; then
    printf '  admin_password: "%s"\n' "$ADMIN_PASSWORD"
  fi
  printf '  registration_open: false\n'
  printf '  created_at: "%s"\n' "$created_at"
  printf 'ssh:\n'
  printf '  host: "%s"\n' "$SSH_HOST"
  printf '  port: %s\n' "$SSH_PORT"
  printf '  user: "%s"\n' "$SSH_USER"
  printf '  private_key: "var/ssh/id_ed25519"\n'
  printf '  authorized_on_host: %s\n' "$authorized"
  printf '  host_created_in_termix: %s\n' "$ssh_host_created"
  if is_true "$OPENCODE_ENABLED"; then
    printf 'opencode:\n'
    printf '  enabled: true\n'
    printf '  host: "%s"\n' "$OPENCODE_HOST"
    printf '  user: "%s"\n' "$OPENCODE_SSH_USER"
    printf '  port: %s\n' "$OPENCODE_SSH_PORT"
    if [ -n "$OPENCODE_SSH_PASSWORD" ]; then
      printf '  ssh_password: "%s"\n' "$OPENCODE_SSH_PASSWORD"
    fi
    printf '  workdir: "%s"\n' "$OPENCODE_WORKDIR"
    printf '  workspace: "%s"\n' "$OPENCODE_WORKSPACE"
    printf '  tab_seeded: %s\n' "$OPENCODE_SEEDED"
  fi
} >"$CONFIG_FILE"

set_env TERMIX_ADMIN_USER "$ADMIN_USER"
[ -n "$ADMIN_PASSWORD" ] && set_env TERMIX_ADMIN_PASSWORD "$ADMIN_PASSWORD"
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
printf '  admin pass : %s\n' "${ADMIN_PASSWORD:-(unchanged)}"
printf '  saved in   : etc/config.yml and .env\n'
printf '  SSH preset : %s@%s:%s (key authorized: %s)\n' "$SSH_USER" "$SSH_HOST" "$SSH_PORT" "$authorized"
if is_true "$OPENCODE_ENABLED"; then
  printf '  OpenCode   : %s@%s:%s (termix workspace: %s)\n' \
    "$OPENCODE_SSH_USER" "$OPENCODE_HOST" "$OPENCODE_SSH_PORT" "$OPENCODE_WORKSPACE"
fi
printf '  ----------------------------------------------------------\n'
printf '\n'
