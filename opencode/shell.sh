#!/bin/sh
# Login shell for the `opencode` user (set as the account shell).
#
# Opening a session therefore drops straight into the OpenCode TUI inside a
# persistent tmux session, while `ssh host <command>` and the SFTP subsystem
# (which sshd handles itself, bypassing the login shell) keep working normally.
set -eu

if [ "${1:-}" = "-c" ]; then
  shift
  exec /bin/sh -c "$*"
fi

# sshd does not pass the container environment to sessions, so fall back to the
# well-known workspace unless the variable is set another way.
WORKDIR="${OPENCODE_WORKDIR:-/workspace}"
[ -d "$WORKDIR" ] || WORKDIR="$HOME"

export TERM="${TERM:-xterm-256color}"
export COLORTERM="${COLORTERM:-truecolor}"
exec tmux new-session -A -s opencode -c "$WORKDIR" opencode
