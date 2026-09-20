#!/bin/sh
# tty-tunnel one-liner CLI.
#
#   curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/main/tty-tunnel.sh | sh
#
# Starts (or inspects) the stack and prints the access table. When piped it
# downloads the repo into $TTT_HOME (default ~/.tty-tunnel); from a clone it
# works in place.
#
#   ./tty-tunnel.sh            start, wait for the URL, print the table
#   ./tty-tunnel.sh pass       print just the access table
#   ./tty-tunnel.sh url        print the public URL
#   ./tty-tunnel.sh logs       follow the logs
#   ./tty-tunnel.sh down       stop the stack (keeps data)
#   ./tty-tunnel.sh reset      DESTRUCTIVE: remove data, credentials and keys
#
# Env: TTT_HOME (checkout dir), TTT_WAIT (seconds to wait for the URL, default 180)

set -eu

REPO="eSlider/tty-tunnel"
REPO_URL="https://github.com/${REPO}"
TARBALL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"
TTT_HOME="${TTT_HOME:-$HOME/.tty-tunnel}"
TTT_WAIT="${TTT_WAIT:-180}"
CMD="${1:-up}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf '!!! %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

usage() {
  cat <<'EOF'
tty-tunnel — run Termix behind a Cloudflare Tunnel.

  tty-tunnel.sh [command]

Commands:
  up       build, start the stack, wait for the public URL, print the table  (default)
  pass     print just the access table (URL, credentials, SSH preset)
  url      print the current public URL
  logs     follow the logs
  down     stop the stack, keep all data
  reset    DESTRUCTIVE: remove data, credentials and generated keys

Run with no checkout to install into $TTT_HOME (~/.tty-tunnel, or set TTT_HOME):
  curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/main/tty-tunnel.sh | sh
Env: TTT_HOME, TTT_WAIT (seconds to wait for the URL, default 180), TTT_FORCE=1 to skip the reset prompt.
EOF
}

compose() {
  # shellcheck disable=SC2086  # $DC is intentionally split ("docker compose")
  $DC "$@"
}

need docker
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "'docker compose' (or 'docker-compose') is required"
fi

is_repo_root() {
  [ -f "$1/docker-compose.yml" ] && [ -f "$1/entrypoint.sh" ] && [ -f "$1/bootstrap/entrypoint.sh" ]
}

# ----------------------------------------------------------- locate repo ----
ROOT=""
if is_repo_root "$PWD"; then
  ROOT="$PWD"
elif [ -n "${TTT_SCRIPT_DIR:-}" ] && is_repo_root "$TTT_SCRIPT_DIR"; then
  ROOT="$TTT_SCRIPT_DIR"
elif is_repo_root "$TTT_HOME"; then
  ROOT="$TTT_HOME"
  log "using existing checkout in $ROOT"
fi

if [ -z "$ROOT" ]; then
  log "fetching $REPO into $TTT_HOME"
  rm -rf "${TTT_HOME}.tmp"
  mkdir -p "${TTT_HOME}.tmp"
  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 "$REPO_URL" "${TTT_HOME}.tmp" >/dev/null 2>&1
  else
    need curl
    need tar
    curl -fsSL "$TARBALL" | tar -xz -C "${TTT_HOME}.tmp" --strip-components=1
  fi
  mkdir -p "$(dirname "$TTT_HOME")"
  rm -rf "$TTT_HOME"
  mv "${TTT_HOME}.tmp" "$TTT_HOME"
  ROOT="$TTT_HOME"
fi

cd "$ROOT"

# --------------------------------------------------------------- helpers ----
ensure_env() {
  [ -f .env ] && return 0
  [ -f .env.example ] || return 0
  sed -e "s|^PUID=.*|PUID=$(id -u)|" \
      -e "s|^PGID=.*|PGID=$(id -g)|" \
      -e "s|^SSH_USER=.*|SSH_USER=${USER:-root}|" \
      -e "s|^HOST_SSH_DIR=.*|HOST_SSH_DIR=${HOME}/.ssh|" \
      .env.example >.env
  log "created .env"
}

yaml_get() {
  # yaml_get <key> — first match in etc/config.yml, quotes stripped
  sed -n "s/^[[:space:]]*$1:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" \
    "$ROOT/etc/config.yml" 2>/dev/null | head -n 1
}

curl_code() {
  # curl_code <curl args...> — HTTP status, retrying through Cloudflare DoH
  # because a fresh trycloudflare name can be cached as NXDOMAIN locally.
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
  case "$code" in
    2* | 3*) printf '%s' "$code"; return 0 ;;
  esac
  code="$(curl -sS --doh-url https://1.1.1.1/dns-query -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
  printf '%s' "$code"
}

