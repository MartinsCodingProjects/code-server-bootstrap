#!/usr/bin/env bash
# Bootstraps the dev environment inside the Debian VM: installs Docker if
# missing, writes .env (asking for the code-server password and an optional
# Cloudflare Tunnel token), then builds and starts the stack.
#
#   ./bootstrap.sh                # first run / re-run (keeps existing .env)
#   ./bootstrap.sh --reconfigure  # ask for password/token again
#   ./bootstrap.sh --update       # git pull, rebuild, restart
#   ./bootstrap.sh --check        # verify the running stack (read-only)
#   ./bootstrap.sh --dev-hosts    # change the domain/ports for dev app hostnames
#   ./bootstrap.sh --mariadb      # enable or disable the dev database
#   ./bootstrap.sh --db-app NAME  # database user + database dev_NAME for one app
#   ./bootstrap.sh --db-app NAME --password # same, with a password you type (or DB_APP_PASSWORD=...)
#   ./bootstrap.sh --db-app NAME --database # same, with a database name you type (or DB_APP_DATABASE=...)
#   ./bootstrap.sh --db-app NAME --delete   # remove that user (the database is kept)
#   ./bootstrap.sh --db-app       # list the app users
#
# Non-interactive: DEV_PASSWORD=... TUNNEL_TOKEN=... ./bootstrap.sh
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
REPO_DIR=$PWD
MODE=${1:-}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user (needs sudo), not as root"
case "$MODE" in ""|--reconfigure|--update|--check|--dev-hosts|--mariadb|--db-app) ;; *) die "unknown option: $MODE" ;; esac

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


env_get() { # value of KEY in .env (empty if the file or key is missing; safe under pipefail)
  [ -f .env ] || return 0
  sed -n "s/^$1=//p" .env | tail -n1 | tr -d "'\""
}

DEFAULT_DEV_PORTS="5173 8000 5000 3000 4173 5174"

valid_dev_pattern() { # sets DEV_ERROR
  local p=$1
  if ! [[ "$p" =~ ^[a-z0-9-]*\{\{port\}\}[a-z0-9-]*\.([a-z0-9-]+\.)+[a-z]{2,}$ ]]; then
    DEV_ERROR="enter a domain like example.com (the names become <port>-dev.example.com)"
    return 1
  fi
}

# normalize_dev_domain INPUT: a bare domain becomes {{port}}-dev.<domain>; sets DEV_PATTERN
normalize_dev_domain() {
  local in=${1,,}
  case "$in" in
    *"{{port}}"*) DEV_PATTERN=$in ;;
    *) DEV_PATTERN="{{port}}-dev.$in" ;;
  esac
  valid_dev_pattern "$DEV_PATTERN"
}

valid_dev_ports() { # sets DEV_ERROR
  local p seen=" " n=0
  for p in $1; do
    [[ "$p" =~ ^[0-9]{4,5}$ ]] && [ "$p" -ge 1024 ] && [ "$p" -le 65535 ] \
      || { DEV_ERROR="'$p' is not a port between 1024 and 65535"; return 1; }
    [ "$p" != 8443 ] || { DEV_ERROR="8443 is code-server itself"; return 1; }
    case "$seen" in *" $p "*) DEV_ERROR="port $p is listed twice"; return 1 ;; esac
    seen="$seen$p "; n=$((n + 1))
  done
  [ "$n" -ge 1 ] || { DEV_ERROR="list at least one port"; return 1; }
  [ "$n" -le 20 ] || { DEV_ERROR="at most 20 ports"; return 1; }
}

