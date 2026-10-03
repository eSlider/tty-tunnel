#!/bin/sh
# Shared helper for the gitleaks hooks (.githooks/pre-commit, pre-push).
#
# Uses the local gitleaks binary when it is on PATH, otherwise the official
# container image (docker, then podman). Returns 127 when no runner exists so
# callers can decide what to do — CI is the hard gate either way.

gl_root="$(git rev-parse --show-toplevel)"
gl_image="ghcr.io/gitleaks/gitleaks:latest"

gl_run() {
  # gl_run <gitleaks args...> — always scan the repo root, exactly once
  if command -v gitleaks >/dev/null 2>&1; then
    (cd "$gl_root" && gitleaks "$@")
    return $?
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker run --rm -v "$gl_root:/repo" -w /repo "$gl_image" "$@"
    return $?
  fi
  if command -v podman >/dev/null 2>&1; then
    podman run --rm -v "$gl_root:/repo" -w /repo "$gl_image" "$@"
    return $?
  fi
  return 127
}

gl_verdict() {
  # gl_verdict <exit code> <what> — shared wording for both hooks
  case "$1" in
    0) return 0 ;;
    127)
      printf '\n!! gitleaks not found (no binary, no docker/podman) — skipping the local scan.\n' >&2
      printf '   CI still scans every push, but install it for the local safety net:\n' >&2
      printf '     go install github.com/gitleaks/gitleaks/v8@latest   # or: brew install gitleaks\n\n' >&2
      return 0
      ;;
    *)
      printf '\n' >&2
      printf 'XX gitleaks found a secret in %s — blocked.\n' "$2" >&2
      printf '   - never commit real credentials: docs, logs and screenshots included\n' >&2
      printf '   - placeholders belong in .env.example / README (change-me, Xk39Qp...)\n' >&2
      printf '   - if it is a genuine false positive, add it to .gitleaks.toml allowlist\n' >&2
      printf '   - deliberate bypass: GITLEAKS_SKIP=1 git <command>\n\n' >&2
      return 1
      ;;
  esac
}
