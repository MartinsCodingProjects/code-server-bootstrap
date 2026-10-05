# dev-server

Browser-based dev environment for a personal Debian VM: **code-server** (VS Code
in the browser) with Claude Code, GitHub CLI, tmux, Node.js, Python and Docker CLI,
exposed through a **Cloudflare Tunnel** behind **Cloudflare Access** (GitHub
login) and code-server's own password. Dev servers (Flask, FastAPI, Vite) open in
the browser at hostnames of their own with **no changes to your projects**, and an
optional MariaDB sits on a private network that only code-server can reach.

This repository contains everything:

- the container stack that runs inside the VM (`docker-compose.yml`, `Dockerfile`,
  `bootstrap.sh`);
- `setup/`, scripts that install the host and the VM from scratch;
- the reasoning and the manual fallback: [dev-server-plan.md](dev-server-plan.md);
- day-to-day commands and troubleshooting: [doc/cli-cheatsheet.md](doc/cli-cheatsheet.md);
- how the setup scripts work and how to test them: [doc/setup-scripts.md](doc/setup-scripts.md).

This repository is public and contains no secrets. The code-server password and
the tunnel token are entered at bootstrap time, the database passwords are
generated, and all of them are stored only in `.env` (mode 600, git-ignored) and,
for the database's `dev` user, in `config/`. Claude Code is logged in interactively and `gh` with a
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
tunnel token into `bootstrap.sh`), the Cloudflare hostnames and Access entries for
the dev app ports (`bootstrap.sh` prints the list; see "Developing in the browser"),
the GitHub fine-grained token and the Claude login (plan Phase 4).

## Quick start (container stack only; inside the VM, as a normal user with sudo)

```bash
git clone https://github.com/MartinsCodingProjects/code-server-bootstrap.git ~/dev-server
cd ~/dev-server
./bootstrap.sh
```

`bootstrap.sh` installs Docker Engine if missing and asks, with an explanation
before every question, for a code-server password (min. 12 chars), an optional
Cloudflare Tunnel token, an optional domain and ports for the dev app hostnames,
and whether to run MariaDB. It writes `.env`, then builds and starts the stack. Without a token only `127.0.0.1:8443` is
served; reach it from your notebook with `ssh -L 8443:127.0.0.1:8443 devvm`.

| Command | Purpose |
|---|---|
| `./bootstrap.sh` | First run or re-run; keeps an existing `.env` |
| `./bootstrap.sh --reconfigure` | Ask everything again (password, token, dev hostnames, database); existing database passwords are kept |
| `./bootstrap.sh --update` | `git pull`, re-run the pulled script, refresh host-derived values and pinned versions in `.env`, rebuild, restart |
| `./bootstrap.sh --check` | Read-only health check of the running stack (non-zero exit on failure) |
| `./bootstrap.sh --mariadb` | Enable or disable the dev database (generates passwords, writes the credentials file) |
| `./bootstrap.sh --dev-hosts` | Change the domain and ports for the dev app hostnames, restart code-server, print the Cloudflare checklist |
| `DEV_PASSWORD=... TUNNEL_TOKEN=... DEV_DOMAIN=example.com DEV_PORTS='5173 8000' DEV_DB=yes ./bootstrap.sh` | Non-interactive (only the password is required) |

## Developing in the browser (Flask, FastAPI, Vite, React, ...)

The container has Node.js 22 with npm, Python 3.12 with `venv`, `pip` and `uv`, git,
`gh`, tmux, the Docker CLI and Claude Code. Keep projects under `projects/`.

**The goal: a repo behaves the same on your laptop and in code-server.** Clone it,
start the dev server with its normal command (`npm run dev`, `uvicorn app:app`,
`flask run`), open it in the browser. No config file, `base` path or flag is changed
for code-server. This works because every port is served at the **root of its own
hostname**: `https://5173-dev.<domain>` shows what listens on port 5173 in the
container, exactly like `http://localhost:5173` would.

**Set up once:**

1. `./bootstrap.sh` asks for your domain and the ports (default `5173 8000 5000 3000
   4173 5174`), or run `./bootstrap.sh --dev-hosts` later to change them. It prints the
   list of hostnames.
2. In the Cloudflare dashboard, once per hostname (the entries live in your account and
   survive rebuilds): Tunnel, Public Hostname, Add: the hostname, type **HTTP**, URL
   **`code-server:8443`**. Then add the same **exact names** to your Access application.
   Do not use a wildcard Access rule if the domain also hosts other sites. If the domain
   already has a wildcard DNS record, explicit records override it for these names only.
3. `./bootstrap.sh --check` lists which hostnames are not set up yet (or not behind Access).

**Every day:** log in to the IDE once, start your servers, open `https://<port>-dev.<domain>`.
One login covers all of them (the cookie is scoped to the parent domain). Without it a
hostname answers 401. A dev server runs in the foreground, so each one needs its own
terminal (a second terminal tab, or a tmux window with `Ctrl+b c`); a command typed after
`uvicorn ...` only runs once uvicorn stops. For uvicorn use `--reload --reload-dir <backend>`
so the reloader does not watch `node_modules` and `.venv`. `ECONNREFUSED 0.0.0.0:<port>`
simply means nothing listens on that port yet.

What changes in the container to make that work (nothing in your projects):
`PROXY_DOMAIN` makes code-server proxy `<port>-dev.<domain>` to that port;
`NODE_OPTIONS=--dns-result-order=ipv4first` makes Vite listen on IPv4 (its default is
IPv6 only, which the proxy cannot reach: `ECONNREFUSED 0.0.0.0:5173`);
`__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` lets Vite accept those hostnames; and
`patches/code-server-cookie-domain.js` fixes a code-server 4.140 bug that kept the login
cookie on the IDE host. The build fails loudly if a new code-server version changes that
code: check whether the bug is fixed upstream, then delete the patch and its two
`Dockerfile` lines. The settings live in `.env` as `PROXY_DOMAIN` (the pattern),
`DEV_PORTS` and `DEV_ALLOWED_HOSTS`; `./bootstrap.sh --dev-hosts` edits them for you.