# ask_dev_hosts: sets DEV_PATTERN, DEV_PORTS_VALUE, DEV_ALLOWED_VALUE (all empty = feature off)
ask_dev_hosts() {
  local cur_pat cur_ports ans
  cur_pat=$(env_get PROXY_DOMAIN); cur_ports=$(env_get DEV_PORTS)
  DEV_PATTERN=""; DEV_PORTS_VALUE=""; DEV_ALLOWED_VALUE=""
  if [ -n "${DEV_DOMAIN:-}" ]; then
    normalize_dev_domain "$DEV_DOMAIN" || die "DEV_DOMAIN: $DEV_ERROR"
    DEV_PORTS_VALUE=${DEV_PORTS:-${cur_ports:-$DEFAULT_DEV_PORTS}}
    valid_dev_ports "$DEV_PORTS_VALUE" || die "DEV_PORTS: $DEV_ERROR"
  elif [ ! -t 0 ]; then
    DEV_PATTERN=$cur_pat; DEV_PORTS_VALUE=$cur_ports
  else
    echo
    explain "Dev apps in your browser (optional)
Apps you start in code-server (Vite, Flask, FastAPI, ...) can be opened at a hostname of their own,
for example https://5173-dev.example.com for port 5173. The app is served at the root, exactly like
on localhost, so NO project file needs a change and the same repo works on every device.
Enter the domain you already use for the IDE (e.g. example.com). The hostnames become
<port>-dev.<domain>. Each hostname needs one entry in the Cloudflare dashboard, once (it survives
rebuilds); this script prints the list afterwards. Press Enter to skip, type - to turn it off.
Add or change it later with: ./bootstrap.sh --dev-hosts"
    while :; do
      read -rp "  domain${cur_pat:+ [$cur_pat]}: " ans
      if [ -z "$ans" ]; then DEV_PATTERN=$cur_pat; break; fi
      if [ "$ans" = "-" ]; then DEV_PATTERN=""; break; fi
      normalize_dev_domain "$ans" && break
      echo "  Not accepted: $DEV_ERROR. Try again, press Enter to skip."
    done
    if [ -n "$DEV_PATTERN" ]; then
      echo
      explain "Which ports get a hostname? Space-separated. The default is Vite (5173), FastAPI (8000), Flask (5000),
Node/Next (3000), vite preview (4173) and 5174 (Vite moves there when 5173 is already taken).
Every port is one dashboard entry; ports you leave out cost nothing and can be added later."
      while :; do
        read -rp "  ports [${cur_ports:-$DEFAULT_DEV_PORTS}]: " ans
        DEV_PORTS_VALUE=${ans:-${cur_ports:-$DEFAULT_DEV_PORTS}}
        valid_dev_ports "$DEV_PORTS_VALUE" && break
        echo "  Not accepted: $DEV_ERROR. Try again."
      done
    fi
  fi
  if [ -n "$DEV_PATTERN" ]; then
    DEV_ALLOWED_VALUE=".${DEV_PATTERN#*.}"
  else
    DEV_PORTS_VALUE=""
  fi
}

print_dev_checklist() {
  local pat ports p
  pat=$(env_get PROXY_DOMAIN); ports=$(env_get DEV_PORTS)
  [ -n "$pat" ] || return 0
  echo
  explain "Dev app hostnames: add each of these in Cloudflare, once (Zero Trust > Networks > Tunnels >
your tunnel > Public Hostname > Add): type HTTP, URL code-server:8443.
$(for p in $ports; do echo "  ${pat//'{{port}}'/$p}"; done)
Then add the same names to your Access application (list the exact names; do not use a wildcard
that could also cover your other subdomains). Check what is still missing with: ./bootstrap.sh --check"
}

dev_host_status() { # "<http_code> <redirect_url>" -> ok | noaccess | missing
  case "$1" in
    30[1278]\ https://*.cloudflareaccess.com/*) echo ok ;;
    401\ *) echo noaccess ;;
    *) echo missing ;;
  esac
}


gen_secret() { head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-24; }

compute_profiles() { # compose profiles from .env: tunnel if a token is set, db if the database is on
  local p=""
  [ -z "$(env_get TUNNEL_TOKEN)" ] || p=tunnel
  [ -z "$(env_get DB_FORWARD)" ] || p="${p:+$p,}db"
  echo "$p"
}

