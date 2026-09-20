#!/bin/sh
# tty-tunnel entrypoint.
#
# Runs cloudflared, extracts the public URL (quick tunnel) and persists it to
# $HOST_DIR so the host can read it from ./var/host.
#
# Env:
#   PORT            port on TARGET_HOST to forward (required unless TUNNEL_TOKEN)
#   TARGET_HOST     host to forward to (default: host.docker.internal)
#   TARGET_PROTO    http | https (default: http)
#   TUNNEL_TOKEN    Cloudflare named-tunnel token -> persistent hostname
#   TUNNEL_HOSTNAME hostname of the named tunnel (only used for reporting)
#   HOST_DIR        where url.txt/hostname.txt/cloudflared.log are written
#   METRICS_ADDR    cloudflared metrics/readiness address (default 0.0.0.0:2000)
#   READY_TIMEOUT   seconds to wait for a public URL (default 60)

set -eu
umask 0000

# Allow running arbitrary commands / cloudflared subcommands:
#   docker compose run --rm tunnel cloudflared tunnel login
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

TARGET_HOST="${TARGET_HOST:-host.docker.internal}"
TARGET_PROTO="${TARGET_PROTO:-http}"
TARGET_PORT="${PORT:-}"
HOST_DIR="${HOST_DIR:-/var/host}"
METRICS_ADDR="${METRICS_ADDR:-0.0.0.0:2000}"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
TUNNEL_HOSTNAME="${TUNNEL_HOSTNAME:-}"
READY_TIMEOUT="${READY_TIMEOUT:-60}"

mkdir -p "$HOST_DIR"
LOG="$HOST_DIR/cloudflared.log"
URL_FILE="$HOST_DIR/url.txt"
HOST_FILE="$HOST_DIR/hostname.txt"
HISTORY_FILE="$HOST_DIR/history.log"
: >"$URL_FILE"

ORIGIN="${TARGET_PROTO}://${TARGET_HOST}"
if [ -n "$TARGET_PORT" ]; then
  ORIGIN="${ORIGIN}:${TARGET_PORT}"
fi

banner() {
  printf '\n'
  printf '  tty-tunnel is live\n'
  printf '  ----------------------------------------------------------\n'
  printf '  public URL : %s\n' "$1"
  printf '  forwarding : %s\n' "${2:-$ORIGIN}"
  printf '  saved to   : %s\n' "$URL_FILE"
  printf '  ----------------------------------------------------------\n'
  printf '\n'
}

record() {
  # record <url> [forwarded-to]
  url="$1"
  printf '%s\n' "$url" >"$URL_FILE"
  printf '%s\n' "${url#https://}" >"$HOST_FILE"
  printf '%s %s -> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$url" "${2:-$ORIGIN}" >>"$HISTORY_FILE"
}

if [ -n "$TUNNEL_TOKEN" ]; then
  echo "==> named tunnel (token mode)"
  cloudflared tunnel --no-autoupdate --metrics "$METRICS_ADDR" run --token "$TUNNEL_TOKEN" >"$LOG" 2>&1 &
  pid=$!
  if [ -n "$TUNNEL_HOSTNAME" ]; then
    record "https://${TUNNEL_HOSTNAME}"
    banner "https://${TUNNEL_HOSTNAME}"
  else
    echo "==> tunnel is up; public hostname is defined in the Cloudflare dashboard"
  fi
  wait "$pid"
else
  if [ -z "$TARGET_PORT" ]; then
    echo "ERROR: PORT is required (or set TUNNEL_TOKEN for a named tunnel)" >&2
    exit 1
  fi

  echo "==> quick tunnel to $ORIGIN"
  cloudflared tunnel --no-autoupdate --metrics "$METRICS_ADDR" --url "$ORIGIN" >"$LOG" 2>&1 &
  pid=$!

  url=""
  i=0
  while [ "$i" -lt "$READY_TIMEOUT" ]; do
    url="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" 2>/dev/null | head -n 1 || true)"
    [ -n "$url" ] && break
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: cloudflared exited before a URL was issued:" >&2
      cat "$LOG" >&2
      exit 1
    fi
    i=$((i + 1))
    sleep 1
  done

  if [ -n "$url" ]; then
    record "$url"
    banner "$url"
  else
    echo "==> no URL detected after ${READY_TIMEOUT}s, see $LOG" >&2
  fi

  wait "$pid"
fi
