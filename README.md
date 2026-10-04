# dev-server

Browser-based dev environment for a personal Debian VM: **code-server** (VS Code
in the browser) with Claude Code, GitHub CLI, tmux, Node.js and Docker CLI,
exposed through a **Cloudflare Tunnel** behind **Cloudflare Access** (GitHub
login) and code-server's own password. Setup of the host and VM is described
in [dev-server-plan.md](dev-server-plan.md); this repo is the part that runs
inside the VM.

This repository is public and contains no secrets. Passwords and the tunnel
token are entered at bootstrap time and stored only in `.env` (mode 600,
git-ignored). Claude Code is logged in interactively and `gh` with a
fine-grained GitHub token (`gh auth login --with-token`, see Phase 4 of the plan)
from the code-server terminal; credentials live in `./config`.

## Fresh install: the setup scripts

From a freshly installed Debian host to a working stack, mostly by script. Every
script explains each question before it asks it and can be re-run safely
(`--dry-run` shows what it would do). Details, the safety design and a test
protocol: [doc/setup-scripts.md](doc/setup-scripts.md).

| Step | Where | Command |
|---|---|---|
| 0. Install Debian 13 on the host (netinst; hostname `devhost`, root password empty, SSH server and standard utilities only) and set the BIOS option "Restore on AC power loss: Power On" | host console | by hand (plan 0.1, 5.1) |
| 1. SSH key and aliases | notebook | `setup/notebook-setup.sh` |
| 2. Harden the host, firewall, KVM, VM network | host | `sudo apt install -y git && git clone <this repo> ~/dev-server-repo && ~/dev-server-repo/setup/host-setup.sh` |
| 3. Create the VM (Debian cloud image and cloud-init) | host | `~/dev-server-repo/setup/create-vm.sh` |
| 4. Wait for the first boot, then start the stack | notebook, then VM | `ssh devvm 'cloud-init status --wait'`, `ssh devvm`, `cd ~/dev-server && ./bootstrap.sh` |
| 5. Check isolation and health | notebook | `ssh devvm 'bash -s -- <router-ip> <host-lan-ip> 192.168.150.1' < setup/verify-isolation.sh`, then `./bootstrap.sh --check` in the VM |
| 6. Remove the seed disk (holds a password hash) | host | `~/dev-server-repo/setup/create-vm.sh --finish` |

Still by hand, because there is no API or it is physical: the Cloudflare tunnel,
its public hostname and the Access policy (plan 2.1 and Phase 3; you paste the
tunnel token into `bootstrap.sh`), the GitHub fine-grained token and the Claude
login (plan Phase 4).

## Quick start (container stack only; inside the VM, as a normal user with sudo)

```bash
git clone https://github.com/MartinsCodingProjects/code-server-bootstrap.git ~/dev-server
cd ~/dev-server
./bootstrap.sh
```

`bootstrap.sh` installs Docker Engine if missing, asks for a code-server
password (min. 12 chars) and an optional Cloudflare Tunnel token, writes `.env`,
then builds and starts the stack. Without a token only `127.0.0.1:8443` is
served; reach it from your notebook with `ssh -L 8443:127.0.0.1:8443 devvm`.

| Command | Purpose |
|---|---|
| `./bootstrap.sh` | First run or re-run; keeps an existing `.env` |
| `./bootstrap.sh --reconfigure` | Ask for password and token again |
| `./bootstrap.sh --update` | `git pull`, re-run the pulled script, refresh host-derived values and pinned versions in `.env`, rebuild, restart |
| `./bootstrap.sh --check` | Read-only health check of the running stack (non-zero exit on failure) |
| `DEV_PASSWORD=... TUNNEL_TOKEN=... ./bootstrap.sh` | Non-interactive |

## Developing in the browser (Flask, FastAPI, Vite and React)

The container has Python 3.12 with `uv`, Node.js 22 with npm, git, `gh`, tmux, the
Docker CLI and Claude Code. Keep projects under `projects/` (the terminal opens
there). Dev servers run **inside the container**; to open them in your browser,
give each one a hostname of its own through the tunnel.

