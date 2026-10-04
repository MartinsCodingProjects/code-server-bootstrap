# Personal Remote Dev Server — Setup Plan

## Goal

Make remote development consistent from any device, with zero setup time per
session. Access a personal dev environment through a browser IDE and terminal,
with Claude Code and GitHub authentication performed inside the development
environment.

This is a personal prototype, not a multi-user service. The VM is the primary
isolation boundary; containers organize services and projects inside it.

## Architecture

```text
Notebook on LAN/WLAN
  └── SSH to Debian host for VM administration
        └── KVM/libvirt
              └── Debian guest VM (internet egress; no LAN access)
                    └── Docker + Compose
                          ├── code-server
                          │     ├── projects and persistent user config
                          │     ├── Claude Code and GitHub CLI/auth
                          │     ├── tmux
                          │     └── Docker CLI + VM Docker socket
                          └── cloudflared
                                └── outbound Cloudflare Tunnel

Browser → Cloudflare Access → Tunnel → cloudflared → code-server
```

The physical host runs Debian and KVM/libvirt, but does not need Docker. The VM
has its own virtual disk; do not share host directories into the guest. From
the notebook, SSH to the host and manage the guest there (for example, with
`virsh` and a VM console), rather than giving the VM a LAN-facing SSH route.

## Tech Stack

| Layer | Choice | Why |
|-------|--------|-----|
| Physical host | Debian 13 minimal | Headless virtualization host |
| Virtualization | KVM/libvirt | Persistent guest VM and a stronger boundary than containers alone |
| Guest OS | Debian 13 minimal | All development services and project workloads stay inside the VM |
| Container runtime | Docker Engine + Compose, inside the VM | Projects can build and run their own containers without access to a host Docker daemon |
| IDE + terminal | code-server (LinuxServer image) | Browser VS Code experience |
| AI agent | Claude Code, installed in the code-server image | Available in the integrated terminal |
| Session persistence | tmux | Keeps terminal processes alive across browser disconnects |
| Remote access | Cloudflare Tunnel (`cloudflared`) | Outbound connection; no inbound router port forwarding |
| Authentication | Cloudflare Access (GitHub login) plus code-server authentication | Defense in depth for the browser IDE |
| VM networking | libvirt NAT/private network with guest egress restrictions | Internet access without general access to the host or LAN |
| Hardware | Spare computer, wired Ethernet | — |

## Key Decisions

1. **Use a VM as the trust boundary.** The guest has a separate kernel from the
   physical host. Containers are not treated as a security boundary against
   code running inside the guest.
2. **Keep Docker inside the VM.** The code-server container gets the VM's Docker
   socket so project workflows can build and run containers. This gives
   code-server and its processes control of the guest's Docker daemon and
   containers, but not the physical host's daemon.
3. **No host directory shares.** The guest uses its virtual disk for projects,
   config, and container data. The host can administer the VM, but guest
   processes should not be able to browse host files.
4. **No guest LAN management route.** Administer the VM by SSHing to the host
   and using host-side VM management tools. The notebook reaches the guest only
   via an SSH jump through the host (`ProxyJump`), so the guest needs no
   LAN-facing exposure and the VM's network policy has no inbound exception.
5. **Use Cloudflare Tunnel, not an exposed inbound port.** Route the tunnel to
   the Compose service name (for example, `http://code-server:8443`), not
   `localhost` inside the `cloudflared` container.
6. **Keep both authentication layers.** Cloudflare Access is the outer gate;
   retain code-server's own authentication and do not publish its port publicly.
7. **Persist browser-session work with tmux.** tmux is for disconnect/reconnect
   continuity, not container or VM restart recovery.
8. **Authenticate from inside code-server.** Sign in to Claude Code
   interactively and to GitHub with a fine-grained token (no broad OAuth scopes)
   in the container; do not bake credentials into the image or put them in
   Compose environment variables. Persist the relevant user config with
   restrictive permissions.
9. **Git for source sync.** Use Git to move project changes between devices;
   no real-time collaboration is required.
10. **Everything must come back unattended after a hardware reboot or power
    loss.** Power on → host boots → VM autostarts → Docker starts → code-server
    and `cloudflared` start → the site is reachable again, with no keyboard,
    passphrase, or manual command. See Phase 5.
