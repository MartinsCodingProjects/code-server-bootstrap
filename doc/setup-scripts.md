# The setup scripts

`setup/` automates the manual steps of [the plan](../dev-server-plan.md) so that a
second run, on this or other hardware, takes minutes of attention instead of hours
of copy and paste. The plan stays the explanation of *why*, and the manual fallback.

Every script explains each question before it asks it, shows the detected default in
`[brackets]` (Enter accepts it), can be re-run safely, and accepts `--dry-run` (show
what would happen, change nothing) and `--yes` (accept the defaults).

## The flow

```text
notebook                        host (physical)                      VM
--------                        ---------------                      --
notebook-setup.sh  ──key──▶     host-setup.sh
                                  SSH key-only, updates, firewall,
                                  KVM/libvirt, VM network, pool
                                create-vm.sh  ──cloud-init──▶        user, key, updates, git clone
ssh devvm 'cloud-init status --wait'                                 
ssh devvm                                                            ./bootstrap.sh
                                                                       (password, token, dev hostnames, database)
verify-isolation.sh ─────────────────────────────────────────▶       checks
                                create-vm.sh --finish                (removes the seed disk)
```

## What each script does

| Script | Runs on | Does |
|---|---|---|
| `setup/notebook-setup.sh` | notebook | Creates a dedicated passphrase-protected SSH key, adds the `devhost` and `devvm` aliases (IPv4 only, key only, VM through the host) to `~/.ssh/config` in a marked block, copies the key to the host. |
| `setup/host-setup.sh` | host | Checks CPU virtualization, RAM and network; installs packages; console keyboard layout; automatic security updates; CPU microcode; SSH hardening; KVM/libvirt, the private VM network `devnet` and the storage pool `vmpool`; the firewall; start order and autostart; locks the root password; SMART health. |
| `setup/create-vm.sh` | host | Downloads and verifies the Debian 13 cloud image, builds the VM disk and a cloud-init seed disk, reserves the VM's address, starts the VM with autostart. cloud-init creates your user, installs the key, makes SSH key-only, installs updates, git and unattended-upgrades and clones this repository. `--finish` removes the seed disk; `--remove --name N` deletes a test VM. |
| `bootstrap.sh` | VM | Installs Docker, asks for the code-server password, the tunnel token, an optional domain and ports for dev app hostnames and whether to run MariaDB (each prompt explains itself and rejects typical mistakes, such as the tunnel ID instead of the token), starts the stack. |
| `setup/verify-isolation.sh` | VM (from the notebook) | Internet works; the router, the host's SSH, your LAN and IPv6 are blocked. |

## Questions you will be asked

`host-setup.sh` (answers are remembered in `setup/setup.env`, git-ignored):

| Question | Default | Why it matters |
|---|---|---|
| Your LAN | from the default route | SSH to the host is allowed only from here. A wrong value would lock you out, so the firewall is applied with an automatic rollback (see below). |
| VM network prefix | `192.168.150` | The VM sits on its own network behind the host; must not overlap the LAN. |
| VM name, address, MAC | `devvm`, `.10`, `52:54:00:aa:bb:10` | Fixed address by DHCP reservation. |
| VM memory | host RAM minus 2.5 GB, 512 MB steps, at most 8 GB | The VM's RAM is fixed; the host needs the rest. |
| VM CPU cores | host cores, at most 4 | All cores can slow the host under load. |
| VM disk | 100 GB | Sparse file; only used space is stored. |
| Folder for VM disks | `/var/lib/libvirt/images` if it has room, else `/home/libvirt/images` | Guided partitioning often leaves `/` small. |
| Keyboard, auto-reboot, root lock | `de`/current, `true` at 04:00, `yes` | See the explanations printed by the script. |

`create-vm.sh`: VM user (default: your user), the VM password (hidden; needed for
`sudo` and the emergency console; SSH never accepts it), a confirmation of the SSH
keys that will be installed, the repository URL, time zone, RAM, cores, disk.

`bootstrap.sh`: the code-server password (at least 12 characters); the tunnel
token (paste it, or Enter to skip and use `ssh -L` instead); an optional domain and
the ports for the dev app hostnames (default `5173 8000 5000 3000 4173 5174`); and
whether to run MariaDB (default yes; passwords are generated). Non-interactive:
`DEV_PASSWORD`, `TUNNEL_TOKEN`, `DEV_DOMAIN`, `DEV_PORTS` and `DEV_DB` environment
variables. `--dev-hosts` and `--mariadb` change those two later.

## Safety design