Limits:

- The browser code of a frontend must reach its API with a relative URL (Vite's `proxy`
  for `/api` is the usual way). A hard-coded `http://localhost:8000` in browser code points
  at the *viewer's* machine and cannot work from any remote browser. A backend can also be
  opened directly at `https://8000-dev.<domain>`.
- Verified end to end in the container (Vite and FastAPI at their hostnames, login cookie,
  401 without it, hot-reload websocket upgrade), with the feature turned off, and on the
  real setup with Cloudflare (a FastAPI plus Vite/React proof of concept, and `--check`).
  Not verified: clicking the link a dev server prints (code-server rewrites it to the
  hostname pattern, expected but unconfirmed).
- `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS` is an internal Vite variable (tested with Vite
  8.3). Other dev servers with a host check (webpack-dev-server, Create React App, Next)
  may need their own setting.
- Python: the system Python is 3.12 and `pip install` outside a virtualenv is refused
  (by design). Use `uv` (included): `uv init`, `uv add fastapi uvicorn alembic
  argon2-cffi`, `uv run uvicorn app:app`. Other versions, e.g. 3.13, are downloaded on
  first use (`uv python install 3.13`, or `uv init --python 3.13`, or a `.python-version`
  file) and kept in `./config` (`HOME` is `/config`), so they survive container
  recreation. No pyenv: it compiles Python from source and would need a compiler and many
  `-dev` libraries. Tested with Python 3.13, FastAPI, Alembic and argon2-cffi.
- Without the hostnames (feature off), code-server's own path proxy `https://<ide-host>/proxy/<port>/`
  still works for apps that listen on IPv4, such as Flask.
- Docker-based projects: `docker compose` works through the mounted socket. Bind mounts
  resolve on the VM, so keep them under `projects/` (same path inside and out).

## Dev database (MariaDB, optional)

`./bootstrap.sh` asks whether to run MariaDB (answer later with `./bootstrap.sh --mariadb`).
It is a separate container on its **own internal network** shared only with code-server:
no published port, no route to the internet, unreachable from your LAN, the VM's other
networks and `cloudflared`. Inside code-server it appears as **`127.0.0.1:3306`** (a
supervised `socat` forwarder), so a project connects exactly as it would on a laptop.

- A `dev` user may create and use databases named `dev_<project>` (and the default `dev`),
  nothing else. Passwords are generated; the `dev` password is in
  `/config/mariadb-credentials.txt` inside code-server, the root password only in
  `~/dev-server/.env` on the VM. Admin shell: `docker exec -it mariadb mariadb -uroot -p`.
- Connect with `127.0.0.1`, not `localhost`: MySQL/MariaDB clients treat `localhost` as a
  unix socket. Example: `mysql+pymysql://dev:<password>@127.0.0.1:3306/dev_myapp`. Use a
  pure-Python driver (PyMySQL, asyncmy, aiomysql); `mysqlclient` needs a compiler and
  `-dev` libraries, which the image does not have.
- Data lives in the Docker volume `dev-server_mariadb-data`. It survives restarts,
  recreation, image updates and disabling the database; `docker compose down -v` deletes
  it. There are no backups (see the plan); dump what matters:
  `docker exec mariadb mariadb-dump -uroot -p --all-databases > dump.sql`.
- `.env` keys: `DB_FORWARD` (`mariadb:3306` means enabled and starts the forwarder in
  code-server; empty means off), `MARIADB_ROOT_PASSWORD` and `MARIADB_DEV_PASSWORD`
  (generated once; they only apply when the data directory is created), and
  `COMPOSE_PROFILES` (`db` and/or `tunnel`, kept in sync by `bootstrap.sh`).
- The version is pinned (`MARIADB_VERSION`, an LTS line); a new major version is a
  deliberate bump, see "Updating". It uses roughly 150 MB of RAM.
- Tested in the built image: use from code-server, the `dev_*` privilege limit, no access
  from other containers, no route out, persistence across recreating either container,
  and the forwarder returning by itself after code-server is recreated.

## Layout

| Path | Purpose |
|---|---|
| `setup/` | Scripts for a fresh install: notebook, host and VM creation, isolation check |
| `Dockerfile` | code-server + Node.js, Python (venv, pip), Claude Code, `gh`, tmux, Docker CLI/Compose |
| `docker-compose.yml` | `code-server`, `cloudflared` (profile `tunnel`) and `mariadb` (profile `db`) |
| `patches/` | Build-time workaround for a code-server cookie bug (fails the build if code-server changed) |
| `docker/svc-db-forward/` | Supervised service that forwards `127.0.0.1:3306` in code-server to MariaDB |
| `mariadb/initdb.d/` | First-start SQL for the database (the `dev_*` privileges) |
| `.env.example` | Documents the variables `bootstrap.sh` writes (also the pinned versions) |
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
     `docker-compose.yml`, and `.env.example`. The build may fail on purpose if the
     cookie patch no longer matches the new code-server (see "Developing in the
     browser"): check whether upstream fixed it, then drop the patch.
   - `CLOUDFLARED_VERSION`: the default in `docker-compose.yml` and `.env.example`.
   - `MARIADB_VERSION` (optional): `.env.example` and the default in `docker-compose.yml`;
     stay on an LTS line and read MariaDB's upgrade notes before a major jump.
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