11. **Container setup is versioned in a public repo.** The Dockerfile, Compose
    file and `bootstrap.sh` live in this repository, which contains no secrets.
    The VM clones it and runs `./bootstrap.sh`, which installs Docker, asks for
    the code-server password and optional tunnel token, writes a git-ignored
    `.env` (mode 600), and starts the stack. Image versions are pinned in the
    repo and bumped by commit.

## Security and Network Boundaries

- The physical host is the virtualization/control plane. Protect its SSH access
  with key-based authentication, updates, and a firewall; do not expose its
  management services to the public internet.
- The guest VM gets internet egress for Claude, GitHub, package registries, and
  Cloudflare Tunnel. It should not be able to initiate connections to the
  physical host, other LAN/WLAN devices, or other private subnets.
- Enforce and test the guest's egress policy at the host/router boundary, not
  only with Docker bridge rules. Account for IPv4, IPv6, DNS, and host/gateway
  addresses. A dedicated VLAN with an internet-only policy is an alternative
  if supported by the router/switch.
- The tunnel container connects outbound to Cloudflare and reaches code-server
  over a private Compose network. The code-server container does not need a
  direct connection to the tunnel container; they need to share the network
  that carries the origin connection.
- code-server needs outbound internet for development tools. Project
  containers may also need internet access. Because code-server controls the
  VM Docker daemon, do not rely on Compose container networks alone to enforce
  the VM's LAN isolation.
- Cloudflare Tunnel only exposes the hostname/routes explicitly configured.
  Exposing project web apps later requires adding routes and Access policies;
  do not assume arbitrary project ports are automatically available.
- A VM reduces the impact of a guest/container compromise, but is not an
  absolute guarantee against hypervisor vulnerabilities, misconfiguration, or
  data the guest is intentionally allowed to access.

## Step-by-Step Build Plan

Conventions: `<admin>` is your Linux username (same on host and VM), `devhost`
is the physical host, `devvm` is the guest. The Fritzbox LAN is assumed to be
`192.168.178.0/24` (Fritzbox default) — adjust if yours differs. Lines marked
`notebook$` run on your notebook, `host$` on the physical host, `vm$` inside
the guest, and `ct$` in the code-server terminal.

### Phase 0: Fresh Debian host, SSH access, baseline hardening

**0.1 Install Debian 13 on the spare computer (on its console)**

- Wired Ethernet into the Fritzbox. Use the netinst ISO.
- Hostname `devhost`. Leave the **root password empty** (this locks root and
  installs `sudo` with your user in the `sudo` group). Create `<admin>` with a
  strong password (needed for `sudo`). If you set a root password anyway, `sudo`
  is not installed: run `su -`, `apt install -y sudo`, `usermod -aG sudo <admin>`,
  `exit` and log in again, **one line at a time** (pasted together, `su -`
  swallows the following lines as its password input).
- Partitioning: guided, whole disk, **no disk encryption** (an unattended boot
  must not wait for a passphrase).
- Software selection: untick desktop environment; tick only **SSH server** and
  **standard system utilities**.

**0.2 Fixed address (Fritzbox UI + console)**

```bash
host$ ip -br a                      # note the IPv4 address and interface name
host$ hostname -I
```

Fritzbox UI → Home Network → Network → Network Connections → `devhost` → edit →
"Always assign this network device the same IPv4 address". The Fritzbox also
resolves the name, so `devhost.fritz.box` works from the notebook.

