#!/usr/bin/env bash
# Run this on the PHYSICAL HOST (fresh Debian 13, as your normal user with sudo),
# after setup/notebook-setup.sh copied your SSH key to it. It hardens SSH, sets up
# automatic updates and the firewall, installs KVM/libvirt and creates the private
# VM network and storage pool. Safe to re-run: unchanged things are left alone.
#
#   setup/host-setup.sh [--dry-run] [--yes]
#     --dry-run  show what would happen, change nothing (no sudo needed)
#     --yes      accept the detected defaults without asking
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"

# ---------------------------------------------------------------- renderers
render_nft() {
  cat <<EOF
#!/usr/sbin/nft -f
table inet hostfw
delete table inet hostfw
table inet hostfw {
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
    ct state invalid drop
    udp sport 67 udp dport 68 accept
    ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
    ip6 nexthdr icmpv6 accept
    ip saddr ${LAN_SUBNET} tcp dport 22 accept
    # the guest may only use DHCP and DNS from the host's libvirt dnsmasq
    iifname "${BRIDGE}" udp dport { 53, 67 } accept
    iifname "${BRIDGE}" tcp dport 53 accept
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "${BRIDGE}" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 224.0.0.0/4 } drop
    iifname "${BRIDGE}" meta nfproto ipv6 drop
    oifname "${BRIDGE}" ct state new drop
  }
}
EOF
}

render_net_xml() {
  cat <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${BRIDGE}' stp='on' delay='0'/>
  <ip address='${GUEST_PREFIX}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${GUEST_PREFIX}.100' end='${GUEST_PREFIX}.200'/>
      <host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>
    </dhcp>
  </ip>
</network>
EOF
}

render_ssh_hardening() {
  cat <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers ${USER}
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
}