# ask_database DEFAULT(y|n): sets DB_FORWARD_VALUE ("mariadb:3306" or ""), DB_ROOT_PW, DB_DEV_PW
ask_database() {
  local def=$1 ans
  DB_ROOT_PW=$(env_get MARIADB_ROOT_PASSWORD); DB_DEV_PW=$(env_get MARIADB_DEV_PASSWORD)
  if [ -n "${DEV_DB:-}" ]; then
    ans=$DEV_DB
  elif [ ! -t 0 ]; then
    [ -z "$(env_get DB_FORWARD)" ] && ans=no || ans=yes
  else
    echo
    explain "Dev database: MariaDB (optional)
A MariaDB database for your projects, in its own container on a private network that only
code-server can reach: no published port, no route to the internet, invisible to your LAN.
Inside code-server it appears as 127.0.0.1:3306, so connection settings are the same as on a
laptop. A 'dev' user may create databases named dev_<project>. The passwords are generated and
saved in .env and, for the 'dev' user, in config/mariadb-credentials.txt. It needs about 150 MB of RAM.
Enable or disable it later with: ./bootstrap.sh --mariadb"
    read -rp "  Run MariaDB? [$def]: " ans
    ans=${ans:-$def}
  fi
  case "${ans,,}" in
    y|yes)
      DB_FORWARD_VALUE="mariadb:3306"
      [ -n "$DB_ROOT_PW" ] || DB_ROOT_PW=$(gen_secret)
      [ -n "$DB_DEV_PW" ] || DB_DEV_PW=$(gen_secret)
      ;;
    *) DB_FORWARD_VALUE="" ;;
  esac
}

write_db_credentials() {
  local f=config/mariadb-credentials.txt
  ( umask 077
    cat > "$f" <<EOF
MariaDB for dev projects (reachable only from code-server: no published port, no internet route)

  host      127.0.0.1    use the IP, not "localhost": MySQL/MariaDB clients treat "localhost" as a unix socket
  port      3306
  user      dev
  password  $(env_get MARIADB_DEV_PASSWORD)
  databases dev, and any dev_<name>; create one per project:  CREATE DATABASE dev_myapp;

Example (SQLAlchemy + PyMySQL):  mysql+pymysql://dev:$(env_get MARIADB_DEV_PASSWORD)@127.0.0.1:3306/dev_myapp

Command line: just type  mariadb  (or mariadb dev_myapp); ~/.my.cnf logs you in as 'dev'.

One user per app: on the VM run  ./bootstrap.sh --db-app myapp  to get a user 'myapp' that can
use only the database dev_myapp; its settings land in /config/mariadb-apps/myapp.env.

Administration: the root password is MARIADB_ROOT_PASSWORD in ~/dev-server/.env on the VM; shell:
  docker exec -it mariadb mariadb -uroot -p
EOF
  )
}

# ~/.my.cnf in code-server (HOME is /config): the mariadb client connects as 'dev' over TCP
# without options. Only a file carrying the marker line is ever overwritten or removed.
MYCNF_MARKER="# Written by bootstrap.sh; delete this line to keep your own edits."
write_db_client_conf() {
  local f=config/.my.cnf
  if [ -f "$f" ] && ! grep -qxF "$MYCNF_MARKER" "$f"; then
    info "Keeping your own config/.my.cnf (no bootstrap marker)"
    return 0
  fi
  ( umask 077
    printf '%s\n[client]\nhost=127.0.0.1\nport=3306\nuser=dev\npassword=%s\n' \
      "$MYCNF_MARKER" "$(env_get MARIADB_DEV_PASSWORD)" > "$f"
  )
}

sync_db_credentials() {
  if [ -n "$(env_get DB_FORWARD)" ]; then
    write_db_credentials
    write_db_client_conf
  else
    rm -f config/mariadb-credentials.txt
    if grep -qxF "$MYCNF_MARKER" config/.my.cnf 2>/dev/null; then rm -f config/.my.cnf; fi
  fi
}

db_root() { # mariadb client as root inside the mariadb container; SQL on stdin, extra args passed on
  "${DOCKER[@]}" exec -i -e "MARIADB_PW=$(env_get MARIADB_ROOT_PASSWORD)" mariadb \
    sh -c 'exec mariadb -uroot -p"$MARIADB_PW" "$@"' sh "$@"
}

valid_app_name() { # sets APP_ERROR
  [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { APP_ERROR="use lowercase letters, digits, _ and -, starting with a letter (max 32)"; return 1; }
  case "$1" in root|dev|healthcheck|mysql|mariadb|pma) APP_ERROR="'$1' is reserved"; return 1 ;; esac
}