- **No lockout from SSH hardening.** `host-setup.sh` refuses to disable password
  login unless it finds a successful *key* login in the SSH log (or you type `yes`).
- **No lockout from the firewall.** New rules are syntax-checked (`nft -c`), then
  applied with a two-minute rollback timer. You open a *second* SSH session and
  confirm; otherwise the previous rules return by themselves. Without a terminal the
  script refuses to apply them. Unchanged rules are not touched on a re-run.
- **Secrets.** The scripts never see the tunnel token. The VM password is stored
  only as a SHA-512 hash in the seed disk, which `create-vm.sh --finish` ejects and
  deletes. The password is not on any command line.
- **The VM keeps password `sudo`.** The cloud image's usual passwordless sudo is
  replaced by your password, as in the manual build. SSH is key-only.
- **Verified download.** The cloud image's SHA-512 checksum is fetched from
  cloud.debian.org and compared before the image is used.

## What stays manual (no API, or a physical setting)

- Installing Debian on the host (netinst; hostname `devhost`, no root password, SSH
  server and standard system utilities only), the BIOS option "Restore on AC power
  loss: Power On", and the router (the Fritzbox resolves `<hostname>.fritz.box`).
- The Cloudflare tunnel, its public hostname and the Access policy (clicks in the
  dashboard; plan 2.1 and Phase 3). You copy the tunnel token into `bootstrap.sh`.
- The Public Hostname and Access entry for each dev app port (plan 3.3); `bootstrap.sh`
  prints the names and `--check` tells which are missing.
- The GitHub fine-grained token and the Claude Code login (plan Phase 4).

## Tested and not tested

Tested during development, on a notebook without KVM:

- Shell syntax of all scripts; full `--dry-run` of the host and VM scripts.
- The rendered firewall rules, VM network XML and SSH hardening are **byte-identical**
  to the versions that ran on the real host.
- The rendered cloud-init `user-data` parses as YAML with the expected users, keys
  (including quoting), packages, files and commands; the password hash is intact.
- The seed ISO (label `cidata`) and the `qemu-img` convert and resize steps with the
  real tools.
- The notebook script in a scratch home directory: idempotent, leaves other entries
  alone, `ssh -G` resolves the jump host.
- The `bootstrap.sh` prompts through a real pseudo-terminal, with wrong and right input,
  and the whole script from a clean directory against real Docker: a fresh install,
  `--check`, and `--mariadb` disable and re-enable. That run found and fixed a bug that
  stopped fresh installs after the token prompt.

**Not tested on real hardware** (needs `nft`, libvirt and the cloud image): applying the
firewall with the rollback timer, `virt-install` with the cloud image and seed disk,
and cloud-init's behavior inside the image. Run the protocol below once before
relying on the scripts for a rebuild.

## Test protocol on the live host (does not touch the running VM)

1. **Idempotency of the host script.** `setup/host-setup.sh --dry-run`, then for real:
   `setup/host-setup.sh`. On the already configured host everything should report
   "unchanged" or "already exists", and the firewall step says "firewall rules
   unchanged". Check the answers it proposes match what you have
   (`virsh net-dumpxml devnet`, `cat /etc/nftables.conf`).
2. **A throwaway VM next to the live one** (small, so RAM is not a problem; answer
   the prompts with 1024 MB, 1 core, 10 GB):
   `setup/create-vm.sh --name devvm2 --ip 192.168.150.11 --mac 52:54:00:aa:bb:11`
3. Wait, then log in through the host (the `devvm` alias belongs to the live VM):
   `ssh -J devhost <user>@192.168.150.11 'cloud-init status --wait'`
   Expect `status: done`, a login that works with the key only, `sudo` asking for the
   password you set, and `~/dev-server` cloned.
4. Isolation of the test VM:
   `ssh -J devhost <user>@192.168.150.11 'bash -s -- <router-ip> <host-lan-ip> 192.168.150.1' < setup/verify-isolation.sh`
5. Remove the seed disk and then the test VM:
   `setup/create-vm.sh --finish --name devvm2`, then
   `setup/create-vm.sh --remove --name devvm2 --ip 192.168.150.11 --mac 52:54:00:aa:bb:11`

If any step fails, the output and `sudo virsh console devvm2` show why; tell me what
you see and I will fix the script.

## Limits

- Debian 13 hosts only; IPv4 only; the VM network must be a /24.
- One physical host, one main VM (a second VM is supported for tests with `--name`).
- The scripts do not manage Cloudflare, GitHub or Claude credentials, by design.