**One-time, in the Cloudflare dashboard** (per app you want to open in the browser):

1. Zero Trust, Networks, Tunnels, your tunnel, Public Hostname, Add: subdomain
   e.g. `web`, your domain, service type **HTTP**, URL **`code-server:5173`**
   (the Vite port). Add `api` with `code-server:8000` if you want to open the
   FastAPI docs, `flask` with `code-server:5000`, and so on. The tunnel reaches the
   container's ports directly, so nothing is published on the VM.
2. Add every new hostname to your **Access application** (same GitHub login
   policy). A hostname without it would be a public dev server.
3. On the VM, list them so `./bootstrap.sh --check` verifies the Access redirect for
   each: `echo "DEV_HOSTS='web.yourdomain.com api.yourdomain.com'" >> ~/dev-server/.env`

**Every day:** start the server listening on all interfaces and open its hostname.

```bash
ct$ cd /home/martin/dev-server/projects/myapp
ct$ uv run flask --app app run --host 0.0.0.0 --port 5000 --debug       # Flask
ct$ uv run uvicorn app:app --host 0.0.0.0 --port 8000 --reload          # FastAPI (docs at /docs)
ct$ npm run dev -- --host                                               # Vite / React
ct$ uv run pytest;  npm test                                            # tests
```

Vite needs to accept the hostname and send hot-reload over https (`vite.config.js`):

```js
export default defineConfig({
  server: {
    host: true,                                   // all interfaces inside the container
    port: 5173,
    allowedHosts: ['web.yourdomain.com'],         // Vite rejects unknown Host headers
    hmr: { clientPort: 443 },                     // hot reload websocket through https
    proxy: { '/api': 'http://localhost:8000' },   // frontend and API on ONE origin
  },
})
```

Let the frontend call the API through that Vite proxy (`fetch('/api/...')`).
Calling `api.yourdomain.com` from `web.yourdomain.com` is a cross-origin request, and
Cloudflare Access (a cookie per hostname) blocks it. Use a separate hostname only for
pages you open directly, such as FastAPI's `/docs`.

Without any Cloudflare change you can use code-server's built-in proxy for a quick look:
`https://dev.yourdomain.com/absproxy/5173/` keeps the path, so set Vite's
`base: '/absproxy/5173/'`; `/proxy/8000/` strips it (`uvicorn ... --root-path /proxy/8000`).
Flask needs prefix handling for this, so use a hostname for Flask.

**Docker-based projects:** `docker compose` works through the mounted socket. Bind
mounts resolve on the **VM**, so keep them under `projects/` (same path inside and
out). Publish ports as `127.0.0.1:PORT:PORT` and reach them with
`ssh -L PORT:127.0.0.1:PORT devvm`. For browser tests run a test image inside the
container's network: `docker run --rm --network container:code-server <image> ...`
(then `localhost:5173` is your dev server).

## Layout

| Path | Purpose |
|---|---|
| `setup/` | Scripts for a fresh install: notebook, host and VM creation, isolation check |
| `Dockerfile` | code-server + Node.js, Claude Code, `gh`, tmux, Docker CLI/Compose |
| `docker-compose.yml` | `code-server` and `cloudflared` (profile `tunnel`) |
| `.env.example` | Documents the variables `bootstrap.sh` writes |
| `config/` | code-server user data and logins (git-ignored) |
| `projects/` | Your workspaces (git-ignored), mounted at the same absolute path inside the container |
| `doc/cli-cheatsheet.md` | Commands for operating and maintaining the setup, plus troubleshooting |
| `doc/setup-scripts.md` | What the setup scripts do, their safety design, test protocol |
| `doc/` | Also notes kept for the record, e.g. the resolved review of this setup |

## Updating

Do this about monthly, or when a security fix is announced for code-server,
`cloudflared` or Claude Code. Do it while idle: a rebuild restarts code-server and
ends running tmux sessions and Claude processes.

1. **Check for newer tags:** `linuxserver/docker-code-server` releases (tags look
   like `4.140.0-ls368`) and `cloudflare/cloudflared` releases.
