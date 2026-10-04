#!/usr/bin/env bash
# Run this on your NOTEBOOK (the machine you SSH from), after installing Debian on
# the host. It creates a dedicated SSH key, adds the ssh aliases and installs the
# key on the host. Safe to re-run.
#
#   setup/notebook-setup.sh [--dry-run] [--yes]
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done
[ "$(id -u)" -ne 0 ] || die "run as your normal user, not as root"

MARK_BEGIN="# >>> dev-server (setup/notebook-setup.sh) >>>"
MARK_END="# <<< dev-server <<<"

step "Notebook setup: SSH key and aliases"
explain "This prepares your notebook to reach the host ('devhost') and the VM ('devvm').
It creates a key only for these machines, adds two aliases to ~/.ssh/config and
copies the public key to the host. Nothing is changed on the host except
~/.ssh/authorized_keys. You can run it again at any time."

load_conf
ask HOST_ADDR "Host name or IP address of the physical host" "devhost.fritz.box" \
"The machine you installed Debian on. A Fritzbox resolves '<hostname>.fritz.box'
for any device that told it its hostname (devhost.fritz.box if you named it
devhost). The name keeps working when the IP changes. Without a name, use the IP
(on the host: ip -br a). Test: getent hosts <name>"
ask ADMIN_USER "Your user name on the host and the VM" "$USER" \
"The account you created during the Debian install. The same name is used inside
the VM later."
ask KEY_FILE "SSH key file to use" "$HOME/.ssh/id_ed25519_devhost" \
"A dedicated key with a passphrase, used only for these machines. It is created if
it does not exist. Keep a copy somewhere safe: it is the way in. If it is lost, log
in at the host's own keyboard and add a new key to ~/.ssh/authorized_keys."
ask VM_IP "Fixed address of the VM on the private VM network" "192.168.150.10" \
"The VM is not on your LAN. It sits on a private network behind the host and is
reached only through the host (ProxyJump). Keep the default unless you changed the
VM network in setup/host-setup.sh."

save_conf HOST_ADDR ADMIN_USER KEY_FILE VM_IP

step "SSH key"
if [ -f "$KEY_FILE" ]; then
  ok "key exists: $KEY_FILE"
else
  explain "Creating the key. You will be asked for a passphrase: choose one. It protects the
key if the file is ever copied. Nothing is shown while you type it."
  run mkdir -p "$(dirname "$KEY_FILE")"
  run chmod 700 "$(dirname "$KEY_FILE")"
  run ssh-keygen -t ed25519 -a 100 -C "notebook->devhost" -f "$KEY_FILE"
fi

step "SSH aliases in ~/.ssh/config"
CFG=$HOME/.ssh/config
BLOCK=$(cat <<EOF
$MARK_BEGIN
Host devhost
  AddKeysToAgent yes
  HostName $HOST_ADDR
  User $ADMIN_USER
  IdentityFile $KEY_FILE
  IdentitiesOnly yes
  AddressFamily inet

Host devvm
  HostName $VM_IP
  User $ADMIN_USER
  IdentityFile $KEY_FILE
  IdentitiesOnly yes
  ProxyJump devhost
$MARK_END
EOF
)
explain "'ssh devhost' reaches the host, 'ssh devvm' reaches the VM through the host.
IPv4 only, because the host firewall allows SSH over IPv4 only. The passphrase is
asked once per session (the key is kept in the ssh-agent)."
if [ -f "$CFG" ] && grep -qxF "$MARK_BEGIN" "$CFG"; then
  info "replacing the block written by an earlier run"
  if [ "$DRY_RUN" != 1 ]; then
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "$CFG" > "$CFG.tmp"
    cat "$CFG.tmp" > "$CFG"; rm -f "$CFG.tmp"
  fi
fi
if [ -f "$CFG" ] && grep -Eq '^Host[[:space:]]+(devhost|devvm)([[:space:]]|$)' "$CFG"; then
  warn "~/.ssh/config already has a 'Host devhost' or 'Host devvm' entry outside this script's block."
  warn "Nothing added (ssh uses the first matching entry). Check it points to $HOST_ADDR and $KEY_FILE."
else
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] would append to $CFG:"; explain "$BLOCK"
  else
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    { if [ -s "$CFG" ] && [ -n "$(tail -n1 "$CFG")" ]; then echo; fi; printf '%s\n' "$BLOCK"; } >> "$CFG"
    chmod 600 "$CFG"
    ok "added the aliases devhost and devvm"
  fi
fi

step "Copy the public key to the host"
explain "ssh-copy-id logs in ONCE with your host password and installs the public key.
After that, logins use the key. (The password is the one you set for $ADMIN_USER during
the Debian install. Nothing is shown while you type it.)"
if confirm "Copy the key to $ADMIN_USER@$HOST_ADDR now?" y; then
  run ssh-copy-id -i "$KEY_FILE.pub" "$ADMIN_USER@$HOST_ADDR"
else
  info "skipped. Later: ssh-copy-id -i $KEY_FILE.pub $ADMIN_USER@$HOST_ADDR"
fi

step "Next"
explain "1. Test the key login (asks for the key passphrase, not the host password):
     ssh devhost
2. On the host, get this repository and run the host setup:
     sudo apt install -y git
     git clone $(git -C "$SETUP_DIR" remote get-url origin 2>/dev/null || echo '<repo-url>') ~/dev-server-repo
     ~/dev-server-repo/setup/host-setup.sh"
