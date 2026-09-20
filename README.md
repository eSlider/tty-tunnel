# tty-tunnel

[![ci](https://github.com/eSlider/tty-tunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/eSlider/tty-tunnel/actions/workflows/ci.yml)
[![smoke](https://github.com/eSlider/tty-tunnel/actions/workflows/smoke.yml/badge.svg)](https://github.com/eSlider/tty-tunnel/actions/workflows/smoke.yml)
[![ghcr](https://img.shields.io/badge/ghcr.io-eslider%2Ftty--tunnel-blue)](https://github.com/eSlider/tty-tunnel/pkgs/container/tty-tunnel)

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
```

> **TryCloudflare is for testing and development only.** No SLA, no uptime
> guarantee, a 200 in-flight request cap (`429` beyond that) and no SSE support.
> For anything real, use a named tunnel on a domain you own. See
> [Limitations](#limitations).

---

## Quick start

Requirements: Docker with the Compose plugin, and `make` (optional).

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
"Local host" host to get a shell.

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

Extra, for the raw tunnel image: `HOST_DIR`, `METRICS_ADDR`, `READY_TIMEOUT`.

---

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

- **`ci.yml`** – shellcheck + hadolint, then builds and pushes a multi-arch
  (`linux/amd64`, `linux/arm64`) image to `ghcr.io/eslider/tty-tunnel`. Pull
  requests build but never push. Provenance and SBOM included. Image tags:

  | Ref | Tags |
  |---|---|
  | push to `main` | `edge`, `main`, `sha-<commit>` |
  | tag `vX.Y.Z` | `X.Y.Z`, `X.Y`, `X`, `latest`, `sha-<commit>` |

- **`release-please.yml`** – automatic [semantic versioning](https://github.com/googleapis/release-please)
  driven by [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:` → minor, `fix:` → patch, `feat!:`/`BREAKING CHANGE:` → major.
  It opens a *Release PR* that bumps `version.txt`,
  `.release-please-manifest.json` and `CHANGELOG.md`; merging it tags
  `vX.Y.Z` and creates the GitHub Release, which triggers the versioned image
  build above.
- **`smoke.yml`** – starts the real stack, waits for the Cloudflare URL, then
  reaches Termix and logs in **through the public URL**. It is marked
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
```

The Termix image itself is upstream (`ghcr.io/lukegus/termix`); this repo only
builds the tunnel wrapper and the bootstrap helper.

### GHCR package visibility

The first push creates the package as **private** even in a public repo. To make
the one-liner work for everyone, set it public once:

```bash
gh api -X PATCH /user/packages/container/tty-tunnel/visibility \
  -f visibility=public            # needs a PAT with the packages:write scope
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
- For anything beyond a test, use a named tunnel plus
  [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/)
  in front of it.

## Operations

```bash
make up        # start, wait for the URL, print credentials
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
[guacamole/guacd](https://hub.docker.com/r/guacamole/guacd) (Apache-2.0).