render_auto_upgrades() {
  cat <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

render_unattended_local() {
  cat <<EOF
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "${AUTO_REBOOT}";
Unattended-Upgrade::Automatic-Reboot-Time "${AUTO_REBOOT_TIME}";
EOF
}

render_libvirt_dropin() {
  cat <<'EOF'
[Unit]
After=nftables.service
Wants=nftables.service
EOF
}

# ---------------------------------------------------------------- detection
default_lan_subnet() {
  local dev
  dev=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [ -n "$dev" ] || return 0
  ip -4 route show dev "$dev" proto kernel scope link 2>/dev/null | awk '{print $1; exit}'
}

default_vm_ram() {
  local total v
  total=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  v=$(( (total - 2560) / 512 * 512 ))
  [ "$v" -ge 1024 ] || v=1024
  [ "$v" -le 8192 ] || v=8192
  echo "$v"
}

default_pool_dir() {
  local avail need=$1
  avail=$(df -BG --output=avail /var/lib 2>/dev/null | tail -n1 | tr -dc '0-9')
  if [ "${avail:-0}" -ge $(( need + 20 )) ]; then echo /var/lib/libvirt/images; else echo /home/libvirt/images; fi
}

# ---------------------------------------------------------------- steps
preflight() {
  step "Checking this machine"
  [ "$(id -u)" -ne 0 ] || die "run as your normal user (with sudo), not as root"
  . /etc/os-release
  [ "${ID:-}" = debian ] || die "this script supports Debian only (found: ${ID:-unknown})"
  [ "${VERSION_ID:-}" = 13 ] || warn "written for Debian 13, found ${VERSION_ID:-?}; continuing"
  ok "Debian ${VERSION_ID:-?}"
  grep -Eq '(vmx|svm)' /proc/cpuinfo \
    || die "no CPU virtualization (VT-x/AMD-V). Enable it in the BIOS/UEFI setup, then run again."
  ok "CPU virtualization available"
  local mem; mem=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  [ "$mem" -ge 4096 ] || warn "only ${mem} MB RAM; the VM would be very small"
  ok "RAM ${mem} MB"
  [ -n "$(default_lan_subnet)" ] || die "no default route: is the network cable plugged in?"
  if [ "$(hostname)" = debian ]; then
    warn "The hostname is the default 'debian', which is ambiguous. Consider renaming it (doc/cli-cheatsheet.md, section 8)."
  fi
}

ssh_guard() {
  step "Safety check before password login is turned off"
  explain "Next, SSH password login will be disabled: only your key will work. If your key
is not installed, you would be locked out (the host's own keyboard still works)."
  if [ ! -s "$HOME/.ssh/authorized_keys" ]; then
    [ "$DRY_RUN" = 1 ] && warn "no ~/.ssh/authorized_keys here (a real run would stop)" \
      || die "$HOME/.ssh/authorized_keys is empty. Run setup/notebook-setup.sh on your notebook first."
  fi
  if [ "$DRY_RUN" != 1 ] && sudo journalctl -u ssh --since "30 days ago" 2>/dev/null | grep -q "Accepted publickey for $USER "; then
    ok "a successful key login for $USER was found in the SSH log"
  elif [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] would look for a successful key login in the SSH log"
  else
    warn "no successful key login for $USER was found. Test it first: from the notebook, run 'ssh devhost'"
    warn "(it must ask for the key passphrase, not the host password), then run this script again."
    confirm_type "Disable password login anyway?" yes || die "stopped; nothing was changed for SSH"
  fi
}

step_packages() {
  step "Packages"
  explain "Installs: nftables (firewall), unattended-upgrades and needrestart (automatic security
updates), smartmontools (disk health), KVM/libvirt with virtinst and qemu (virtual machines),
genisoimage and curl (needed to build the VM from the Debian cloud image), git."
  run sudo apt-get update
  run sudo apt-get -y full-upgrade
  run sudo apt-get install -y nftables unattended-upgrades apt-listchanges needrestart smartmontools \
    qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst ovmf osinfo-db libosinfo-bin \
    genisoimage xorriso curl ca-certificates git
}

step_keyboard() {
  step "Console keyboard layout"
  explain "The Debian console defaults to a US layout. This sets '$KEYBOARD' for the keyboard attached
to this machine (SSH sessions use the notebook's layout and are not affected)."
  if [ -f /etc/default/keyboard ] && grep -q "^XKBLAYOUT=\"$KEYBOARD\"" /etc/default/keyboard; then
    ok "already $KEYBOARD"; return 0
  fi
  run sudo sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"$KEYBOARD\"/" /etc/default/keyboard
  if command -v setupcon >/dev/null 2>&1; then run sudo setupcon -k --save || warn "setupcon reported a problem (harmless warnings are normal)"; fi
}

step_updates() {
  step "Automatic security updates"
  explain "Debian security updates install daily by themselves. When an update needs a reboot
(for example a kernel), the host reboots at ${AUTO_REBOOT_TIME} if you chose true (the VM restarts
automatically afterwards). 'Remove unused dependencies' keeps the disk tidy."
  put_file /etc/apt/apt.conf.d/20auto-upgrades 644 < <(render_auto_upgrades)
  put_file /etc/apt/apt.conf.d/52unattended-upgrades-local 644 < <(render_unattended_local)
}

step_microcode() {
  step "CPU microcode"
  local vendor pkg
  vendor=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo)
  case "$vendor" in
    GenuineIntel) pkg=intel-microcode ;;
    AuthenticAMD) pkg=amd64-microcode ;;
    *) warn "unknown CPU vendor '$vendor'; skipping microcode"; return 0 ;;
  esac
  explain "Newer CPU microcode (security fixes for CPU flaws) is loaded at boot by the operating
system. This is more reliable than a BIOS update on old hardware. Needs a reboot to load."
  if [ "$DRY_RUN" != 1 ] && [ -z "$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -v '(none)')" ]; then
    warn "$pkg is not available: enable the 'non-free-firmware' component in /etc/apt/sources.list(.d/) and re-run."
    return 0
  fi
  run sudo apt-get install -y "$pkg"
}

step_ssh() {
  step "SSH hardening"
  explain "Key login only, no root login, only the user '$USER', three tries per connection.
Written to /etc/ssh/sshd_config.d/10-hardening.conf and applied after a syntax check."
  put_file /etc/ssh/sshd_config.d/10-hardening.conf 644 < <(render_ssh_hardening)
  if [ "$CHANGED" = 1 ]; then
    run sudo sshd -t
    run sudo systemctl reload ssh
    if [ "$DRY_RUN" != 1 ]; then ok "SSH reloaded; password login is now off"; fi
  fi
}

