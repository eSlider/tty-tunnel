SHELL := /bin/sh
COMPOSE ?= docker compose
ENV_FILE := .env
IMAGE ?= ghcr.io/eslider/tty-tunnel:latest

.DEFAULT_GOAL := help
.PHONY: help env build release up opencode wait-url down logs url pass login shell config clean reset

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

env: ## create .env from .env.example with your ids (skipped if it exists)
	@test -f $(ENV_FILE) || { \
		sed -e "s|^PUID=.*|PUID=$$(id -u)|" \
		    -e "s|^PGID=.*|PGID=$$(id -g)|" \
		    -e "s|^SSH_USER=.*|SSH_USER=$${USER:-root}|" \
		    -e "s|^HOST_SSH_DIR=.*|HOST_SSH_DIR=$${HOME}/.ssh|" \
		    .env.example > $(ENV_FILE); \
		echo "==> created $(ENV_FILE)"; }

build: ## build the tunnel image locally
	docker build -t $(IMAGE) .

release: ## tag and publish a release: make release VERSION=1.2.3
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=1.2.3"; exit 1; }
	scripts/release.sh "$(VERSION)"

up: env ## start the stack, wait for the public URL, print credentials
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory wait-url
	@$(MAKE) --no-print-directory pass

opencode: env ## start the stack plus the isolated OpenCode container and Termix tab
	OPENCODE_ENABLED=1 $(COMPOSE) --profile opencode up -d --build
	@$(MAKE) --no-print-directory wait-url
	@$(MAKE) --no-print-directory pass

wait-url: ## wait for the tunnel URL and print it
	@printf '==> waiting for the tunnel URL'
	@i=0; until [ -s var/host/url.txt ]; do \
		i=$$((i+1)); \
		if [ $$i -gt 90 ]; then echo " timed out (see: $(COMPOSE) logs tunnel)"; exit 1; fi; \
		printf '.'; sleep 2; \
	done; echo
	@printf '\n  Public URL: %s\n\n' "$$(cat var/host/url.txt)"

url: ## print the current public URL
	@cat var/host/url.txt

pass: ## print the generated Termix credentials
	@if [ -f etc/config.yml ]; then \
		sed -n 's/^  admin_user: "\(.*\)"/  user: \1/p; s/^  admin_password: "\(.*\)"/  pass: \1/p' etc/config.yml; \
	else echo "  not initialised yet — run: make up"; fi

logs: ## follow the stack logs
	$(COMPOSE) logs -f --tail=100

down: ## stop the stack (keeps all data)
	$(COMPOSE) down

login: env ## one-time cloudflared login for a locally-managed named tunnel
	$(COMPOSE) run --rm -e HOME=/var/host/cloudflared tunnel cloudflared tunnel login

shell: ## shell inside the bootstrap image (debugging)
	$(COMPOSE) run --rm --entrypoint sh bootstrap

config: ## validate and render the effective compose config
	$(COMPOSE) config

clean: ## stop the stack and drop the tunnel URL/logs
	$(COMPOSE) down
	rm -f var/host/url.txt var/host/hostname.txt var/host/cloudflared.log

reset: ## DESTRUCTIVE: remove all data, credentials and generated keys
	$(COMPOSE) down -v
	rm -rf var/termix var/ssh var/host-ssh var/opencode
	rm -f var/host/url.txt var/host/hostname.txt var/host/cloudflared.log
	rm -f etc/config.yml .env
	@echo "==> reset complete"