# The password goes into SQL, a .env file and a URL: keep out what would need quoting there.
valid_db_password() { # sets PW_ERROR
  [ "${#1}" -ge 8 ] || { PW_ERROR="at least 8 characters are required"; return 1; }
  case "$1" in *[[:space:]\'\"\`\\#\$]*) PW_ERROR="it must not contain spaces or any of  ' \" \` \\ # \$"; return 1 ;; esac
}

ask_db_password() { # -> DB_APP_PW (from DB_APP_PASSWORD or a hidden prompt)
  if [ -n "${DB_APP_PASSWORD:-}" ]; then
    valid_db_password "$DB_APP_PASSWORD" || die "DB_APP_PASSWORD: $PW_ERROR"
    DB_APP_PW=$DB_APP_PASSWORD; return
  fi
  local a b
  while :; do
    read_secret "  password for '$1': "; a=$REPLY
    valid_db_password "$a" || { echo "  Not accepted: $PW_ERROR. Try again."; continue; }
    read_secret "  repeat password: "; b=$REPLY
    [ "$a" = "$b" ] || { echo "  The two entries differ. Try again."; continue; }
    DB_APP_PW=$a; break
  done
}

urlencode() { # percent-encode everything but unreserved URL characters
  local s=$1 i c out=""
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in [A-Za-z0-9._~-]) out+=$c ;; *) printf -v c '%%%02X' "'$c"; out+=$c ;; esac
  done
  echo "$out"
}

valid_db_name() { # sets DBN_ERROR
  [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]] || { DBN_ERROR="use letters, digits and _ (max 64)"; return 1; }
  case "${1,,}" in mysql|information_schema|performance_schema|sys) DBN_ERROR="'$1' is a system database"; return 1 ;; esac
}

app_env_get() { # NAME KEY: value from config/mariadb-apps/NAME.env (empty if missing)
  [ -f "config/mariadb-apps/$1.env" ] || return 0
  sed -n "s/^$2=//p" "config/mariadb-apps/$1.env"
}

