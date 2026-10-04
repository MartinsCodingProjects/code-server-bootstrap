#!/usr/bin/env bash
# Run this on the PHYSICAL HOST after setup/host-setup.sh. It creates the VM from
# the official Debian 13 cloud image and configures it on first boot with cloud-init:
# your user (key login only), updates, git and a clone of this repository.
#
#   setup/create-vm.sh [--dry-run] [--yes]
#   setup/create-vm.sh --name devvm2 --ip 192.168.150.11 --mac 52:54:00:aa:bb:11   (a test VM)
#   setup/create-vm.sh --finish [--name N]   after the first boot: remove the seed disk
#   setup/create-vm.sh --remove --name N     delete a (test) VM and its disk
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

IMG_URL_BASE=https://cloud.debian.org/images/cloud/trixie/latest
IMG_NAME=debian-13-genericcloud-amd64.qcow2

# ---------------------------------------------------------------- renderers
render_meta_data() {
  cat <<EOF
instance-id: ${VM_NAME}-$(date +%Y%m%d%H%M%S)
local-hostname: ${VM_NAME}
EOF
}

render_user_data() { # needs VM_NAME VM_USER PASS_HASH VM_TZ REPO_URL KEYS (one per line)
  local k
  cat <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
timezone: ${VM_TZ}
disable_root: true
ssh_pwauth: false
users:
  - name: ${VM_USER}
    gecos: ${VM_USER}
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    passwd: '${PASS_HASH}'
    sudo: ALL=(ALL) ALL
    ssh_authorized_keys:
EOF
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    printf "      - '%s'\n" "${k//\'/\'\'}"
  done <<<"$KEYS"
  cat <<EOF
package_update: true
package_upgrade: true
packages:
  - sudo
  - git
  - curl
  - ca-certificates
  - unattended-upgrades
  - apt-listchanges
write_files:
  - path: /etc/ssh/sshd_config.d/10-hardening.conf
    permissions: '0644'
    content: |
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitRootLogin no
      AllowUsers ${VM_USER}
      MaxAuthTries 3
      X11Forwarding no
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    permissions: '0644'
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
runcmd:
  - [ sh, -c, "sshd -t && systemctl reload ssh" ]
  - [ runuser, -l, "${VM_USER}", -c, "git clone '${REPO_URL}' dev-server" ]
EOF
}

# ---------------------------------------------------------------- helpers
vm_exists() { q sudo virsh dominfo "$1"; }

need_conf() {
  local v
  for v in VM_NAME VM_IP VM_MAC VM_RAM_MB VM_VCPUS VM_DISK_GB POOL_DIR GUEST_PREFIX; do
    [ -n "${!v:-}" ] || die "setup.env has no $v: run setup/host-setup.sh first"
  done
}

fetch_image() {
  local cache=$HOME/.cache/dev-server base=$POOL_DIR/$IMG_NAME want have
  step "Debian cloud image"
  explain "Downloads the official Debian 13 'genericcloud' image (about 400 MB) from cloud.debian.org
and verifies its SHA-512 checksum, which is published next to it. It is kept in
${POOL_DIR} and reused for further VMs."
  if [ "$DRY_RUN" = 1 ]; then info "[dry-run] would download and verify $IMG_URL_BASE/$IMG_NAME"; return 0; fi
  want=$(curl -fsSL "$IMG_URL_BASE/SHA512SUMS" | awk -v f="$IMG_NAME" '$2 == f {print $1}')
  [ -n "$want" ] || die "could not read the checksum of $IMG_NAME from $IMG_URL_BASE/SHA512SUMS"
  if sudo test -f "$base" && [ "$(sudo sha512sum "$base" | cut -d' ' -f1)" = "$want" ]; then
    ok "image already downloaded and verified"; return 0
  fi
  mkdir -p "$cache"
  curl -fL --progress-bar -o "$cache/$IMG_NAME" "$IMG_URL_BASE/$IMG_NAME"
  have=$(sha512sum "$cache/$IMG_NAME" | cut -d' ' -f1)
  [ "$have" = "$want" ] || die "checksum mismatch for the downloaded image; not using it"
  sudo install -m 0644 "$cache/$IMG_NAME" "$base"
  rm -f "$cache/$IMG_NAME"
  ok "image downloaded and checksum verified"
}

add_dhcp_reservation() {
  if [ "$DRY_RUN" = 1 ]; then info "[dry-run] would make sure $NET_NAME reserves $VM_IP for $VM_MAC"; return 0; fi
  if sudo virsh net-dumpxml "$NET_NAME" | grep -qi "mac='$VM_MAC'"; then
    ok "address reservation for $VM_MAC exists"
  else
    sudo virsh net-update "$NET_NAME" add ip-dhcp-host \
      "<host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>" --live --config
    ok "reserved $VM_IP for $VM_MAC"
  fi
}

