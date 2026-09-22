# syntax=docker/dockerfile:1
# Lightweight browser TTY: gotty (xterm.js over WebSocket) plus an ssh client,
# so the tunnel can point straight at a shell on the host. WebSocket only — no
# SSE — so it works on Cloudflare Quick Tunnels where opencode's web UI cannot.
#
#   docker build --build-arg GOTTY_VERSION=v1.8.1 ./gotty
ARG GOTTY_VERSION=v1.8.0

FROM alpine:3.21 AS fetch
ARG GOTTY_VERSION
ARG TARGETARCH
SHELL ["/bin/ash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3018
RUN apk add --no-cache curl
WORKDIR /tmp
# hadolint ignore=DL3018
RUN arch="${TARGETARCH:-$(uname -m)}" \
 && case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac \
 && asset="gotty_${GOTTY_VERSION}_linux_${arch}.tar.gz" \
 && curl -fsSLO "https://github.com/sorenisanerd/gotty/releases/download/${GOTTY_VERSION}/${asset}" \
 && curl -fsSLO "https://github.com/sorenisanerd/gotty/releases/download/${GOTTY_VERSION}/SHA256SUMS" \
 && grep " ${asset}\$" SHA256SUMS | sha256sum -c - \
 && tar -xzf "$asset" \
 && test -x /tmp/gotty \
 && /tmp/gotty --version

FROM alpine:3.21

LABEL org.opencontainers.image.title="tty-tunnel-gotty" \
      org.opencontainers.image.description="gotty + ssh client: a lightweight browser terminal for tty-tunnel, aimed at the host's shell." \
      org.opencontainers.image.source="https://github.com/eslider/tty-tunnel" \
      org.opencontainers.image.url="https://github.com/eslider/tty-tunnel" \
      org.opencontainers.image.licenses="MIT"

# hadolint ignore=DL3018
RUN apk add --no-cache openssh-client bash tmux ca-certificates tzdata ncurses-terminfo \
 && mkdir -p /root/.ssh \
 && chmod 700 /root/.ssh

COPY --from=fetch /tmp/gotty /usr/local/bin/gotty
COPY entrypoint.sh /usr/local/bin/gotty-entrypoint
RUN chmod +x /usr/local/bin/gotty-entrypoint

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["nc", "-z", "127.0.0.1", "8080"]

ENTRYPOINT ["/usr/local/bin/gotty-entrypoint"]