step_libvirt() {
  step "KVM/libvirt, VM network and storage pool"
  explain "The VM gets a private network '${NET_NAME}' (${GUEST_PREFIX}.0/24, NAT to the internet) and its
disk lives in '${POOL_NAME}' (${POOL_DIR}). Your user joins the 'libvirt' group (takes effect at the next login)."
  run sudo adduser "$USER" libvirt
  if q sudo virsh net-info "$NET_NAME"; then
    ok "network $NET_NAME already exists"
  else
    local xml; xml=$(mktemp); render_net_xml > "$xml"
    run sudo virsh net-define "$xml"
    rm -f "$xml"
    run sudo virsh net-start "$NET_NAME"
  fi
  run sudo virsh net-autostart "$NET_NAME"
  if q sudo virsh pool-info "$POOL_NAME"; then
    ok "pool $POOL_NAME already exists"
  else
    run sudo virsh pool-define-as "$POOL_NAME" dir --target "$POOL_DIR"
    run sudo virsh pool-build "$POOL_NAME"
    run sudo virsh pool-start "$POOL_NAME"
  fi
  run sudo virsh pool-autostart "$POOL_NAME"
}

step_firewall() {
  step "Firewall"
  explain "Default deny for everything inbound, except SSH from your LAN (${LAN_SUBNET}). The VM may
only use DHCP and DNS from this host; it cannot reach this host, your LAN or IPv6, only the
internet. IMPORTANT: a wrong LAN subnet would lock you out of SSH. So the rules are applied
with an automatic rollback: you must open a SECOND terminal on your notebook, run 'ssh devhost'
and confirm here within two minutes, otherwise the old rules come back by themselves."
  local tmp; tmp=$(mktemp); render_nft > "$tmp"
  if [ "$DRY_RUN" != 1 ] && [ -f /etc/nftables.conf ] && [ "$(cat /etc/nftables.conf)" = "$(cat "$tmp")" ]; then
    ok "firewall rules unchanged"; rm -f "$tmp"
    run sudo systemctl enable --now nftables
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] would check the rules with 'nft -c', apply them with a 120 s rollback timer,"
    info "[dry-run] ask for a confirmation from a second SSH session, then write /etc/nftables.conf"
    rm -f "$tmp"; return 0
  fi
  [ -t 0 ] || die "applying the firewall needs a terminal (you must confirm from a second SSH session)"
  sudo nft -c -f "$tmp" || die "the generated firewall rules do not parse; nothing was changed"
  [ -f /etc/nftables.conf ] && sudo cp -p /etc/nftables.conf /etc/nftables.conf.pre-devsetup
  sudo systemctl stop hostfw-rollback.timer 2>/dev/null || true
  sudo systemd-run --quiet --unit=hostfw-rollback --on-active=120 /bin/sh -c \
    'nft delete table inet hostfw 2>/dev/null; if [ -f /etc/nftables.conf.pre-devsetup ]; then cp /etc/nftables.conf.pre-devsetup /etc/nftables.conf; nft -f /etc/nftables.conf; fi'
  sudo nft -f "$tmp"
  info "Rules are active now. The rollback fires in 2 minutes unless you confirm."
  info "On your notebook, in a NEW terminal: ssh devhost   (it must still work)"
  if confirm "Did the new SSH login work?" n; then
    sudo systemctl stop hostfw-rollback.timer
    sudo install -m 644 "$tmp" /etc/nftables.conf
    rm -f "$tmp"
    sudo systemctl enable nftables
    ok "firewall confirmed and saved to /etc/nftables.conf"
  else
    rm -f "$tmp"
    warn "Not confirmed: the rollback restores the previous rules within 2 minutes."
    die "firewall not applied. Check LAN_SUBNET in $CONF_FILE and run this script again."
  fi
}

step_services() {
  step "Start order and autostart"
  explain "After a power cut the machine boots, loads the firewall first, then libvirt, then the VM (autostart).
'libvirt-guests' shuts the VM down cleanly before the host reboots or powers off."
  run sudo systemctl enable --now libvirtd libvirt-guests nftables
  run sudo sed -i 's/^#\?ON_BOOT=.*/ON_BOOT=start/; s/^#\?ON_SHUTDOWN=.*/ON_SHUTDOWN=shutdown/; s/^#\?SHUTDOWN_TIMEOUT=.*/SHUTDOWN_TIMEOUT=120/' /etc/default/libvirt-guests
  run sudo mkdir -p /etc/systemd/system/libvirtd.service.d
  put_file /etc/systemd/system/libvirtd.service.d/10-after-nftables.conf 644 < <(render_libvirt_dropin)
  run sudo systemctl daemon-reload
}

step_misc() {
  step "Root account and disk health"
  if [ "$LOCK_ROOT" = yes ]; then
    explain "Locks the root password: nobody can log in as root. Use 'sudo' (and 'sudo -i' for a root shell)."
    run sudo passwd -l root
  fi
  local d
  for d in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}'); do
    if [ "$DRY_RUN" = 1 ]; then info "[dry-run] smartctl -H /dev/$d"; continue; fi
    sudo smartctl -H "/dev/$d" 2>/dev/null | grep -i 'overall-health' | sed "s#^#    /dev/$d: #" || warn "no SMART data for /dev/$d"
  done
}