If that option is not available, rely on the name: `devhost.fritz.box` follows
the IP. The DNS name comes from the hostname the machine announces via DHCP, not
from the label shown in the Fritzbox UI, and it changes at the next lease. To
rename the host later: `sudo hostnamectl set-hostname <new>`, fix the
`127.0.1.1` line in `/etc/hosts` (otherwise `sudo` complains "unable to resolve
host"), reboot, wait until `getent hosts <new>.fritz.box` resolves on the
notebook, then update `HostName` in the notebook's SSH config.

**0.3 SSH key login from the notebook (WLAN → Fritzbox → host)**

```bash
notebook$ ssh-keygen -t ed25519 -a 100 -C "notebook->devhost" -f ~/.ssh/id_ed25519_devhost   # set a passphrase
notebook$ ssh-copy-id -i ~/.ssh/id_ed25519_devhost.pub <admin>@devhost.fritz.box
notebook$ ssh -i ~/.ssh/id_ed25519_devhost <admin>@devhost.fritz.box   # confirm key login works
```

Convenience entry on the notebook (`~/.ssh/config`):

```
Host devhost
  AddKeysToAgent yes
  HostName devhost.fritz.box
  User <admin>
  IdentityFile ~/.ssh/id_ed25519_devhost
  IdentitiesOnly yes
  AddressFamily inet
```

Use a dedicated key with a passphrase for the servers (do not reuse an existing
passphrase-less key). `AddressFamily inet` forces IPv4, because the host
firewall allows SSH over IPv4 only; `AddKeysToAgent` asks for the passphrase
once per session. Run all `ssh` tests on the notebook: the aliases exist only
in the notebook's `~/.ssh/config`. If the key is lost, log in at the host's
console (password login still works there) and add a new public key to
`~/.ssh/authorized_keys`.

**0.4 Key-only SSH, no root login**

Keep the existing SSH session open until the new settings are tested.

```bash
host$ sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers <admin>
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
host$ sudo sshd -t && sudo systemctl reload ssh
host$ sudo sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|allowusers'
```

Test from a second terminal on the notebook:

```bash
notebook$ ssh devhost                                   # works (key)
notebook$ ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password devhost
# must fail with "Permission denied (publickey)"
```

**0.5 System updates and automatic security updates**

```bash
host$ sudo apt update && sudo apt full-upgrade -y
host$ sudo apt install -y unattended-upgrades apt-listchanges needrestart
host$ sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
host$ sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-local >/dev/null <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
host$ sudo unattended-upgrade --dry-run --debug | tail -n 20
host$ systemctl list-timers 'apt-daily*'
```

`Automatic-Reboot` reboots the host (and therefore the VM) at 04:00 only when an
update requires it. This is acceptable once Phase 5 makes recovery unattended;
set it to `"false"` if you prefer manual reboots.

**0.6 Host firewall (nftables, default-deny inbound, SSH from LAN only)**

Do not use `flush ruleset` in this file: libvirt (Phase 1) manages its own
nftables tables, and flushing the whole ruleset on reload would remove them.
The `delete table` idiom replaces only our own table.

```bash
host$ sudo apt install -y nftables
host$ sudo tee /etc/nftables.conf >/dev/null <<'EOF'
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
    ip saddr 192.168.178.0/24 tcp dport 22 accept
  }
}
EOF
host$ sudo nft -c -f /etc/nftables.conf          # syntax check only
host$ sudo nft -f /etc/nftables.conf
host$ sudo systemctl enable nftables
host$ sudo nft list table inet hostfw
```

Confirm from a *new* notebook terminal that `ssh devhost` still works before
closing the old session. IPv6 SSH is intentionally not allowed; use IPv4.

**0.7 Remaining baseline checks**

```bash
host$ sudo passwd -l root                        # no-op if root was left empty at install
host$ sudo ss -tulpn                             # expect only sshd (and DHCP client)
host$ timedatectl                                # "System clock synchronized: yes"
host$ sudo apt install -y smartmontools
host$ sudo smartctl -H /dev/sda                  # disk health (use your device name)
host$ sudo apt purge -y <anything-you-do-not-need> && sudo apt autoremove -y
```

CPU microcode and mitigations (old hardware):

```bash
host$ grep . /sys/devices/system/cpu/vulnerabilities/*
host$ sudo apt install -y intel-microcode       # amd64-microcode on AMD; reboot to load
host$ sudo dmesg | grep -i microcode             # "Updated early from: ..." shows it loaded
```

The OS loads newer microcode than an old BIOS carries, so a BIOS update is rarely
needed. Some old CPUs stay at `Vulnerable: No microcode` for a flaw because the
vendor never published a fix (an i5-6400 for GDS/"Downfall"); the rest should
show `Mitigation: ...`. With a single trusted guest this residual risk is accepted.

Console keyboard layout (the Debian console defaults to US):

```bash
host$ sudo sed -i 's/^XKBLAYOUT=.*/XKBLAYOUT="de"/' /etc/default/keyboard
host$ sudo setupcon -k --save
```

The login prompt on the host's console after boot is normal and does not block
services (sshd, libvirt, Docker start before it). Do not enable auto-login.

Laptop as server? Prevent suspend on lid close:

```bash
host$ sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
host$ sudo systemctl restart systemd-logind
```

Also: keep a copy of the notebook's SSH key somewhere safe, and keep physical
console access available for lockout recovery. `fail2ban` is not needed:
SSH is key-only and reachable from the LAN only.

### Phase 1: Virtualization host and guest VM

**1.1 Install KVM/libvirt on the host**

```bash
host$ grep -Ec '(vmx|svm)' /proc/cpuinfo         # >0 means CPU virtualization is available
host$ sudo apt install -y qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst ovmf osinfo-db libosinfo-bin
host$ sudo adduser <admin> libvirt               # log out/in afterwards
host$ lsmod | grep kvm
host$ sudo virsh list --all
```

If `grep` prints 0, enable VT-x/AMD-V in the firmware first. (The count can be
twice the number of cores because of a `vmx flags` line: a 4-core CPU prints 8.)

**1.2 Private NAT network for the guest**

```bash
host$ cat > devnet.xml <<'EOF'
<network>
  <name>devnet</name>
  <forward mode='nat'/>
  <bridge name='virbr-dev' stp='on' delay='0'/>
  <ip address='192.168.150.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.150.100' end='192.168.150.200'/>
      <host mac='52:54:00:aa:bb:10' name='devvm' ip='192.168.150.10'/>
    </dhcp>
  </ip>
</network>
EOF
host$ sudo virsh net-define devnet.xml
host$ sudo virsh net-start devnet
host$ sudo virsh net-autostart devnet
host$ sudo virsh net-list --all
```

**1.2b Storage pool for the guest disk**

The default image directory `/var/lib/libvirt/images` lives on `/`, which guided
partitioning can leave small (about 19 GB here, with the rest in `/home`). Check
with `df -h` and put the guest disk where the space is:

```bash
host$ sudo virsh pool-define-as vmpool dir --target /home/libvirt/images
host$ sudo virsh pool-build vmpool
host$ sudo virsh pool-start vmpool
host$ sudo virsh pool-autostart vmpool
host$ sudo virsh pool-list --all
```

**1.3 Isolate the guest: internet only, no host, no LAN, no IPv6**

Replace the `hostfw` table with this extended version (it adds the allowance
the guest needs for DHCP/DNS and the forward rules):

```bash
host$ sudo tee /etc/nftables.conf >/dev/null <<'EOF'
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
    ip saddr 192.168.178.0/24 tcp dport 22 accept
    # the guest may only use DHCP and DNS from the host's libvirt dnsmasq
    iifname "virbr-dev" udp dport { 53, 67 } accept
    iifname "virbr-dev" tcp dport 53 accept
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "virbr-dev" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 224.0.0.0/4 } drop
    iifname "virbr-dev" meta nfproto ipv6 drop
    oifname "virbr-dev" ct state new drop
  }
}
EOF
host$ sudo nft -c -f /etc/nftables.conf && sudo nft -f /etc/nftables.conf
host$ sudo nft list ruleset | grep -E 'table|chain'   # libvirt tables must still be present
```

The guest cannot initiate connections to the host, the LAN, or other private
ranges; the host can still open connections *to* the guest (SSH, virsh).

**1.4 Create the guest (headless install over the serial console)**

Adjust RAM/vCPUs/disk to the spare hardware. The guest's RAM must stay well
below the host's total (7.6 GiB here, so 5 GiB for the guest); vCPUs up to the
host's core count work, but a busy guest then competes with the host.

```bash
host$ osinfo-query os | grep -i 'debian1[23]'    # use debian12 below if debian13 is missing
host$ sudo virt-install \
  --name devvm \
  --memory 5120 --vcpus 4 --cpu host-passthrough \
  --disk pool=vmpool,size=100,format=qcow2,bus=virtio \
  --network network=devnet,model=virtio,mac=52:54:00:aa:bb:10 \
  --osinfo debian13 \
  --graphics none --console pty,target_type=serial \
  --location 'https://deb.debian.org/debian/dists/trixie/main/installer-amd64/' \
  --extra-args 'console=ttyS0,115200n8'
```

In the text installer: hostname `devvm`, empty root password, user `<admin>`,
whole-disk partitioning **without encryption**, software = **SSH server** and
**standard system utilities** only (untick the desktop environment). Install
GRUB to the virtual disk (`/dev/vda`). Leave the console with `Ctrl+]`. After the
final reboot the console can stay quiet, or the guest can end up powered off
(`sudo virsh start devvm`); test with `ssh <admin>@192.168.150.10` from the host
(password login, before hardening).

```bash
host$ sudo virsh list --all
host$ sudo virsh console devvm                   # emergency console access (exit with Ctrl+])
```

**1.5 SSH to the guest through the host (no LAN route to the guest)**

On the notebook, extend `~/.ssh/config`:

```
Host devvm
  HostName 192.168.150.10
  User <admin>
  IdentityFile ~/.ssh/id_ed25519_devhost
  IdentitiesOnly yes
  ProxyJump devhost
```

```bash
notebook$ ssh-copy-id -i ~/.ssh/id_ed25519_devhost.pub devvm
notebook$ ssh devvm
```

**1.6 Guest baseline hardening (same approach as Phase 0)**

```bash
vm$ sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers <admin>
MaxAuthTries 3
X11Forwarding no
EOF
vm$ sudo sshd -t && sudo systemctl reload ssh
vm$ sudo apt update && sudo apt full-upgrade -y
vm$ sudo apt install -y unattended-upgrades apt-listchanges curl ca-certificates
vm$ sudo dpkg-reconfigure -plow unattended-upgrades
vm$ timedatectl                                   # clock synchronized: yes
```

**1.7 Verify isolation (all from inside the guest)**

```bash
vm$ ping -c2 1.1.1.1                                              # works
vm$ curl -sI https://deb.debian.org | head -n1                    # works
vm$ for t in 192.168.178.1:80 192.168.178.1:53 192.168.150.1:22 <host-LAN-IP>:22 <notebook-IP>:22; do
      timeout 3 bash -c "</dev/tcp/${t%:*}/${t#*:}" 2>/dev/null \
        && echo "REACHABLE (BAD): $t" || echo "blocked (good): $t"
    done
vm$ curl -6 -m5 -sS https://ipv6.google.com -o /dev/null || echo "IPv6 blocked (good)"
notebook$ ssh devvm hostname                                      # host -> guest still works (jump through the host; the host itself holds no key for the key-only guest)
```

Do not continue until every "blocked" check is blocked.

### Phase 2: Deploy the containers from the public repo

The Dockerfile, Compose file and bootstrap script live in this repository
(public, no secrets). Everything secret is entered at bootstrap time and stored
only in `.env` on the VM. Push this repo to GitHub first (from the notebook):

```bash
notebook$ cd ~/code/dev-server-ide
notebook$ git init -b main && git add . && git commit -m "Initial dev server setup"
notebook$ gh repo create dev-server --public --source=. --push
```

**2.1 Create the tunnel and get its token (Cloudflare dashboard)**

Zero Trust → Networks → Tunnels → Create tunnel (Cloudflared). The **tunnel ID is
not the token.** The token is the long string starting with `eyJ` in the tunnel's
"Install and run a connector" page: copy only the part after `--token` (or after
`cloudflared service install`) and ignore the install commands, because
`cloudflared` runs as a container here. Keep it out of chat and git. Public
hostname: subdomain `dev`, your domain, empty path, service type **HTTP**, URL
**`code-server:8443`** (not `localhost`; inside the cloudflared container that is
cloudflared itself).

**2.2 Clone and bootstrap (inside the VM)**

```bash
notebook$ ssh devvm                              # via the host (ProxyJump)
vm$ sudo apt install -y git
vm$ git clone https://github.com/MartinsCodingProjects/code-server-bootstrap.git ~/dev-server
vm$ cd ~/dev-server && ./bootstrap.sh
```

The script installs Docker Engine (Debian repo from Docker), asks for the
code-server password (min. 12 chars, typed twice) and the tunnel token (Enter to
skip), writes `.env` with mode 600, then builds and starts code-server and, when
a token was given, `cloudflared`. Re-run it any time; use `--reconfigure` to
change the password or token. Run the commands one at a time (the script prompts
for input) and paste the token as a single line without any `cloudflared ...
--token` prefix; the script rejects spaces. Until you log in again, the new
`docker` group membership is not active, so use `sudo docker ...` in that session.

**2.3 Verify**

```bash
vm$ cd ~/dev-server && docker compose ps          # code-server healthy, cloudflared up
vm$ docker compose logs --tail=30 cloudflared     # "Registered tunnel connection"
vm$ docker exec -u abc code-server sh -c 'claude --version && gh --version | head -1 && tmux -V && docker ps'
```

Check that the container resolves DNS and cannot reach the LAN. Compose pins
`dns: 192.168.150.1` because at boot Docker can start the container before
`dhcpcd` has written the VM's `/etc/resolv.conf`, which leaves the container
without any DNS upstream:

```bash
vm$ docker exec -u abc code-server bash -c 'curl -sS -I https://github.com | head -n1'   # HTTP/2 200
vm$ docker exec -u abc code-server bash -c 'for t in 192.168.178.1:80 <host-LAN-IP>:22 <notebook-IP>:22; do timeout 3 bash -c "</dev/tcp/${t%:*}/${t#*:}" 2>/dev/null && echo "REACHABLE (BAD): $t" || echo "blocked (good): $t"; done'
```

(The VM's own Docker bridge, `172.17.0.1`, is reachable on purpose.)

Without a token, test locally from the notebook:

```bash
notebook$ ssh -L 8443:127.0.0.1:8443 devvm        # then open http://localhost:8443
```

If `docker ps` in the container reports a permission error on the socket, the
`DOCKER_GID` in `.env` does not match the VM's `docker` group; run
`./bootstrap.sh --reconfigure`.

### Phase 3: Cloudflare Access

The tunnel is already up from Phase 2; add the outer authentication gate now.
Until this is done, only the code-server password protects the public hostname.

**3.1 Access policy (dashboard)**

Zero Trust → Access → Applications → Add → Self-hosted and private →
destination type *Public DNS* → `dev.yourdomain.com` → policy *Allow* for your
own identity only. Log in with the **GitHub** login method (OAuth), which is
already configured under Settings → Authentication and also protects other
domains; the one-time-PIN email login is not used.

**3.2 Verify (from a phone on mobile data, plus CLI)**

```bash
notebook$ curl -sI https://dev.yourdomain.com | head -n5   # redirect to *.cloudflareaccess.com
```

After the GitHub login you should see the code-server password prompt (second
gate).

### Phase 4: Authentication and workflow

Run these in the code-server integrated terminal.

```bash
ct$ gh auth login --with-token    # paste the fine-grained token, Enter, then Ctrl+D (see below)
ct$ gh auth setup-git
ct$ gh auth status
ct$ gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"'   # your noreply commit address
ct$ git config --global user.name  "Your Name"
ct$ git config --global user.email "<the noreply address printed above>"
ct$ claude                        # follow the interactive login; complete the browser flow
ct$ terminal-w                    # create or re-attach the named session
```

`terminal-w` is an alias for `tmux new -As work`, baked into the image
(`/etc/bash.bashrc`) by the Dockerfile that `bootstrap.sh` builds. It is not
attached automatically, so each terminal tab stays independent until you run it.

Detach with `Ctrl+b d`, close the browser tab, reopen it, and run
`terminal-w` again: the session and any running `claude` process remain.
Login pitfalls inside the container:

- GitHub token: use a **fine-grained personal access token**, not the browser
  device login (that OAuth token gets the broad `repo` and `workflow` scopes and
  never expires). Create it at `github.com/settings/personal-access-tokens/new`:
  resource owner = your account, *All repositories*, repository permissions
  Contents, Pull requests and Issues **Read and write**, Metadata read, and
  nothing else (no Workflows, Administration or Secrets), expiry 90 days. Log in
  with `gh auth login --with-token`. `gh repo create` needs Administration, so
  create repos in the web UI. If you logged in with the device flow before, run
  `gh auth logout` (it only deletes the local copy) and revoke "GitHub CLI" under
  `github.com/settings/applications`. Rotate before the expiry by repeating
  `gh auth logout` and `gh auth login --with-token`. Add a ruleset on `main`
  (require a pull request) to repos that matter. (If you do use the browser flow,
  do not press Ctrl+C at "Press Enter to open ...": open
  `https://github.com/login/device` yourself and enter the code while `gh` waits.)
- `claude`: the browser redirect points at `localhost`, which is the notebook, not
  the container. Do not click the link: copy the URL by hand, authorize in a new
  tab and paste the code at "Paste code here".
- Commit email: use the GitHub noreply address (`gh api user --jq
  '"\(.id)+\(.login)@users.noreply.github.com"'`) and enable "Keep my email
  addresses private" and "Block command line pushes that expose my email" in
  GitHub's settings. Set `git config user.email` on every machine that commits,
  or the push is rejected.

Set Claude usage limits/alerts in your Anthropic account console.

Verify credentials survive a container recreation:

```bash
vm$ cd ~/dev-server && docker compose up -d --force-recreate code-server
ct$ gh auth status && claude --version       # still authenticated
```

### Phase 5: Unattended boot and recovery

**5.1 Firmware (on the physical machine, no CLI)**

Set "Restore on AC power loss" / "After power failure" to **Power On**. Make
sure nothing waits for a keypress at boot (no GRUB menu timeout of 0 issues, no
disk passphrase).

**5.2 Host: libvirt, VM and network autostart**

```bash
host$ sudo systemctl enable --now libvirtd libvirt-guests nftables
host$ sudo virsh net-autostart devnet
host$ sudo virsh autostart devvm
host$ sudo virsh list --all --autostart
host$ sudo sed -i 's/^#\?ON_BOOT=.*/ON_BOOT=start/; s/^#\?ON_SHUTDOWN=.*/ON_SHUTDOWN=shutdown/; s/^#\?SHUTDOWN_TIMEOUT=.*/SHUTDOWN_TIMEOUT=120/' /etc/default/libvirt-guests
```

**5.3 Host: firewall rules must exist before the VM starts**

```bash
host$ sudo mkdir -p /etc/systemd/system/libvirtd.service.d
host$ sudo tee /etc/systemd/system/libvirtd.service.d/10-after-nftables.conf >/dev/null <<'EOF'
[Unit]
After=nftables.service
Wants=nftables.service
EOF
host$ sudo systemctl daemon-reload
host$ systemctl show libvirtd -p After | tr ' ' '\n' | grep nftables
```

**5.4 Guest: Docker and containers come back by themselves**

```bash
vm$ systemctl is-enabled docker containerd         # both: enabled
vm$ docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' code-server cloudflared
                                                    # both: unless-stopped
vm$ timedatectl | grep synchronized                 # NTP on (wrong clock breaks the tunnel)
```

**5.5 Test the whole chain**

```bash
host$ sudo reboot                                  # or pull the power plug
# wait a few minutes, touch nothing, then from the notebook:
notebook$ ssh -t devhost 'virsh -c qemu:///system list --all; sudo nft list table inet hostfw | head -n3'   # -t lets sudo ask for the password
notebook$ ssh devvm 'docker compose -f ~/dev-server/docker-compose.yml ps'
notebook$ ssh devvm "docker exec -u abc code-server curl -sS -I https://github.com | head -n1"   # DNS works without a manual restart
notebook$ curl -sI https://dev.yourdomain.com | head -n3   # Access redirect again
```

The Access redirect alone does not prove the tunnel works (Cloudflare answers it
at its edge). Cloudflare **error 1033** means no `cloudflared` is connected:
usually the VM is off (no `virsh autostart devvm`) or the containers are down.
Run a soft reboot first and then a real power-loss test (pull the plug); the
firmware setting from 5.1 must bring the machine back on its own.

Also test a guest-only reboot (`vm$ sudo reboot`) and
`vm$ sudo systemctl restart docker`; rerun the Phase 1.7 isolation checks after
the host reboot.

## Updates and Operations

- Enable security updates on both host and guest. Schedule and verify reboots
  when kernel updates require them; host maintenance also interrupts the VM.
- Pin container image versions rather than tracking `latest`. Automate update
  detection (for example, a checker or dependency-update PRs), but initially
  review and apply image updates deliberately so an unattended restart does not
  interrupt active work. Keep a known-good version for rollback.
- Docker packages come from Docker's own apt repository; the default
  unattended-upgrades origins do not cover them, so run `sudo apt upgrade`
  in the VM occasionally (a Docker daemon restart restarts the containers).
- Review Cloudflare Access/Tunnel status and host/guest disk space periodically.
- Rotate credentials on a schedule: the GitHub fine-grained token before it
  expires (90 days), and the code-server password or tunnel token when needed
  (`./bootstrap.sh --reconfigure`; a tunnel token can be refreshed in the
  Cloudflare dashboard).

```bash
# security updates: automatic (unattended-upgrades); check what happened
host$ sudo tail -n 30 /var/log/unattended-upgrades/unattended-upgrades.log
host$ [ -f /var/run/reboot-required ] && echo "reboot pending"
# container updates: deliberate, with rollback
vm$ cd ~/dev-server && git pull                          # bump pinned tags in the repo first (commit from notebook)
vm$ ./bootstrap.sh --update                              # pulls, rebuilds, restarts
vm$ docker compose ps
vm$ docker image prune -f                                # only once the new version is verified
# disk and health
host$ df -h /var/lib/libvirt/images && sudo virsh domblklist devvm
vm$ df -h / && docker system df
```
- **Recovery without backups (a deliberate decision: no backup target is
  available).** Recovery is a rebuild: reinstall the host, follow Phases 0-5 and
  re-run `./bootstrap.sh`.
  - Reproduced from this repo and plan: host, firewall, VM, Docker stack.
  - Re-created by you: the code-server password, a new GitHub token, the Claude
    login, and the tunnel token (the tunnel and its hostname live in Cloudflare;
    copy the token from the tunnel's connector page, and note that "Refresh
    token" invalidates the old one). Keep a copy of the notebook's
    `~/.ssh/id_ed25519_devhost`; it is not on the server.
  - **Lost:** anything in `projects/` that is not pushed to GitHub (uncommitted
    changes, untracked files, local-only branches) and the code-server
    settings, extensions and shell history in `config/`. Commit and push
    regularly (WIP branches are fine) and never keep the only copy of anything
    on the server.
  - Optional later: copy the VM disk (`/home/libvirt/images/`, VM shut down)
    to the spare internal disk, which only covers a failing system disk, or to
    an off-site target. Git is not a backup for untracked files, local
    configuration, or credentials.

## Prototype Acceptance Checks

- Host administration works from the notebook over LAN SSH; the guest is reached
  only via an SSH jump through the host and has no direct LAN route.
- The guest can reach required internet services and Cloudflare, but cannot
  initiate connections to host or LAN/private destinations over IPv4 or IPv6.
- A project can build and run Docker containers inside the guest.
- code-server resolves DNS and has internet right after a reboot, without a
  manual container restart, and still cannot reach the LAN.
- The Cloudflare Access login protects code-server, and its origin port is not
  publicly exposed.
- Claude Code and GitHub authentication work from the code-server terminal and
  survive a container recreation through the persistent user config.
- A browser disconnect/reconnect preserves a tmux session.
- After a power cut or host reboot with no intervention, the VM, Docker,
  code-server, and the tunnel all come back, the isolation rules are active,
  and the site is reachable through Cloudflare Access. Running tmux sessions and
  in-flight processes are expected to be lost.

## End Result

SSH to the Debian host from the notebook only when VM administration is needed.
For normal work, open `https://dev.yourdomain.com` from any device, authenticate
through Cloudflare Access and code-server, attach to tmux, and work in the
persistent VM environment. Projects can use Docker inside that VM without
access to the physical host's Docker daemon.
