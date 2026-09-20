# syntax=docker/dockerfile:1
# Bump the base image to upgrade OpenCode, e.g.
#   docker build --build-arg OPENCODE_IMAGE=ghcr.io/anomalyco/opencode:2.1.0
ARG OPENCODE_IMAGE=ghcr.io/anomalyco/opencode:2.0.6

# hadolint ignore=DL3006
FROM ${OPENCODE_IMAGE}

LABEL org.opencontainers.image.title="tty-tunnel-opencode" \
      org.opencontainers.image.description="OpenCode v2 in a container with sshd, tmux and a developer toolset, ready to be opened from a Termix tab." \
      org.opencontainers.image.source="https://github.com/eslider/tty-tunnel" \
      org.opencontainers.image.url="https://github.com/eslider/tty-tunnel" \
      org.opencontainers.image.licenses="MIT"

# Extra packages for a fat image, e.g. --build-arg EXTRA_TOOLS="gcc musl-dev nodejs npm"
ARG EXTRA_TOOLS=""

# hadolint ignore=DL3018
RUN apk add --no-cache \
      openssh-server su-exec bash zsh tmux git github-cli \
      fzf ripgrep fd bat exa jq yq-go curl wget unzip less \
      vim neovim tree htop ncdu zoxide direnv lazygit \
      coreutils findutils procps iproute2 bind-tools netcat-openbsd socat rsync \
      ncurses-terminfo tzdata ca-certificates openssl sudo shadow \
      ${EXTRA_TOOLS} \
 && mkdir -p /home/opencode /workspace

COPY sshd_config /etc/ssh/sshd_config
COPY shell.sh /usr/local/bin/opencode-shell
COPY entrypoint.sh /usr/local/bin/opencode-entrypoint
RUN chmod +x /usr/local/bin/opencode-shell /usr/local/bin/opencode-entrypoint \
 && grep -qx /usr/local/bin/opencode-shell /etc/shells 2>/dev/null \
 || echo /usr/local/bin/opencode-shell >>/etc/shells

VOLUME ["/home/opencode", "/workspace"]
EXPOSE 22

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["pgrep", "-x", "sshd"]

ENTRYPOINT ["/usr/local/bin/opencode-entrypoint"]