summary() {
  step "Done"
  [ ! -f /var/run/reboot-required ] || warn "A reboot is needed (kernel or microcode). Run: sudo reboot"
  explain "Host setup finished. Also set the BIOS/UEFI option 'Restore on AC power loss' to 'Power On'
so the machine starts again by itself after a power cut (this cannot be done from Linux).

Next, still on this host:
  ${SETUP_DIR}/create-vm.sh
(log out and in first, so the 'libvirt' group applies).

Day-to-day commands: doc/cli-cheatsheet.md"
}

# ---------------------------------------------------------------- main
main() {
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
      *) die "unknown option: $a" ;;
    esac
  done
  preflight
  step "Host setup"
  explain "This script sets up the physical host. It asks a few questions; the detected default is
shown in [brackets]; press Enter to accept it. Your answers are remembered in
$CONF_FILE so that a re-run does not ask the same things again."
  require_sudo
  load_conf

  ask LAN_SUBNET "Your LAN (network the notebook is in)" "$(default_lan_subnet)" \
"SSH to this host will be allowed ONLY from this network, and nothing else is reachable.
Your notebook must be inside it. Detected from the default route (a Fritzbox usually
uses 192.168.178.0/24)."
  ask GUEST_PREFIX "Private network prefix for the VM (first three numbers)" "192.168.150" \
"The VM lives on its own small network behind this host, invisible to your LAN. Pick a
range that does not overlap with your LAN."
  case "$LAN_SUBNET" in "$GUEST_PREFIX".*) die "the VM network overlaps with your LAN; choose another prefix" ;; esac
  ask VM_NAME "Name of the VM" "devvm" \
"The libvirt name and the hostname of the guest."
  ask VM_IP "Fixed address of the VM" "${GUEST_PREFIX}.10" \
"The VM always receives this address (a DHCP reservation by MAC address)."
  ask VM_MAC "MAC address of the VM" "52:54:00:aa:bb:10" \
"Ties the fixed address to the VM. Keep the default unless you run several VMs."
  ask VM_RAM_MB "VM memory in MB" "$(default_vm_ram)" \
"Fixed for the VM. The default leaves about 2.5 GB for the host. Docker builds, code-server
and Claude Code all share this memory."
  ask VM_VCPUS "VM CPU cores" "$(n=$(nproc); [ "$n" -gt 4 ] && echo 4 || echo "$n")" \
"Up to the number of cores of this host. All cores means a busy VM can slow the host down
(SSH, libvirt); fewer cores leave headroom."
  ask VM_DISK_GB "VM disk size in GB" "100" \
"Maximum size of the VM disk. It is a sparse file: it only uses what the VM stores."
  ask POOL_DIR "Folder for VM disks" "$(default_pool_dir "$VM_DISK_GB")" \
"Where the VM disk file lives. Debian's guided install often leaves '/' small and puts
the space in /home; the default picks the place with enough room."
  ask KEYBOARD "Console keyboard layout" "$(awk -F'"' '/^XKBLAYOUT=/ {print $2}' /etc/default/keyboard 2>/dev/null || echo us)" \
"Layout for the keyboard attached to this machine (de, us, fr, ...)."
  ask AUTO_REBOOT "Reboot automatically when an update needs it (true/false)" "true" \
"Kernel updates only take effect after a reboot. With true, the host reboots at the time
below, only when needed; the VM stops cleanly and starts again by itself. Running
processes in the VM (tmux sessions, builds) end at that moment."
  ask AUTO_REBOOT_TIME "Time for that reboot" "04:00" "Local time, HH:MM."
  ask LOCK_ROOT "Lock the root password (yes/no)" "yes" \
"Recommended: root can then no longer log in at all. You keep full control via sudo."
  save_conf LAN_SUBNET GUEST_PREFIX VM_NAME VM_IP VM_MAC VM_RAM_MB VM_VCPUS VM_DISK_GB POOL_DIR KEYBOARD AUTO_REBOOT AUTO_REBOOT_TIME LOCK_ROOT

  ssh_guard
  step_packages
  step_keyboard
  step_updates
  step_microcode
  step_ssh
  step_libvirt
  step_firewall
  step_services
  step_misc
  summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
