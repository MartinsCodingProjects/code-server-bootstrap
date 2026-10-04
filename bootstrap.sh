#!/usr/bin/env bash
# Bootstraps the dev environment inside the Debian VM: installs Docker if
# missing, writes .env (asking for the code-server password and an optional
# Cloudflare Tunnel token), then builds and starts the stack.
#
#   ./bootstrap.sh                # first run / re-run (keeps existing .env)
#   ./bootstrap.sh --reconfigure  # ask for password/token again
#   ./bootstrap.sh --update       # git pull, rebuild, restart
#   ./bootstrap.sh --check        # verify the running stack (read-only)
#
# Non-interactive: DEV_PASSWORD=... TUNNEL_TOKEN=... ./bootstrap.sh
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
REPO_DIR=$PWD
MODE=${1:-}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user (needs sudo), not as root"
case "$MODE" in ""|--reconfigure|--update|--check) ;; *) die "unknown option: $MODE" ;; esac

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

set_env() { # key value: replace the line in .env or append it
  local key=$1 val=$2
  val=${val//\\/\\\\}; val=${val//&/\\&}; val=${val//|/\\|}
  if grep -q "^$key=" .env; then sed -i "s|^$key=.*|$key=$val|" .env; else echo "$key=$2" >> .env; fi
}

# .env is kept across runs, so repo bumps of the pinned image versions must be
# copied into it, or Compose keeps using the old values from .env.
sync_versions() {
  local line
  while IFS= read -r line; do
    set_env "${line%%=*}" "${line#*=}"
  done < <(grep -E '^(CODE_SERVER|CLOUDFLARED)_VERSION=' .env.example)
}

# Values derived from this host and clone can go stale after a restore or move
# (different docker GID or clone path); recompute them, keep password/token/TZ.
sync_env() {
  local gid
  gid=$(getent group docker | cut -d: -f3)
  set_env PUID "$(id -u)"
  set_env PGID "$(id -g)"
  [ -z "$gid" ] || set_env DOCKER_GID "$gid"
  set_env PROJECTS_DIR "$REPO_DIR/projects"
  sync_versions
}

run_checks() { # read-only verification of the running stack
  local fails=0 warns=0 state running n use
  pass() { echo "  ok    $*"; }
  warn() { echo "  WARN  $*"; warns=$((warns + 1)); }
  fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
  if docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi

  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] \
    && pass "clock synchronized" || fail "clock not synchronized (breaks the tunnel)"
  systemctl is-active --quiet docker && pass "docker running" || fail "docker not running"
  [ "$(stat -c %a .env 2>/dev/null)" = 600 ] && pass ".env mode 600" || warn ".env missing or not mode 600"
  [ "$(stat -c %a config 2>/dev/null)" = 700 ] && pass "config/ mode 700" || warn "config/ is not mode 700"
  "${DOCKER[@]}" compose config -q 2>/dev/null && pass "compose config valid" || fail "compose config invalid"
  state=$("${DOCKER[@]}" inspect -f '{{.State.Health.Status}}' code-server 2>/dev/null || true)
  [ "$state" = healthy ] && pass "code-server healthy" || fail "code-server health: ${state:-not found}"
  if grep -q '^TUNNEL_TOKEN=.' .env 2>/dev/null; then
    running=$("${DOCKER[@]}" inspect -f '{{.State.Running}}' cloudflared 2>/dev/null || true)
    n=$("${DOCKER[@]}" compose logs --tail=1000 cloudflared 2>/dev/null | grep -c 'Registered tunnel connection' || true)
    [ "$running" = true ] && [ "${n:-0}" -gt 0 ] \
      && pass "cloudflared up ($n tunnel connections in the recent log)" || fail "cloudflared not running or no tunnel connection"
  else
    pass "no tunnel token configured (local-only)"
  fi
  "${DOCKER[@]}" exec -u abc code-server curl -fsS -m 8 -o /dev/null https://github.com >/dev/null 2>&1 \
    && pass "container DNS and internet" || fail "container cannot reach github.com (DNS or egress)"
  "${DOCKER[@]}" exec -u abc code-server sh -c 'claude --version && gh --version && tmux -V && docker ps' >/dev/null 2>&1 \
    && pass "claude, gh, tmux and the docker socket work in the container" || fail "tools or docker socket not working in the container"
  use=$(df -P . | awk 'NR==2 {gsub("%", "", $5); print $5}')
  [ "$use" -lt 90 ] && pass "disk usage ${use}%" || warn "disk usage ${use}%"
  [ -f /var/run/reboot-required ] && warn "reboot required (kernel update)" || pass "no reboot pending"
  echo "$fails failed, $warns warnings"
  [ "$fails" -eq 0 ]
}

if [ "$MODE" = "--check" ]; then
  run_checks
  exit $?
fi

# Pull first, then continue in the freshly pulled copy: otherwise this run would
# keep executing the old script logic.
if [ "$MODE" = "--update" ] && [ -z "${BOOTSTRAP_PULLED:-}" ]; then
  info "Pulling latest repo changes"
  git pull --ff-only
  BOOTSTRAP_PULLED=1 exec "$REPO_DIR/bootstrap.sh" --update
fi

install_docker
setup_docker_access

mkdir -p config projects
chmod 700 config

if [ ! -f .env ] || [ "$MODE" = "--reconfigure" ]; then
  write_env
else
  info "Keeping existing .env (use --reconfigure to change password/token)"
  sync_env
  info "Refreshed host-derived values and pinned versions in .env"
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
