#!/bin/sh
# Run OpenCode v2 in an isolated container — no server, no Termix, just the TUI.
#
#   curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/main/opencode.sh | sh
#
# Your project directory is mounted at /workspace, OpenCode's own state lives in
# a Docker volume, and your host OpenCode config/credentials are copied into
# that volume on first start (read-only source, never modified).
#
# Env:
#   OPENCODE_IMAGE      image to run                    (ghcr.io/eslider/tty-tunnel-opencode:latest)
#   OPENCODE_PROJECT    directory to work on            ($PWD)
#   OPENCODE_VOLUME     docker volume for OpenCode      (tty-tunnel-opencode-home)
#   OPENCODE_SEED       copy host config/credentials    (auto: yes when they exist)
#   TTT_INSTALL         ask (default) | yes | no — install Docker when missing

set -eu

IMAGE="${OPENCODE_IMAGE:-ghcr.io/eslider/tty-tunnel-opencode:latest}"
PROJECT="${OPENCODE_PROJECT:-$PWD}"
VOLUME="${OPENCODE_VOLUME:-tty-tunnel-opencode-home}"
DOCKER_DOCS="https://docs.docker.com/engine/install/ubuntu/"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf '!!! %s\n' "$*" >&2; exit 1; }

[ -t 0 ] && [ -t 1 ] || die "OpenCode is a terminal UI — run this in a terminal (not piped to a file)"

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

set_dc() {
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      DC="docker"
      return 0
    fi
    if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
      DC="$SUDO docker"
      return 0
    fi
  fi
  if command -v podman >/dev/null 2>&1; then
    DC="podman"
    return 0
  fi
  return 1
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
  [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ] || die "installing Docker requires root or sudo — see $DOCKER_DOCS"
  log "installing Docker Engine"
  if command -v apt-get >/dev/null 2>&1 && [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu | debian)
        $SUDO apt-get update -qq
        $SUDO apt-get install -y -qq ca-certificates curl
        $SUDO install -m 0755 -d /etc/apt/keyrings
        $SUDO curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
        $SUDO chmod a+r /etc/apt/keyrings/docker.asc
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
          "$(dpkg --print-architecture)" "$ID" "${VERSION_CODENAME:-stable}" |
          $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
        $SUDO apt-get update -qq
        $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
      *) die "unsupported distribution '${ID:-unknown}' — see $DOCKER_DOCS" ;;
    esac
  else
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://get.docker.com | $SUDO sh
    else
      die "install Docker manually: $DOCKER_DOCS"
    fi
  fi
  if [ -n "$SUDO" ]; then
    $SUDO systemctl enable --now docker >/dev/null 2>&1 || $SUDO service docker start >/dev/null 2>&1 || true
  fi
}

set_dc || {
  install_runtime
  set_dc || die "Docker is installed but not reachable — start it ('sudo systemctl start docker') and re-run"
}

# shellcheck disable=SC2086
run() { $DC "$@"; }

[ -d "$PROJECT" ] || die "project directory does not exist: $PROJECT"
PROJECT="$(cd "$PROJECT" && pwd)"

SEED="${OPENCODE_SEED:-}"
if [ -z "$SEED" ]; then
  if [ -f "${HOME}/.local/share/opencode/auth.json" ] || [ -d "${HOME}/.config/opencode" ]; then
    SEED=yes
  else
    SEED=no
  fi
fi

set -- run --rm -it \
  -e OPENCODE_MODE=tui \
  -e "OPENCODE_SEED=$([ "$SEED" = "yes" ] && echo true || echo false)" \
  -e "OPENCODE_UID=$(id -u)" \
  -e "OPENCODE_GID=$(id -g)" \
  -v "$VOLUME:/home/opencode" \
  -v "$PROJECT:/workspace"

# Only mount the seed sources when they exist, so that Docker does not create
# root-owned directories in your home.
if [ "$SEED" = "yes" ]; then
  [ -d "${HOME}/.config/opencode" ] && set -- "$@" -v "${HOME}/.config/opencode:/seed/config:ro"
  [ -d "${HOME}/.local/share/opencode" ] && set -- "$@" -v "${HOME}/.local/share/opencode:/seed/data:ro"
fi

log "project : $PROJECT"
log "state   : volume $VOLUME"
[ "$SEED" = "yes" ] && log "seeding OpenCode config and credentials from your home directory"

run "$@" "$IMAGE"
