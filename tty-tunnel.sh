#!/bin/sh
# tty-tunnel one-liner CLI.
#
#   curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/main/tty-tunnel.sh | sh
#
# Starts (or inspects) the stack and prints the access table. When piped it
# downloads the repo into $TTT_HOME (default ~/.tty-tunnel); from a clone it
# works in place. If no container runtime is found, Docker Engine is installed
# on Debian/Ubuntu (official apt repository) after a prompt.
#
#   ./tty-tunnel.sh            start, wait for the URL, print the table
#   ./tty-tunnel.sh pass       print just the access table
#   ./tty-tunnel.sh url        print the public URL
#   ./tty-tunnel.sh logs       follow the logs
#   ./tty-tunnel.sh down       stop the stack (keeps data)
#   ./tty-tunnel.sh reset      DESTRUCTIVE: remove data, credentials and keys
#
# Env:
#   TTT_HOME      checkout dir (default ~/.tty-tunnel)
#   TTT_WAIT      seconds to wait for the URL (default 180)
#   TTT_INSTALL   ask (default) | yes | no — install Docker when it is missing
#   TTT_FORCE=1   skip the reset prompt

set -eu

REPO="eSlider/tty-tunnel"
REPO_URL="https://github.com/${REPO}"
TARBALL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/main"
TTT_HOME="${TTT_HOME:-$HOME/.tty-tunnel}"
TTT_WAIT="${TTT_WAIT:-180}"
CMD="${1:-up}"

DOCKER_DOCS="https://docs.docker.com/engine/install/ubuntu/"

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

Missing Docker is installed automatically on Debian/Ubuntu (official apt repo,
needs sudo). TTT_INSTALL=no never installs anything, TTT_INSTALL=yes skips the
prompt. Podman is used automatically when it is present and Docker is not.
Env: TTT_HOME, TTT_WAIT (URL timeout, default 180), TTT_FORCE=1 (skip reset prompt).
EOF
}

# ------------------------------------------------------------ utilities -----
fetch() {
  # fetch <url> — print to stdout
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    die "curl or wget is required"
  fi
}

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

compose() {
  # shellcheck disable=SC2086  # $DC is intentionally split ("docker compose")
  $DC "$@"
}

# ---------------------------------------------------- container runtime -----
# Sets $DC to the command prefix used for every compose call, e.g.
# "docker compose", "sudo docker compose" or "podman compose".
set_dc() {
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      DC="docker compose"
      return 0
    fi
    if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
      DC="$SUDO docker compose"
      return 0
    fi
  fi
  if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    DC="podman compose"
    return 0
  fi
  return 1
}

install_docker_apt() {
  distro="$1"
  codename="$2"
  log "installing Docker Engine from the official apt repository ($distro/$codename)"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  arch="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$distro" "$codename" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_script() {
  log "installing Docker Engine via get.docker.com"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | $SUDO sh
  else
    $SUDO sh -c "$(fetch https://get.docker.com)"
  fi
}

install_runtime() {
  mode="${TTT_INSTALL:-ask}"

  if [ "$mode" = "no" ]; then
    die "no container runtime found and TTT_INSTALL=no — install Docker first: $DOCKER_DOCS"
  fi

  if [ "$mode" = "ask" ] && [ -r /dev/tty ]; then
    printf '  Docker is not installed. Install Docker Engine now? [Y/n] ' >/dev/tty
    answer=""
    read -r answer </dev/tty || answer=""
    case "$answer" in
      n | N | no | NO) die "aborted — install Docker first: $DOCKER_DOCS" ;;
    esac
  fi

  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    die "installing Docker requires root or sudo — see $DOCKER_DOCS"
  fi

  if command -v apt-get >/dev/null 2>&1 && [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu | debian) install_docker_apt "$ID" "${VERSION_CODENAME:-stable}" ;;
      *) install_docker_script ;;
    esac
  else
    install_docker_script
  fi

  if [ -n "$SUDO" ]; then
    $SUDO systemctl enable --now docker >/dev/null 2>&1 ||
      $SUDO service docker start >/dev/null 2>&1 || true
    if ! id -nG "$USER" 2>/dev/null | grep -qw docker; then
      $SUDO usermod -aG docker "$USER" 2>/dev/null || true
      log "added $USER to the 'docker' group (active after your next login; using sudo now)"
    fi
  fi

  command -v docker >/dev/null 2>&1 ||
    die "Docker was installed but is not on PATH — open a new shell and re-run, or see $DOCKER_DOCS"
}

if ! set_dc; then
  install_runtime
  set_dc || die "Docker is installed but the daemon is not reachable. Start it with 'sudo systemctl start docker' and re-run."
fi

case "$DC" in
  podman*) log "using podman: compose support is best-effort; Docker is recommended" ;;
  sudo*) log "using sudo for docker (your user is not in the 'docker' group yet)" ;;
esac

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
    need tar
    fetch "$TARBALL" | tar -xz -C "${TTT_HOME}.tmp" --strip-components=1
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

  # A brand-new quick-tunnel hostname can take a few seconds to resolve.
  printf '  checking reachability…\n' >&2
  root_code=""
  i=0
  while [ "$i" -lt 15 ]; do
    root_code="$(curl_code -L "$url/")"
    case "$root_code" in
      2* | 3*) break ;;
    esac
    i=$((i + 1))
    sleep 3
  done

  login_code="$(curl_code -X POST "$url/users/login" -H 'Content-Type: application/json' -d "$body")"
  reg="$(curl -sS --doh-url https://1.1.1.1/dns-query "$url/users/registration-allowed" 2>/dev/null | sed -n 's/.*"allowed":\([a-z]*\).*/\1/p')"

  case "$reg" in
    false) reg="closed" ;;
    true) reg="OPEN (run the stack once more to finish initialising)" ;;
    *) reg="unknown" ;;
  esac

  printf '  checks\n'
  printf '  %s\n' '──────────────────────────────────────────────────────────────'
  printf '  %-26s %s\n' 'GET  /' "${root_code:-000}"
  printf '  %-26s %s\n' 'POST /users/login' "${login_code:-000}"
  printf '  %-26s %s\n' 'registration' "$reg"
  printf '  %s\n' '──────────────────────────────────────────────────────────────'
  printf '\n'
  if [ "$root_code" = "000" ]; then
    printf '  note: the tunnel URL is not resolvable yet — retry in a few seconds,\n'
    printf '        or flush the DNS cache (resolvectl flush-caches).\n\n'
  fi
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