2. **Bump the pins and commit** (from the notebook):
   - `CODE_SERVER_VERSION`: the `ARG` in `Dockerfile`, the default in
     `docker-compose.yml`, and `.env.example`.
   - `CLOUDFLARED_VERSION`: the default in `docker-compose.yml` and `.env.example`.
   - `DOCKER_CLI_VERSION` and `UV_VERSION` (optional): the `ARG`s in `Dockerfile`;
     the tags are `docker:<version>-cli` and `ghcr.io/astral-sh/uv:<version>`.
3. **Apply on the VM:** `cd ~/dev-server && ./bootstrap.sh --update`. It pulls,
   continues in the freshly pulled script, refreshes `PUID`, `PGID`, `DOCKER_GID`,
   `PROJECTS_DIR` and the pinned versions in `.env` (Compose prefers `.env`;
   password, token and `TZ` are kept), rebuilds and restarts. A new base tag rebuilds every layer, so `apt`
   packages, Node.js, `gh` and Claude Code are refreshed too.
4. **Verify:** `./bootstrap.sh --check` runs the checks below in one go
   (read-only; non-zero exit on failure). By hand:
   ```bash
   docker compose ps                              # code-server healthy, cloudflared up
   docker compose logs --tail=30 cloudflared      # "Registered tunnel connection"
   docker exec -u abc code-server sh -c 'claude --version && gh --version | head -1 && tmux -V && docker ps'
   docker exec -u abc code-server curl -sS -I https://github.com | head -n1   # HTTP/2 200 (DNS)
   ```
   Then log in at the public URL (Access, then the code-server password).
5. **Clean up** once it works: `docker image prune -f`. **Roll back** by reverting
   the version commit and running `./bootstrap.sh --update` again.

Fresher Node.js, `gh` or Claude Code without changing the base tag:
`docker compose build --pull --no-cache && ./bootstrap.sh`. This does not upgrade
the OS packages of the base image; only a newer base tag does.

**The OS layers update separately** (not part of the containers):

- Host and VM run `unattended-upgrades` for Debian and Debian-Security. Check with
  `systemctl list-timers 'apt-daily*'`, `apt list --upgradable` and
  `cat /var/run/reboot-required`. The host reboots itself at 04:00 when needed
  (which also restarts the VM); the VM does not, so reboot it after kernel updates.
- Docker's own packages on the VM come from Docker's apt repository and are not
  covered: run `sudo apt update && sudo apt upgrade` on the VM now and then (a
  Docker daemon upgrade restarts the containers).
- Do not run rebuilds unattended; an upstream release can break the build.

## Notes

- The container mounts the VM's Docker socket so projects can build and run
  containers. That grants control of the VM's Docker daemon: the VM, not the
  container, is the security boundary.
- In the code-server terminal, `terminal-w` (alias for `tmux new -As work`)
  creates or re-attaches the persistent tmux session. It is built into the image
  by `bootstrap.sh`; it is not attached automatically, so plain terminal tabs
  stay independent. Inside tmux it prints "sessions should be nested with care",
  which only means you are already in a session.
- Image versions are pinned in the Dockerfile/Compose defaults and `.env.example`;
  see [Updating](#updating) for the bump-and-apply procedure.
- Tunnel origin must be `http://code-server:8443` (not `localhost`).
- There are no backups. A rebuild from this repo and the plan restores the
  setup; only work that is not pushed to GitHub and the code-server settings in
  `config/` are lost, so push regularly (the plan's Operations section lists
  what to re-create).
- `bootstrap.sh` sets `config/` to mode 700. Container logs rotate (3 x 10 MB per
  service). `cloudflared` runs read-only with all capabilities dropped; code-server
  cannot (its init needs them, and the mounted Docker socket is root in the VM
  anyway).
- Compose pins `dns: 192.168.150.1` (the libvirt host's resolver from the plan). At boot
  Docker can otherwise start the container before `dhcpcd` wrote the VM's
  `/etc/resolv.conf` and leave it without DNS. Change it if your libvirt network differs.