wait_for_url() {
  i=0
  while [ "$i" -lt "$TTT_WAIT" ]; do
    if [ -s "$ROOT/var/host/url.txt" ] && [ -f "$ROOT/etc/config.yml" ]; then
      return 0
    fi
    i=$((i + 2))
    printf '.' >&2
    sleep 2
  done
  printf '\n' >&2
  return 1
}

print_table() {
  url="$(cat "$ROOT/var/host/url.txt" 2>/dev/null || true)"
  local_port="${TERMIX_LOCAL_PORT:-$(sed -n 's/^TERMIX_LOCAL_PORT=//p' "$ROOT/.env" 2>/dev/null | head -n1)}"
  local_url="http://localhost:${local_port:-8080}"
  admin_user="$(yaml_get admin_user)"
  admin_pass="$(yaml_get admin_password)"
  ssh_user="$(yaml_get user)"
  ssh_host="$(yaml_get host)"
  ssh_port="$(yaml_get port)"

  printf '\n'
  printf '  tty-tunnel — running now\n'
  printf '  %s\n' '──────────────────────────────────────────────────────────────'
  printf '  %-13s %s\n' 'Public URL' "${url:-(starting…)}"
  printf '  %-13s %s\n' 'Local Termix' "$local_url"
  printf '  %-13s %s\n' 'Admin user' "${admin_user:-(not initialised)}"
  printf '  %-13s %s\n' 'Admin pass' "${admin_pass:-(not initialised)}"
  printf '  %-13s %s\n' 'SSH preset' "${ssh_user:-?}@${ssh_host:-?}:${ssh_port:-?}"
  printf '  %-13s %s\n' 'Checkout' "$ROOT"
  printf '  %s\n' '──────────────────────────────────────────────────────────────'
  printf '\n'

  [ -n "$url" ] || return 0

  body="$(printf '{"username":"%s","password":"%s"}' "$admin_user" "$admin_pass")"
  root_code="$(curl_code -L "$url/")"
  login_code="$(curl_code -X POST "$url/users/login" -H 'Content-Type: application/json' -d "$body")"
  reg="$(curl -sS --doh-url https://1.1.1.1/dns-query "$url/users/registration-allowed" 2>/dev/null | sed -n 's/.*"allowed":\([a-z]*\).*/\1/p')"

  case "$reg" in
    false) reg="closed" ;;
    true) reg="OPEN (run make up to finish initialising)" ;;
    *) reg="unknown" ;;
  esac

  printf '  checks\n'
  printf '  %s\n' '──────────────────────────────────────────────────────────────'
  printf '  %-26s %s\n' 'GET  /' "${root_code:-unreachable}"
  printf '  %-26s %s\n' 'POST /users/login' "${login_code:-unreachable}"
  printf '  %-26s %s\n' 'registration' "$reg"
  printf '  %s\n' '──────────────────────────────────────────────────────────────'
  printf '\n'
  printf '  logs: %s logs -f   ·   stop: %s down\n' "$DC" "$DC"
  printf '\n'
}

# ------------------------------------------------------------- commands -----
case "$CMD" in
  up)
    ensure_env
    log "building and starting the stack"
    compose up -d --build
    log "waiting for the public URL (up to ${TTT_WAIT}s)"
    if ! wait_for_url; then
      printf '\n'
      print_table
      die "timed out waiting for the tunnel; check: $DC logs tunnel"
    fi
    print_table
    ;;
  pass | creds)
    print_table
    ;;
  url)
    cat "$ROOT/var/host/url.txt"
    ;;
  logs)
    compose logs -f --tail=100
    ;;
  down)
    compose down
    ;;
  reset)
    if [ "${TTT_FORCE:-0}" != "1" ]; then
      if [ -t 0 ]; then
        printf 'This deletes var/termix, var/ssh, var/host state, etc/config.yml and .env. Continue? [y/N] '
        read -r answer || answer=""
        case "$answer" in
          y | Y | yes) ;;
          *) die "aborted" ;;
        esac
      else
        die "refusing to reset without a TTY; re-run with TTT_FORCE=1"
      fi
    fi
    compose down -v || true
    rm -rf "$ROOT/var/termix" "$ROOT/var/ssh" "$ROOT/var/host-ssh"
    rm -f "$ROOT/var/host/url.txt" "$ROOT/var/host/hostname.txt" "$ROOT/var/host/cloudflared.log"
    rm -f "$ROOT/etc/config.yml" "$ROOT/.env"
    log "reset complete"
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    die "unknown command '$CMD' (try: up, pass, url, logs, down, reset)"
    ;;
esac
