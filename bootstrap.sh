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
  info "Installing Docker Engine (sudo may ask for your password)"
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

explain() { local l; while IFS= read -r l; do printf '    | %s\n' "$l"; done <<<"$*"; }

valid_password() { # sets PW_ERROR
  [ "${#1}" -ge 12 ] || { PW_ERROR="at least 12 characters are required"; return 1; }
  case "$1" in *\'*|*$'\n'*) PW_ERROR="it must not contain a ' (single quote) or a newline"; return 1 ;; esac
}

valid_token() { # an empty token is fine (skip); sets TOKEN_ERROR
  local t=$1
  [ -n "$t" ] || return 0
  case "$t" in
    *[[:space:]]*) TOKEN_ERROR="it contains spaces. Paste only the token (the part after '--token'), not the whole command"; return 1 ;;
    *[!A-Za-z0-9=_+/.-]*) TOKEN_ERROR="it contains unexpected characters. Paste only the token"; return 1 ;;
  esac
  if [[ "$t" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    TOKEN_ERROR="that looks like the tunnel ID (a UUID), not the token. The token is a much longer string starting with eyJ"
    return 1
  fi
  case "$t" in eyJ*) ;; *) TOKEN_ERROR="a tunnel token starts with 'eyJ'"; return 1 ;; esac
}

ask_password() {
  if [ -n "${DEV_PASSWORD:-}" ]; then
    PASSWORD_VALUE=$DEV_PASSWORD
    valid_password "$PASSWORD_VALUE" || die "DEV_PASSWORD: $PW_ERROR"
    return
  fi
  echo
  explain "code-server password
This is the second login gate: first Cloudflare Access asks who you are (GitHub login),
then code-server asks for this password. At least 12 characters, no single quote (').
Nothing is shown while you type. It is stored only in .env (mode 600) on this VM, never in git.
Change it later with: ./bootstrap.sh --reconfigure"
  local a b
  while :; do
    read_secret "  code-server password: "; a=$REPLY
    valid_password "$a" || { echo "  Not accepted: $PW_ERROR. Try again."; continue; }
    read_secret "  repeat password: "; b=$REPLY
    [ "$a" = "$b" ] || { echo "  The two entries differ. Try again."; continue; }
    PASSWORD_VALUE=$a; break
  done
}

ask_token() {
  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    TOKEN_VALUE=$TUNNEL_TOKEN
    valid_token "$TOKEN_VALUE" || die "TUNNEL_TOKEN: $TOKEN_ERROR"
    return
  fi
  if [ ! -t 0 ]; then TOKEN_VALUE=""; return; fi
  echo
  explain "Cloudflare Tunnel token
The tunnel makes this VM reachable from the internet without opening any port: the
'cloudflared' container connects OUT to Cloudflare, and your browser reaches code-server through it.
Where to find the token: Cloudflare dashboard > Zero Trust > Networks > Tunnels > your tunnel >
'Add a connector' > Docker. In the command shown there, copy ONLY the long string after
'--token' (it starts with 'eyJ'). The tunnel ID is NOT the token. The tunnel's public hostname
must point to service type HTTP, URL code-server:8443.
Paste it as one line; nothing is shown. Press Enter to skip: code-server then runs only on
127.0.0.1:8443 inside this VM (reach it with: ssh -L 8443:127.0.0.1:8443 devvm).
Add the token later with: ./bootstrap.sh --reconfigure"
  while :; do
    read_secret "  tunnel token (Enter to skip): "; TOKEN_VALUE=$REPLY
    valid_token "$TOKEN_VALUE" && break
    echo "  Not accepted: $TOKEN_ERROR. Try again, or press Enter to skip."
  done
}

write_env() {
  explain "Two questions follow: the code-server password and the Cloudflare Tunnel token.
Both are kept only in .env (mode 600) on this VM."
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
