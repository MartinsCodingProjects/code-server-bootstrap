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

## Quick start (inside the Debian VM, as a normal user with sudo)

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

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | code-server + Node.js, Claude Code, `gh`, tmux, Docker CLI/Compose |
| `docker-compose.yml` | `code-server` and `cloudflared` (profile `tunnel`) |
| `.env.example` | Documents the variables `bootstrap.sh` writes |
| `config/` | code-server user data and logins (git-ignored) |
| `projects/` | Your workspaces (git-ignored), mounted at the same absolute path inside the container |

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
   - `DOCKER_CLI_VERSION` (optional): the `ARG` in `Dockerfile`; the tag is
     `docker:<version>-cli`.
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
