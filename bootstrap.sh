#!/usr/bin/env bash
# Bootstraps the dev environment inside the Debian VM: installs Docker if
# missing, writes .env (asking for the code-server password and an optional
# Cloudflare Tunnel token), then builds and starts the stack.
#
#   ./bootstrap.sh                # first run / re-run (keeps existing .env)
#   ./bootstrap.sh --reconfigure  # ask for password/token again
#   ./bootstrap.sh --update       # git pull, rebuild, restart
#
# Non-interactive: DEV_PASSWORD=... TUNNEL_TOKEN=... ./bootstrap.sh
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
REPO_DIR=$PWD
MODE=${1:-}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user (needs sudo), not as root"
case "$MODE" in ""|--reconfigure|--update) ;; *) die "unknown option: $MODE" ;; esac

install_docker() {
  command -v docker >/dev/null 2>&1 && return
  . /etc/os-release
  [ "${ID:-}" = "debian" ] || die "automatic Docker install supports Debian only; install Docker Engine + Compose plugin manually"
  info "Installing Docker Engine"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<DOCKERSRC
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
DOCKERSRC
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker containerd
}

setup_docker_access() {
  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$USER"
    info "Added $USER to the docker group (takes effect on next login)"
  fi
  # Group membership is not active in this shell yet; fall back to sudo.
  if docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi
}

read_secret() { # prompt -> REPLY
  local p=$1
  [ -t 0 ] || die "no terminal for prompt '$p'; provide DEV_PASSWORD / TUNNEL_TOKEN via environment"
  read -rsp "$p" REPLY; echo
}

ask_password() {
  if [ -n "${DEV_PASSWORD:-}" ]; then PASSWORD_VALUE=$DEV_PASSWORD
  else
    local a b
    while :; do
      read_secret "code-server password (min 12 chars): "; a=$REPLY
      read_secret "repeat password: "; b=$REPLY
      [ "$a" = "$b" ] || { echo "Passwords differ."; continue; }
      PASSWORD_VALUE=$a; break
    done
  fi
  [ "${#PASSWORD_VALUE}" -ge 12 ] || die "password must be at least 12 characters"
  case "$PASSWORD_VALUE" in *\'*|*$'\n'*) die "password must not contain ' or newlines" ;; esac
}

ask_token() {
  if [ -n "${TUNNEL_TOKEN:-}" ]; then TOKEN_VALUE=$TUNNEL_TOKEN
  elif [ -t 0 ]; then
    read_secret "Cloudflare Tunnel token (Enter to skip, local-only for now): "; TOKEN_VALUE=$REPLY
  else TOKEN_VALUE=""; fi
  case "$TOKEN_VALUE" in
    *[!A-Za-z0-9=_+/.-]*) die "tunnel token contains unexpected characters" ;;
  esac
}

write_env() {
  ask_password
  ask_token
  local tz=${TZ:-}
  [ -n "$tz" ] || tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo Europe/Berlin)
  umask 077
  {
    echo "PUID=$(id -u)"
    echo "PGID=$(id -g)"
    echo "DOCKER_GID=$(getent group docker | cut -d: -f3)"
    echo "TZ=$tz"
    echo "PROJECTS_DIR=$REPO_DIR/projects"
    echo "PASSWORD='$PASSWORD_VALUE'"
    if [ -n "$TOKEN_VALUE" ]; then
      echo "COMPOSE_PROFILES=tunnel"
      echo "TUNNEL_TOKEN=$TOKEN_VALUE"
    else
      echo "COMPOSE_PROFILES="
      echo "TUNNEL_TOKEN="
    fi
    grep -E '^(CODE_SERVER|CLOUDFLARED)_VERSION=' .env.example
  } > .env.new
  mv .env.new .env
  chmod 600 .env
  info "Wrote .env (mode 600)"
}

# .env is kept across runs, so repo bumps of the pinned image versions must be
# copied into it, or Compose keeps using the old values from .env.
sync_versions() {
  local line key
  while IFS= read -r line; do
    key=${line%%=*}
    if grep -q "^$key=" .env; then sed -i "s|^$key=.*|$line|" .env; else echo "$line" >> .env; fi
  done < <(grep -E '^(CODE_SERVER|CLOUDFLARED)_VERSION=' .env.example)
}

install_docker
setup_docker_access

if [ "$MODE" = "--update" ]; then
  info "Pulling latest repo changes"
  git pull --ff-only
fi

mkdir -p config projects

if [ ! -f .env ] || [ "$MODE" = "--reconfigure" ]; then
  write_env
else
  info "Keeping existing .env (use --reconfigure to change password/token)"
  if [ "$MODE" = "--update" ]; then
    sync_versions
    info "Synced pinned image versions from .env.example"
  fi
fi

info "Building and starting"
"${DOCKER[@]}" compose up -d --build --remove-orphans
"${DOCKER[@]}" compose ps

if grep -q '^TUNNEL_TOKEN=.' .env; then
  echo "Tunnel enabled. Check: ${DOCKER[*]} compose logs --tail=30 cloudflared"
else
  echo "No tunnel token set: code-server is reachable only on 127.0.0.1:8443 in this VM."
  echo "From your notebook:  ssh -L 8443:127.0.0.1:8443 devvm   then open http://localhost:8443"
fi
