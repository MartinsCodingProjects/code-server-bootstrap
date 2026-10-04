# dev-server

Browser-based dev environment for a personal Debian VM: **code-server** (VS Code
in the browser) with Claude Code, GitHub CLI, tmux, Node.js and Docker CLI,
exposed through a **Cloudflare Tunnel** behind **Cloudflare Access** (GitHub
login) and code-server's own password. Setup of the host and VM is described
in [dev-server-plan.md](dev-server-plan.md); this repo is the part that runs
inside the VM.

This repository is public and contains no secrets. Passwords and the tunnel
token are entered at bootstrap time and stored only in `.env` (mode 600,
git-ignored). Claude Code and GitHub are logged in interactively from the
code-server terminal; credentials live in `./config`.

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
| `./bootstrap.sh --update` | `git pull`, rebuild, restart |
| `DEV_PASSWORD=... TUNNEL_TOKEN=... ./bootstrap.sh` | Non-interactive |

## Layout

| Path | Purpose |
|---|---|
| `Dockerfile` | code-server + Node.js, Claude Code, `gh`, tmux, Docker CLI/Compose |
| `docker-compose.yml` | `code-server` and `cloudflared` (profile `tunnel`) |
| `.env.example` | Documents the variables `bootstrap.sh` writes |
| `config/` | code-server user data and logins (git-ignored) |
| `projects/` | Your workspaces (git-ignored), mounted at the same absolute path inside the container |

## Notes

- The container mounts the VM's Docker socket so projects can build and run
  containers. That grants control of the VM's Docker daemon: the VM, not the
  container, is the security boundary.
- Image versions are pinned in the Dockerfile/Compose defaults and `.env.example`.
  Bump them in a commit, then run `./bootstrap.sh --update`.
- Tunnel origin must be `http://code-server:8443` (not `localhost`).