ask_db_name() { # NAME -> DB_APP_DB (from DB_APP_DATABASE or a prompt; default: current, else dev_NAME)
  if [ -n "${DB_APP_DATABASE:-}" ]; then
    valid_db_name "$DB_APP_DATABASE" || die "DB_APP_DATABASE: $DBN_ERROR"
    DB_APP_DB=$DB_APP_DATABASE; return
  fi
  [ -t 0 ] || die "no terminal for the database name; provide DB_APP_DATABASE"
  local def
  def=$(app_env_get "$1" DB_NAME); def=${def:-dev_${1//-/_}}
  while :; do
    read -rp "  database for '$1' [$def]: " DB_APP_DB
    DB_APP_DB=${DB_APP_DB:-$def}
    valid_db_name "$DB_APP_DB" && break
    echo "  Not accepted: $DBN_ERROR. Try again."
  done
}

# App users: user NAME may use only its own database, dev_NAME (- becomes _) unless chosen otherwise. The
# 'dev' user can use it too (dev_* already, any other name gets a grant). Password and database
# are the ones given, else the ones in config/mariadb-apps/NAME.env (so re-runs keep them),
# else a generated password and dev_NAME.
db_app_create() { # NAME [PW] [DB]
  local name=$1 f="config/mariadb-apps/$1.env" pw=${2:-} db=${3:-} old_db dev_grant=""
  old_db=$(app_env_get "$name" DB_NAME)
  [ -n "$pw" ] || pw=$(app_env_get "$name" DB_PASSWORD)
  [ -n "$pw" ] || pw=$(gen_secret)
  [ -n "$db" ] || db=${old_db:-dev_${name//-/_}}
  [[ "$db" == dev_* ]] || dev_grant="GRANT ALL PRIVILEGES ON \`$db\`.* TO 'dev'@'%';"
  db_root <<SQL
CREATE DATABASE IF NOT EXISTS \`$db\`;
CREATE USER IF NOT EXISTS '$name'@'%' IDENTIFIED BY '$pw';
ALTER USER '$name'@'%' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$name'@'%';
$dev_grant
SQL
  if [ -n "$old_db" ] && [ "$old_db" != "$db" ]; then
    db_root <<<"REVOKE ALL PRIVILEGES ON \`$old_db\`.* FROM '$name'@'%';" 2>/dev/null || true
    info "'$name' no longer has access to '$old_db' (that database is kept)"
  fi
  mkdir -p config/mariadb-apps
  chmod 700 config/mariadb-apps
  ( umask 077
    cat > "$f" <<EOF
# MariaDB for the app '$name' (written by ./bootstrap.sh --db-app $name; re-running keeps password and database)
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=$db
DB_USER=$name
DB_PASSWORD=$pw
DATABASE_URL=mysql+pymysql://$name:$(urlencode "$pw")@127.0.0.1:3306/$db
EOF
  )
  info "User '$name' can use database '$db' (and nothing else; 'dev' can use it too)"
  echo "Settings for the app: config/mariadb-apps/$name.env (inside code-server: /config/mariadb-apps/$name.env)"
  echo "Command line in code-server:  mariadb -u $name -p $db"
}

db_app_delete() {
  local name=$1 db
  db=$(app_env_get "$name" DB_NAME); db=${db:-dev_${name//-/_}}
  db_root <<<"DROP USER IF EXISTS '$name'@'%';"
  rm -f "config/mariadb-apps/$name.env"
  info "Removed user '$name'. The database $db is kept; drop it with:  mariadb -e 'DROP DATABASE $db'"
}

db_app_list() {
  echo "App users (user -> database):"
  db_root -N -B <<'SQL' | sed 's/^/  /'
SELECT CONCAT(User, ' -> ', Db) FROM mysql.db
WHERE User NOT IN ('', 'root', 'dev', 'healthcheck', 'mariadb.sys') ORDER BY User;
SQL
}

write_env() {
  explain "A few questions follow: the code-server password, the Cloudflare Tunnel token and
(optional) hostnames for dev apps. Everything is kept only in .env (mode 600) on this VM."
  ask_password
  ask_token
  ask_dev_hosts
  ask_database "$([ -f .env ] && [ -z "$(env_get DB_FORWARD)" ] && echo n || echo y)"
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
    local profiles=""
    [ -z "$TOKEN_VALUE" ] || profiles=tunnel
    [ -z "$DB_FORWARD_VALUE" ] || profiles="${profiles:+$profiles,}db"
    echo "COMPOSE_PROFILES=$profiles"
    echo "TUNNEL_TOKEN=$TOKEN_VALUE"
    echo "DB_FORWARD='$DB_FORWARD_VALUE'"
    [ -z "$DB_ROOT_PW" ] || echo "MARIADB_ROOT_PASSWORD=$DB_ROOT_PW"
    [ -z "$DB_DEV_PW" ] || echo "MARIADB_DEV_PASSWORD=$DB_DEV_PW"
    echo "PROXY_DOMAIN='$DEV_PATTERN'"
    echo "DEV_PORTS='$DEV_PORTS_VALUE'"
    echo "DEV_ALLOWED_HOSTS='$DEV_ALLOWED_VALUE'"
    grep -E '^(CODE_SERVER|CLOUDFLARED|MARIADB)_VERSION=' .env.example
  } > .env.new
  mv .env.new .env
  chmod 600 .env
  sync_db_credentials
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
  done < <(grep -E '^(CODE_SERVER|CLOUDFLARED|MARIADB)_VERSION=' .env.example)
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
  sync_db_credentials
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
  if [ -n "$(env_get DB_FORWARD)" ]; then
    state=$("${DOCKER[@]}" inspect -f '{{.State.Health.Status}}' mariadb 2>/dev/null || true)
    [ "$state" = healthy ] && pass "mariadb healthy" || fail "mariadb health: ${state:-not found}"
    "${DOCKER[@]}" exec code-server timeout 3 bash -c '</dev/tcp/127.0.0.1/3306' >/dev/null 2>&1 \
      && pass "database reachable from code-server at 127.0.0.1:3306" || fail "database not reachable from code-server at 127.0.0.1:3306"
    "${DOCKER[@]}" exec -u abc -e HOME=/config code-server mariadb -e 'SELECT 1' >/dev/null 2>&1 \
      && pass "mariadb client in code-server logs in as dev" || warn "mariadb client in code-server cannot log in (rebuild with ./bootstrap.sh; config/.my.cnf)"
  fi
  local dpat dports dp dh dans
  dpat=$(env_get PROXY_DOMAIN); dports=$(env_get DEV_PORTS)
  if [ -n "$dpat" ]; then
    for dp in $dports; do
      dh=${dpat//'{{port}}'/$dp}
      dans=$(curl -s -o /dev/null -m 8 -w '%{http_code} %{redirect_url}' "https://$dh" || true)
      case "$(dev_host_status "$dans")" in
        ok) pass "$dh is set up and behind Cloudflare Access" ;;
        noaccess) warn "$dh works but is NOT behind Access (code-server's cookie still protects it): add it to your Access application" ;;
        *) warn "$dh is not set up in Cloudflare yet (answer: ${dans:-none}): add a Public Hostname to code-server:8443" ;;
      esac
    done
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

if [ "$MODE" = "--mariadb" ]; then
  [ -f .env ] || die ".env not found: run ./bootstrap.sh first"
  setup_docker_access
  ask_database y
  set_env DB_FORWARD "'$DB_FORWARD_VALUE'"
  if [ -n "$DB_FORWARD_VALUE" ]; then
    set_env MARIADB_ROOT_PASSWORD "$DB_ROOT_PW"
    set_env MARIADB_DEV_PASSWORD "$DB_DEV_PW"
  fi
  set_env COMPOSE_PROFILES "$(compute_profiles)"
  sync_db_credentials
  if [ -n "$DB_FORWARD_VALUE" ]; then
    info "Starting MariaDB and restarting code-server"
    "${DOCKER[@]}" compose up -d
    echo "Credentials for your projects: config/mariadb-credentials.txt (inside code-server: /config/mariadb-credentials.txt)"
  else
    info "Stopping MariaDB (its data volume is kept; enable it again to get the data back)"
    "${DOCKER[@]}" compose --profile db stop mariadb || true
    "${DOCKER[@]}" compose --profile db rm -f mariadb || true
    "${DOCKER[@]}" compose up -d
  fi
  exit 0
fi

if [ "$MODE" = "--db-app" ]; then
  [ -f .env ] || die ".env not found: run ./bootstrap.sh first"
  [ -n "$(env_get DB_FORWARD)" ] || die "the dev database is off: enable it with ./bootstrap.sh --mariadb"
  setup_docker_access
  [ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' mariadb 2>/dev/null)" = true ] || die "the mariadb container is not running"
  APP_NAME="" DB_APP_PW="" DB_APP_DB="" app_delete="" ask_pw="" ask_db=""
  for arg in "${@:2}"; do
    case "$arg" in
      --password) ask_pw=1 ;;
      --database) ask_db=1 ;;
      --delete) app_delete=1 ;;
      -*) die "unknown option: $arg (--password, --database or --delete)" ;;
      *) [ -z "$APP_NAME" ] || die "one app name only"; APP_NAME=$arg ;;
    esac
  done
  if [ -z "$APP_NAME" ]; then db_app_list; exit 0; fi
  valid_app_name "$APP_NAME" || die "app name: $APP_ERROR"
  if [ -n "$app_delete" ]; then
    [ -z "$ask_pw$ask_db" ] || die "--delete cannot be combined with --password or --database"
    db_app_delete "$APP_NAME"; exit 0
  fi
  [ -z "$ask_db" ] || ask_db_name "$APP_NAME"
  [ -z "$ask_pw" ] || ask_db_password "$APP_NAME"
  db_app_create "$APP_NAME" "$DB_APP_PW" "$DB_APP_DB"
  exit 0
fi

if [ "$MODE" = "--dev-hosts" ]; then
  [ -f .env ] || die ".env not found: run ./bootstrap.sh first"
  setup_docker_access
  ask_dev_hosts
  set_env PROXY_DOMAIN "'$DEV_PATTERN'"
  set_env DEV_PORTS "'$DEV_PORTS_VALUE'"
  set_env DEV_ALLOWED_HOSTS "'$DEV_ALLOWED_VALUE'"
  info "Saved. Restarting code-server so the new hostnames take effect"
  "${DOCKER[@]}" compose up -d
  print_dev_checklist
  exit 0
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

print_dev_checklist

if grep -q '^TUNNEL_TOKEN=.' .env; then
  echo "Tunnel enabled. Check: ${DOCKER[*]} compose logs --tail=30 cloudflared"
else
  echo "No tunnel token set: code-server is reachable only on 127.0.0.1:8443 in this VM."
  echo "From your notebook:  ssh -L 8443:127.0.0.1:8443 devvm   then open http://localhost:8443"
fi