create() {
  need_conf
  [ "$DRY_RUN" = 1 ] || require_sudo
  q sudo virsh pool-info "$POOL_NAME" || [ "$DRY_RUN" = 1 ] || die "storage pool $POOL_NAME is missing: run setup/host-setup.sh first"
  if vm_exists "$VM_NAME"; then die "a VM named '$VM_NAME' already exists (use --name for another, or --remove)"; fi

  step "Create the VM '$VM_NAME'"
  explain "The VM is built from the Debian cloud image. On its first boot, cloud-init creates your
user, installs your SSH key, turns SSH into key-only, installs updates, git and unattended-upgrades,
and clones this repository into your home folder. Nothing is typed into an installer."
  ask VM_USER "Login name inside the VM" "$USER" \
"The account created in the VM. Use the same name as on the host and notebook so the
ssh aliases work."
  [[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid user name: $VM_USER"
  ask_secret VM_PASS "Password for $VM_USER inside the VM" \
"Needed for 'sudo' and for the emergency console on this host (virsh console). SSH never
accepts it (key only). Use something strong, at least 8 characters; nothing is shown
while you type. Only a hash of it is stored, in a temporary seed disk that
'create-vm.sh --finish' removes after the first boot."
  [ "${#VM_PASS}" -ge 8 ] || die "password too short (minimum 8 characters)"
  PASS_HASH=$(printf '%s' "$VM_PASS" | openssl passwd -6 -stdin)
  unset VM_PASS

  KEYS=$(grep -Ev '^[[:space:]]*(#|$)' "$HOME/.ssh/authorized_keys" 2>/dev/null || true)
  [ -n "$KEYS" ] || die "$HOME/.ssh/authorized_keys has no keys: run setup/notebook-setup.sh first"
  echo; explain "SSH keys that will be allowed to log in to the VM (the same ones that work on this host):"
  while IFS= read -r k; do
    [ -n "$k" ] && printf '    %s\n' "$(ssh-keygen -lf /dev/stdin <<<"$k" 2>/dev/null || echo "(unreadable key)")"
  done <<<"$KEYS"
  confirm "Install these keys for $VM_USER in the VM?" y || die "stopped: no keys, no way into the VM"

  local def_repo; def_repo=$(git -C "$SETUP_DIR" remote get-url origin 2>/dev/null || true)
  ask REPO_URL "Repository to clone into the VM" "$def_repo" \
"The VM clones this public repository to ~/dev-server and you run ./bootstrap.sh there.
It must be an https:// address that needs no login."
  [[ "$REPO_URL" =~ ^https://[A-Za-z0-9._/@:-]+$ ]] || die "REPO_URL must be a plain https:// address"
  ask VM_TZ "Time zone of the VM" "$(timedatectl show -p Timezone --value 2>/dev/null || echo Europe/Berlin)" \
"Used for logs and the code-server terminal."
  ask VM_RAM_MB "VM memory in MB" "$VM_RAM_MB" "From the host setup; change it here for this VM only."
  ask VM_VCPUS "VM CPU cores" "$VM_VCPUS" ""
  ask VM_DISK_GB "VM disk size in GB" "$VM_DISK_GB" ""

  fetch_image
  step "Disk, seed disk and network reservation"
  local disk=$POOL_DIR/$VM_NAME.qcow2 seed=$POOL_DIR/$VM_NAME-seed.iso tmp
  explain "The VM disk is a copy of the image, grown to ${VM_DISK_GB} GB (it fills up on first boot).
The 'seed' disk carries the cloud-init settings and is removed again by --finish."
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] would create $disk (${VM_DISK_GB}G) and $seed"
    info "[dry-run] cloud-init user-data that would be used (password hash hidden):"
    tmp=$(render_user_data | sed "s#passwd: '.*'#passwd: '<hash>'#"); explain "$tmp"
  else
    sudo test ! -e "$disk" || die "$disk already exists; remove it or pick another --name"
    sudo qemu-img convert -O qcow2 "$POOL_DIR/$IMG_NAME" "$disk"
    sudo qemu-img resize "$disk" "${VM_DISK_GB}G" >/dev/null
    sudo chmod 600 "$disk"
    tmp=$(mktemp -d); chmod 700 "$tmp"
    render_user_data > "$tmp/user-data"; render_meta_data > "$tmp/meta-data"
    local mk=genisoimage; command -v genisoimage >/dev/null || mk=mkisofs
    sudo "$mk" -quiet -output "$seed" -volid cidata -joliet -rock "$tmp/user-data" "$tmp/meta-data"
    sudo chmod 600 "$seed"
    rm -rf "$tmp"
    sudo virsh pool-refresh "$POOL_NAME" >/dev/null
    ok "disk and seed disk created"
  fi
  add_dhcp_reservation

  step "Start the VM"
  local os=debian13
  if [ "$DRY_RUN" != 1 ] && ! osinfo-query os short-id="$os" >/dev/null 2>&1; then os=debian12; fi
  run sudo virt-install --name "$VM_NAME" --memory "$VM_RAM_MB" --vcpus "$VM_VCPUS" --cpu host-passthrough \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --disk "path=$seed,device=cdrom,readonly=on" \
    --network "network=$NET_NAME,model=virtio,mac=$VM_MAC" \
    --osinfo "$os" --import --graphics none --console pty,target_type=serial --noautoconsole
  run sudo virsh autostart "$VM_NAME"

  step "Next"
  explain "The VM boots and configures itself (a few minutes: it installs updates). On your NOTEBOOK:

  ssh-keygen -R $VM_IP                          # forget an older VM's host key, if any
  ssh devvm 'cloud-init status --wait'          # waits until the setup is finished: 'status: done'
  ssh devvm
  cd ~/dev-server && ./bootstrap.sh             # asks for the code-server password and the tunnel token

Afterwards, on this host, remove the seed disk (it holds the password hash):
  ${SETUP_DIR}/create-vm.sh --finish --name $VM_NAME"
}

finish() {
  need_conf; require_sudo
  vm_exists "$VM_NAME" || die "no VM named '$VM_NAME'"
  local seed=$POOL_DIR/$VM_NAME-seed.iso tgt
  step "Remove the seed disk of '$VM_NAME'"
  explain "cloud-init only reads it on the first boot. Removing it also deletes the stored password
hash from this host. Do this after 'cloud-init status' reports 'done' in the VM."
  tgt=$(sudo virsh domblklist "$VM_NAME" --details | awk '$2 == "cdrom" {print $3; exit}')
  if [ -n "$tgt" ]; then sudo virsh change-media "$VM_NAME" "$tgt" --eject --live --config --force >/dev/null || warn "could not eject $tgt"; fi
  sudo rm -f "$seed"
  ok "seed disk removed"
}

remove() {
  need_conf; require_sudo
  vm_exists "$VM_NAME" || die "no VM named '$VM_NAME'"
  step "Remove the VM '$VM_NAME' and its disk"
  warn "This permanently deletes the VM and everything stored in it."
  confirm_type "Delete the VM '$VM_NAME'?" "$VM_NAME" || die "cancelled"
  sudo virsh destroy "$VM_NAME" 2>/dev/null || true
  sudo virsh undefine "$VM_NAME" >/dev/null
  sudo rm -f "$POOL_DIR/$VM_NAME.qcow2" "$POOL_DIR/$VM_NAME-seed.iso"
  sudo virsh net-update "$NET_NAME" delete ip-dhcp-host "<host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>" --live --config 2>/dev/null || true
  sudo virsh pool-refresh "$POOL_NAME" >/dev/null 2>&1 || true
  ok "removed"
}

main() {
  local mode=create a name_arg="" ip_arg="" mac_arg=""
  while [ $# -gt 0 ]; do
    a=$1; shift
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      --finish) mode=finish ;;
      --remove) mode=remove ;;
      --name) name_arg=${1:?--name needs a value}; shift ;;
      --ip) ip_arg=${1:?--ip needs a value}; shift ;;
      --mac) mac_arg=${1:?--mac needs a value}; shift ;;
      -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
      *) die "unknown option: $a" ;;
    esac
  done
  [ "$(id -u)" -ne 0 ] || die "run as your normal user (with sudo), not as root"
  load_conf
  local main_name=${VM_NAME:-}
  if [ -n "$name_arg" ] && [ "$name_arg" != "$main_name" ]; then
    [ "$mode" = finish ] || { [ -n "$ip_arg" ] && [ -n "$mac_arg" ] || die "a second VM needs --name, --ip and --mac (own address, own MAC)"; }
    VM_NAME=$name_arg
    [ -z "$ip_arg" ] || VM_IP=$ip_arg
    [ -z "$mac_arg" ] || VM_MAC=$mac_arg
  fi
  case "$mode" in
    create) create ;;
    finish) finish ;;
    remove) [ -n "$name_arg" ] || die "--remove needs --name"; remove ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
