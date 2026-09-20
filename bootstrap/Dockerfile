# syntax=docker/dockerfile:1
FROM alpine:3.21

LABEL org.opencontainers.image.title="tty-tunnel-bootstrap" \
      org.opencontainers.image.description="One-shot first-run initialisation for tty-tunnel: creates the Termix admin, closes registration and seeds the SSH host preset." \
      org.opencontainers.image.source="https://github.com/eslider/tty-tunnel" \
      org.opencontainers.image.licenses="MIT"

# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates curl jq openssh-client

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
