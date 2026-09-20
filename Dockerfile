# syntax=docker/dockerfile:1
FROM alpine:3.21

LABEL org.opencontainers.image.title="tty-tunnel" \
      org.opencontainers.image.description="Cloudflare Tunnel wrapper: expose a local/Compose port on a public URL, print it and persist it in var/host." \
      org.opencontainers.image.source="https://github.com/eslider/tty-tunnel" \
      org.opencontainers.image.url="https://github.com/eslider/tty-tunnel" \
      org.opencontainers.image.licenses="MIT"

# Pin for reproducible builds, e.g. --build-arg CLOUDFLARED_VERSION=2026.9.1
ARG CLOUDFLARED_VERSION=latest

# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates wget \
 && arch="$(uname -m)" \
 && case "$arch" in \
      x86_64|amd64) cf_arch=amd64 ;; \
      aarch64|arm64) cf_arch=arm64 ;; \
      *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac \
 && wget -qO /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/${CLOUDFLARED_VERSION}/download/cloudflared-linux-${cf_arch}" \
 && chmod +x /usr/local/bin/cloudflared \
 && cloudflared --version

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/var/host"]

# cloudflared exposes a readiness endpoint on its metrics server (`--metrics`).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:2000/ready"]

ENTRYPOINT ["/entrypoint.sh"]
