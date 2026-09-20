# tty-tunnel

[![ci](https://github.com/eSlider/tty-tunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/eSlider/tty-tunnel/actions/workflows/ci.yml)
[![smoke](https://github.com/eSlider/tty-tunnel/actions/workflows/smoke.yml/badge.svg)](https://github.com/eSlider/tty-tunnel/actions/workflows/smoke.yml)
[![ghcr](https://img.shields.io/badge/ghcr.io-eslider%2Ftty--tunnel-blue)](https://github.com/eSlider/tty-tunnel/pkgs/container/tty-tunnel)
[![ghcr opencode](https://img.shields.io/badge/ghcr.io-eslider%2Ftty--tunnel--opencode-blue)](https://github.com/eSlider/tty-tunnel/pkgs/container/tty-tunnel-opencode)

Run [Termix](https://github.com/Termix-SSH/Termix) (a self-hosted web SSH
client) behind a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/),
inside Docker, with one command.

`tty-tunnel` is a tiny wrapper around `cloudflared`. You give it a port, it
gives you a public URL, prints it, and saves it to `var/host/` — so you can
reach a service on your machine (or in a Compose network) from anywhere,
without opening a single inbound port on your router or firewall.

On first run it also:

- creates the Termix **admin user with a generated password**,
- **closes self-registration** before the tunnel is ever exposed,
- generates an **SSH key** and seeds a "Local host" entry in Termix, so you can
  SSH into the machine the tunnel runs on right away,
- writes the credentials to **`etc/config.yml`** and **`.env`** (both `chmod 600`,
  both gitignored).

```
Internet ──https──▶ Cloudflare edge ──tunnel──▶ tty-tunnel ──▶ Termix :8080
                        (trycloudflare.com)       (cloudflared)

Termix ──ssh──▶ opencode container (isolated; no published ports)
```

> **TryCloudflare is for testing and development only.** No SLA, no uptime
> guarantee, a 200 in-flight request cap (`429` beyond that) and no SSE support.
> For anything real, use a named tunnel on a domain you own. See
> [Limitations](#limitations).

---

## One-liner

<img width="1263" height="1285" alt="image" src="https://github.com/user-attachments/assets/912f7c90-93fc-4fa3-b6a9-30ccf27a4866" />


```bash
curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/main/tty-tunnel.sh | sh
```

That is the whole install. The script checks for a container runtime, downloads
the repo into `~/.tty-tunnel` (override with `TTT_HOME`), builds and starts the
stack, waits for the Cloudflare URL, and prints the access table:

**Fresh machine?** On Ubuntu/Debian with nothing installed, the script installs
Docker Engine for you from the [official apt repository](https://docs.docker.com/engine/install/ubuntu/)
(asking first when it has a terminal), adds you to the `docker` group and
continues — `sudo` is all it needs. Podman is detected and used automatically
when Docker is absent. `TTT_INSTALL=no` never installs anything,
`TTT_INSTALL=yes` skips the prompt.

```
  tty-tunnel — running now
  ──────────────────────────────────────────────────────────────
  Public URL    https://three-random-words.trycloudflare.com
  Local Termix  http://localhost:8080
  Admin user    admin
  Admin pass    Xk39Qp2vLm7TzR8aBcD4eF1g
  SSH preset    ano@host.docker.internal:22
  Checkout      /home/you/.tty-tunnel
  ──────────────────────────────────────────────────────────────

  checks
  ──────────────────────────────────────────────────────────────
  GET  /                     200
  POST /users/login          200
  registration               closed
  ──────────────────────────────────────────────────────────────
```

Open the public URL, log in with the generated credentials and click
"Local host" for a shell.

Same script as a small CLI (handy after the first run, or from a clone as
`./tty-tunnel.sh`):

```bash
sh ~/.tty-tunnel/tty-tunnel.sh pass    # print the table again
sh ~/.tty-tunnel/tty-tunnel.sh url     # just the public URL
sh ~/.tty-tunnel/tty-tunnel.sh logs    # follow the logs
sh ~/.tty-tunnel/tty-tunnel.sh down    # stop, keep all data
sh ~/.tty-tunnel/tty-tunnel.sh reset   # DESTRUCTIVE: wipe everything
```

Pin to a release instead of `main` if you prefer:

```bash
curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/v1.0.0/tty-tunnel.sh | sh
```

### OpenCode in a Termix tab

```bash
curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/main/tty-tunnel.sh | sh -s -- opencode
```

Same stack, plus an isolated [OpenCode v2](https://opencode.ai/v2/docs) container
and a Termix **default workspace that opens one `opencode` tab** on login. The
tab lands directly in the OpenCode TUI — inside `tmux`, so it survives page
reloads and reconnects — working in the container's `/workspace`.

Just OpenCode, no server and no Termix:

```bash
curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/main/opencode.sh | sh
```

That runs the same image interactively in your terminal with the **current
directory** mounted at `/workspace`. See [OpenCode](#opencode) for the details.

## Quick start

Prefer to see the code first? Clone it. Requirements: a container runtime —
Docker with the Compose plugin (the one-liner above installs it on
Ubuntu/Debian) or Podman — and `make` (optional).

```bash
git clone https://github.com/eslider/tty-tunnel.git
cd tty-tunnel
make up
```

`make up` will:

1. create `.env` from `.env.example` with your `PUID`/`PGID`, `SSH_USER` and
   `$HOME/.ssh` path,
2. build and start `termix` + `bootstrap` + `tunnel`,
3. wait for the Cloudflare URL,
4. print the URL and the generated Termix credentials.

```
  tty-tunnel is initialised
  ----------------------------------------------------------
  Termix     : http://localhost:8080
  admin user : admin
  admin pass : Xk39Qp2vLm7TzR8aBcD4eF1g
  saved in   : etc/config.yml and .env
  SSH preset : ano@host.docker.internal:22 (key authorized: true)
  ----------------------------------------------------------

  tty-tunnel is live
  ----------------------------------------------------------
  public URL : https://three-random-words.trycloudflare.com
  forwarding : http://termix:8080
  saved to   : /var/host/url.txt
  ----------------------------------------------------------
```

Open the public URL, log in with the generated credentials, and click the
"Local host" host to get a shell. Add the isolated OpenCode tab with
`make opencode` (see [OpenCode](#opencode)).

Without `make`:

```bash
cp .env.example .env        # then edit PUID/PGID/SSH_USER/HOST_SSH_DIR
docker compose up -d --build
cat var/host/url.txt
cat etc/config.yml
```

### Just the tunnel (no Termix)

The tunnel image is published to GHCR and can forward any port, on its own:

```bash
docker run --rm \
  --add-host host.docker.internal:host-gateway \
  -e PORT=3000 \
  -v "$PWD/var/host:/var/host" \
  ghcr.io/eslider/tty-tunnel:latest
```

`PORT` is the only required setting. The public URL is printed and written to
`./var/host/url.txt`.

---

## What ends up where

| Path | What | Gitignored |
|---|---|---|
| `var/host/url.txt` | current public URL | yes |
| `var/host/hostname.txt` | hostname only | yes |
| `var/host/history.log` | every URL seen, with timestamps | yes |
| `var/host/cloudflared.log` | cloudflared logs | yes |
| `var/termix/` | Termix database, keys, certificates | yes |
| `var/ssh/id_ed25519` | SSH key generated on first run | yes |
| `var/opencode/home/` | OpenCode config, credentials, sessions (container home) | yes |
| `var/opencode/workspace/` | the OpenCode container's isolated working directory | yes |
| `etc/config.yml` | generated admin credentials + prep state (`0600`) | yes |
| `.env` | comes from `.env.example`, gets the generated password | yes |

Check the tunnel at any time with `make url`; show credentials with `make pass`.

---

## Configuration (`.env`)

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | Port on `TARGET_HOST` to forward. The only required setting. |
| `TARGET_HOST` | `termix` | Where to forward. Compose service name, or `host.docker.internal` for a host port. |
| `TARGET_PROTO` | `http` | `http` or `https`. |
| `TERMIX_LOCAL_PORT` | `8080` | Host port Termix is published on, bound to `127.0.0.1` only. |
| `TERMIX_ADMIN_USER` | `admin` | Admin username created on first run. |
| `SSH_USER` | `$USER` | Username for the seeded "Local host" SSH entry. |
| `SSH_HOST` | `host.docker.internal` | Hostname of the seeded SSH entry. |
| `SSH_PORT` | `22` | Port of the seeded SSH entry. |
| `AUTHORIZE_SSH_KEY` | `true` | Append the generated public key to `HOST_SSH_DIR/authorized_keys`. |
| `HOST_SSH_DIR` | `$HOME/.ssh` | Mounted read-write into the one-shot `bootstrap` container only. |
| `PUID` / `PGID` | `1000` | Ownership of files written into `var/`. |
| `TUNNEL_TOKEN` | – | Named-tunnel token → **persistent** hostname (see below). |
| `TUNNEL_HOSTNAME` | – | Hostname to report for a token-managed tunnel. |
| `OPENCODE_ENABLED` | `0` | Set to `1` by `tty-tunnel.sh opencode` / `make opencode`. |
| `OPENCODE_SSH_USER` | `opencode` | Account inside the OpenCode container. |
| `OPENCODE_SSH_PASSWORD` | generated | Fallback password for that account (Termix uses the SSH key). |
| `OPENCODE_WORKDIR` | `/workspace` | Where OpenCode starts inside the container. |
| `OPENCODE_SEED` | `true` | Copy your host OpenCode config/credentials in once. |
| `OPENCODE_CONFIG_DIR` | `~/.config/opencode` | Read-only seed source for the config. |
| `OPENCODE_DATA_DIR` | `~/.local/share/opencode` | Read-only seed source for `auth.json`. |
| `OPENCODE_WORKSPACE` | `opencode` | Name of the Termix default workspace that is seeded. |

Extra, for the raw tunnel image: `HOST_DIR`, `METRICS_ADDR`, `READY_TIMEOUT`.

---

## OpenCode

Run [OpenCode v2](https://opencode.ai/v2/docs) in its own container, isolated
from your host, and open it from a Termix tab.

```bash
./tty-tunnel.sh opencode        # or: make opencode
```

What that adds:

- **`opencode` service** — `ghcr.io/eslider/tty-tunnel-opencode`, built from
  [`opencode/Dockerfile`](opencode/Dockerfile): the official OpenCode v2 image
  (Alpine) plus `openssh-server`, `tmux`, `bash`/`zsh`, `git`, `gh`, `fzf`,
  `ripgrep`, `fd`, `bat`, `eza` (the maintained `exa`), `jq`, `yq`, `vim`,
  `neovim`, `zoxide`, `direnv`, `lazygit`, `tree`, `htop`, `rsync`, `socat` and
  more (`EXTRA_TOOLS` build arg for anything else).
- **Termix host preset** `opencode@opencode:22`, key-based, using the SSH key the
  bootstrap already generates.
- **Default workspace `opencode`** with a single terminal tab. On login Termix
  auto-applies the default workspace, so the OpenCode tab is simply there.

### What opens

The tab connects over SSH and the container's login shell attaches to a
persistent `tmux` session running `opencode` in `/workspace`, so closing the
browser or reloading the page keeps the session alive. Plain shells still work:

```bash
docker compose exec opencode su-exec opencode bash
# from another container on the compose network:
ssh -i var/ssh/id_ed25519 opencode@opencode 'opencode --version'
```

### Credentials

Your host's `~/.config/opencode` and `~/.local/share/opencode/auth.json` are
mounted **read-only** and copied into the container's own volume on first start
(set `OPENCODE_SEED=false` to skip). Your host files are never written to, and
the multi-hundred-MB session database is not copied. Change providers later from
inside the tab with `opencode auth login`.

### Isolation

Only three things cross the boundary: the read-only seed, the read-only SSH key,
and `var/opencode/workspace` mounted at `/workspace`. Nothing else of yours is
visible. To let it loose on a real project:

```yaml
# docker-compose.override.yml
services:
  opencode:
    volumes:
      - ./my-project:/workspace
```

### Terminal only (no Termix)

```bash
curl -fsSL https://raw.githubusercontent.com/eSlider/tty-tunnel/main/opencode.sh | sh
```

or directly:

```bash
docker run --rm -it \
  -v tty-tunnel-opencode-home:/home/opencode \
  -v "$PWD:/workspace" \
  -v "$HOME/.config/opencode:/seed/config:ro" \
  -v "$HOME/.local/share/opencode:/seed/data:ro" \
  ghcr.io/eslider/tty-tunnel-opencode:latest
```

The standalone run mounts the **current directory** as `/workspace` — the point
of a coding agent — while the Termix path stays fully isolated.
`OPENCODE_IMAGE`, `OPENCODE_MODE=tui|sshd` and `OPENCODE_SEED` are available for
both paths.

## Persistent hostname

A quick tunnel gets a **random `*.trycloudflare.com` hostname on every start**,
and that name cannot be reserved or reused. That is a Cloudflare limitation, not
a limitation of this repo — `var/host/hostname.txt` is a record, not a lease.

For a stable hostname you need a named tunnel, which requires a (free)
Cloudflare account and a domain on Cloudflare:

1. In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/)
   create a tunnel and copy its token.
2. Point its public hostname at `http://termix:8080` (or `http://localhost:8080`
   with the host-network override).
3. Put the token in `.env`:
   ```env
   TUNNEL_TOKEN=eyJhIjoi...
   TUNNEL_HOSTNAME=termix.example.com
   ```
4. `docker compose up -d tunnel`

The hostname is now defined by Cloudflare and survives every restart.

<details>
<summary>Alternative: locally-managed tunnel credentials</summary>

```bash
make login        # one-time browser login, cert stored in var/host/cloudflared
```
Then create/route the tunnel with `cloudflared tunnel create` /
`cloudflared tunnel route dns` via `docker compose run --rm tunnel cloudflared ...`.
The token flow above is simpler for most people.
</details>

---

## CI/CD

`.github/workflows/`:

- **`ci.yml`** – shellcheck + hadolint, then builds and pushes two multi-arch
  (`linux/amd64`, `linux/arm64`) images: `ghcr.io/eslider/tty-tunnel` (the
  cloudflared wrapper) and `ghcr.io/eslider/tty-tunnel-opencode` (OpenCode +
  toolset). Pull requests build but never push. Provenance and SBOM included.
  Image tags:

  | Ref | Tags |
  |---|---|
  | push to `main` | `edge`, `main`, `sha-<commit>` |
  | tag `vX.Y.Z` | `X.Y.Z`, `X.Y`, `X`, `latest`, `sha-<commit>` |

- **`release-please.yml`** – automatic [semantic versioning](https://github.com/googleapis/release-please)
  driven by [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:` → minor, `fix:` → patch, `feat!:`/`BREAKING CHANGE:` → major.
  It opens a *Release PR* that bumps `version.txt`,
  `.release-please-manifest.json` and `CHANGELOG.md`; merging it tags
  `vX.Y.Z` and creates the GitHub Release, then dispatches `ci.yml` on the new
  tag to publish the versioned images. (That dispatch is needed because tags
  created with the default `GITHUB_TOKEN` do not trigger workflows by themselves.)
  A manual `git push` of a tag triggers the same build directly.
  PR checks on a release-please PR show as skipped/failed with no jobs — GitHub
  does not start workflows for PRs opened with `GITHUB_TOKEN`. It is harmless.
- **`smoke.yml`** – starts the real stack, waits for the Cloudflare URL, then
  reaches Termix and logs in **through the public URL**. A second, independent
  job builds the OpenCode image and proves key auth, exec, SFTP and that an
  interactive session lands in the OpenCode TUI. Both are marked
  `continue-on-error` because TryCloudflare rate-limits CI IPs.

> A brand-new quick-tunnel hostname can take a few seconds to resolve, and local
> stub resolvers (`systemd-resolved`) may briefly cache it as `NXDOMAIN`. The
> smoke test falls back to resolving over Cloudflare DoH for that reason. If a
> fresh URL does not open for you, retry after a few seconds or flush the cache
> with `resolvectl flush-caches`.

### Cutting a release

Normally you do nothing: merge Conventional Commits to `main`, then merge the
Release PR that `release-please` opens.

To release manually:

```bash
make release VERSION=1.2.3      # or: scripts/release.sh 1.2.3
```

That updates `version.txt` + the manifest, commits, tags `v1.2.3`, pushes and
creates the GitHub Release; CI then publishes the image tags.

### Using a version

```bash
docker run --rm --add-host host.docker.internal:host-gateway \
  -e PORT=3000 -v "$PWD/var/host:/var/host" \
  ghcr.io/eslider/tty-tunnel:1.2.3     # pin
  # ghcr.io/eslider/tty-tunnel:1       # track the 1.x line
  # ghcr.io/eslider/tty-tunnel:latest  # newest release
  # ghcr.io/eslider/tty-tunnel:edge    # every push to main

docker run --rm -it -v "$PWD:/workspace" \
  ghcr.io/eslider/tty-tunnel-opencode:1.2.3   # same tags for the OpenCode image
```

The Termix image itself is upstream (`ghcr.io/lukegus/termix`); this repo builds
the tunnel wrapper, the bootstrap helper and the OpenCode image.

### GHCR package visibility

The first push creates the package as **private** even in a public repo. To make
the one-liner work for everyone, set both packages public once:

```bash
gh api -X PATCH /user/packages/container/tty-tunnel/visibility \
  -f visibility=public            # needs a PAT with the packages:write scope
gh api -X PATCH /user/packages/container/tty-tunnel-opencode/visibility \
  -f visibility=public
```

or do it in the UI: *Package settings → Change visibility → Public*.

---

## Security

This project puts a **web SSH client on a public URL**. Treat it accordingly.

- The admin password is generated (>100 bits of entropy) and registration is
  closed right after it is created. Change the password and enable TOTP 2FA in
  Termix after the first login.
- The `bootstrap` container finishes **before** the tunnel starts, so Termix is
  never publicly reachable while registration is open.
- Termix is only published on `127.0.0.1:8080` locally — remove the `ports:`
  mapping entirely if you want tunnel-only access.
- `AUTHORIZE_SSH_KEY=true` appends one public key (comment `tty-tunnel first-run key`)
  to `~/.ssh/authorized_keys`. To revoke, delete that line and remove the host
  from Termix; to skip entirely, set `AUTHORIZE_SSH_KEY=false`.
- The OpenCode container has **no published ports** and is only reachable from
  the Compose network. It shares that same SSH key; `OPENCODE_SEED=true` copies
  your host provider credentials into its volume (read-only source, container
  copy only) — set it to `false` if you would rather log in inside the tab.
- For anything beyond a test, use a named tunnel plus
  [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/)
  in front of it.

## Operations

```bash
make up        # start, wait for the URL, print credentials
make opencode  # same, plus the isolated OpenCode container and its Termix tab
make url       # print the current public URL
make pass      # print the Termix credentials
make logs      # follow logs
make down      # stop, keep all data
make clean     # stop, drop URL and logs
make reset     # DESTRUCTIVE: wipe var/, credentials and .env
```

`restart: unless-stopped` on `termix` and `tunnel` means the stack comes back
after a reboot — as long as the Docker daemon is enabled (`systemctl enable docker`).

Services bound to `127.0.0.1` on the host are not reachable through the Docker
bridge. Use the host-network override:

```bash
docker compose -f docker-compose.yml -f docker-compose.hostnet.yml up -d
```

## Limitations

TryCloudflare quick tunnels ([`try.cloudflare.com`](https://try.cloudflare.com/)):

- **Random hostname each start** — cannot be reserved or reused.
- **200 concurrent in-flight requests** — beyond that the response is `429`.
- **No Server-Sent Events (SSE).**
- **No SLA or uptime guarantee** — Cloudflare explicitly calls them a testing
  and development tool, not a production deployment.
- Other quick-tunnel caveats: a `config.yaml` in `.cloudflared` can disable the
  quick-tunnel path, and the tunnel dies with the container (that is what
  `restart: unless-stopped` is for).

These limits do not apply to named tunnels on your own domain.

Links: [TryCloudflare](https://try.cloudflare.com/) ·
[Quick Tunnels docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/) ·
[cloudflared downloads](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) ·
[Termix](https://github.com/Termix-SSH/Termix) ·
[Termix docs](https://docs.termix.site)

## Credits & license

MIT — see [LICENSE](LICENSE).

Bundles/uses third-party software, each under its own license:
[cloudflared](https://github.com/cloudflare/cloudflared) (Apache-2.0),
[Termix](https://github.com/Termix-SSH/Termix) (Apache-2.0),
[OpenCode](https://opencode.ai) (MIT),
[guacamole/guacd](https://hub.docker.com/r/guacamole/guacd) (Apache-2.0).
