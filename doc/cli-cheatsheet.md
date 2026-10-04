# CLI cheat sheet

Everyday and maintenance commands for this setup. Names used throughout:

| Name | What | Where it is set up |
|---|---|---|
| notebook | your laptop (SSH client) | |
| `devhost` | physical Debian host, runs KVM/libvirt | `ssh devhost` (alias, `~/.ssh/config`) |
| `devvm` | guest VM, runs Docker | `ssh devvm` (jumps through `devhost`) |
| `code-server`, `cloudflared` | containers in the VM | `~/dev-server` on the VM |

Prompts in this file: `notebook$`, `host$` (on `devhost`), `vm$` (on `devvm`),
`ct$` (code-server terminal in the browser). The SSH aliases exist only on the
notebook, so run `ssh devhost` / `ssh devvm` there, not from the host or VM.

Habits that avoid trouble:

- Run `sudo -v` first when you paste several lines; the password prompt would
  swallow the following lines otherwise.
- Run commands that prompt (`su -`, `ssh-copy-id`, `./bootstrap.sh`) on their own.
- Keep one SSH session open while you change SSH or firewall settings, and test
  from a second terminal before closing it.

## 1. Connect

```bash
notebook$ ssh devhost                                  # host (key passphrase, once per session)
notebook$ ssh devvm                                    # VM, through the host
notebook$ ssh -L 8443:127.0.0.1:8443 devvm             # code-server on http://localhost:8443 (no tunnel needed)
notebook$ ssh-add -l                                   # keys in the agent
notebook$ ssh-add ~/.ssh/id_ed25519_devhost            # load the key manually
notebook$ getent hosts devhost.fritz.box               # does the Fritzbox name resolve?
notebook$ ssh-keygen -R devhost.fritz.box              # after a rebuild: "REMOTE HOST IDENTIFICATION HAS CHANGED"
notebook$ ssh-keygen -R 192.168.150.10                 # same for the VM
```

Find the host if the name does not resolve (scan the LAN for an open port 22):

```bash
notebook$ for i in $(seq 1 254); do (timeout 1 bash -c "echo > /dev/tcp/192.168.178.$i/22" 2>/dev/null && echo "192.168.178.$i ssh open") & done; wait
notebook$ ssh -i ~/.ssh/id_ed25519_devhost martin@192.168.178.145   # by IP while the name is missing
```

## 2. Health checks

One command for the whole container stack (read-only, non-zero exit on failure):

```bash
vm$ cd ~/dev-server && ./bootstrap.sh --check
```

Host:

```bash
host$ uptime -p; free -h; df -h / /home
host$ systemctl --failed                               # should list nothing
host$ sudo ss -tulpn                                   # expect only sshd (22) and the DHCP client
host$ timedatectl | grep synchronized                  # "yes"
host$ virsh -c qemu:///system list --all               # devvm: running
host$ sudo nft list table inet hostfw                  # firewall present
host$ sudo smartctl -H /dev/sda; sudo smartctl -H /dev/sdb   # PASSED (device names: lsblk)
host$ grep . /sys/devices/system/cpu/vulnerabilities/* # CPU mitigations
```

VM:

```bash
vm$ uptime -p; free -h; df -h /
vm$ systemctl is-enabled docker containerd             # enabled, enabled
vm$ ss -tlnp | grep -v 127.0.0.53                      # :22 and 127.0.0.1:8443 only
vm$ timedatectl | grep synchronized
```

From the notebook (does the public site answer?):

```bash
notebook$ curl -sI https://dev.yourdomain.com | head -n3  # 302 to cloudflareaccess.com is Access only,
                                                       # it does not prove the tunnel; use --check or a browser login
```

## 3. The container stack (VM, in `~/dev-server`)

```bash
vm$ cd ~/dev-server
vm$ docker compose ps                                  # use "sudo docker" until you log in again after the first bootstrap
vm$ docker compose logs -f --tail=50 code-server       # Ctrl+C to stop following
vm$ docker compose logs --tail=30 cloudflared          # "Registered tunnel connection" lines
vm$ docker compose restart code-server                 # ends tmux sessions' processes
vm$ docker compose up -d --force-recreate code-server  # logins in ./config survive
vm$ docker stats --no-stream                           # CPU and memory per container
vm$ docker exec -it -u abc code-server bash            # shell in the container
vm$ docker exec -u abc code-server sh -c 'claude --version && gh --version | head -1 && tmux -V && docker ps'
```

`bootstrap.sh`:

```bash
vm$ ./bootstrap.sh                 # first run / re-run, keeps the password and token
vm$ ./bootstrap.sh --reconfigure   # new code-server password and/or tunnel token
vm$ ./bootstrap.sh --update        # pull, re-run the new script, refresh .env, rebuild, restart
vm$ ./bootstrap.sh --check         # health check
vm$ DEV_PASSWORD=... TUNNEL_TOKEN=... ./bootstrap.sh   # non-interactive
```

## 4. Inside code-server (`ct$`)

```bash
ct$ terminal-w                     # attach to or create the persistent tmux session "work"
                                   # detach: Ctrl+b d      list: tmux ls      kill: tmux kill-session -t work
ct$ gh auth status                 # GitHub login (fine-grained token)
ct$ gh auth logout && gh auth login --with-token && gh auth setup-git   # rotate the token (paste it, Enter, Ctrl+D)
ct$ git config --global user.email "<id>+<login>@users.noreply.github.com"
ct$ claude                         # Claude Code; login: copy the URL by hand, paste the code back
ct$ docker ps                      # the VM's Docker, through the mounted socket
```

## 5. The VM from the host (libvirt)

```bash
host$ sudo virsh list --all
host$ sudo virsh start devvm
host$ sudo virsh shutdown devvm                        # clean shutdown (ACPI)
host$ sudo virsh reboot devvm
host$ sudo virsh destroy devvm                         # hard power off, only if shutdown hangs
host$ sudo virsh console devvm                         # serial console, leave with Ctrl+] ; Enter shows the prompt
host$ sudo virsh dominfo devvm                         # memory, vCPUs, autostart
host$ sudo virsh domifaddr devvm                       # its IP (192.168.150.10)
host$ sudo virsh domblklist devvm                      # disk image path
host$ sudo virsh autostart devvm                       # on boot (add --disable to undo)
host$ sudo virsh dumpxml devvm                         # the full definition
host$ sudo virsh net-list --all; sudo virsh net-dhcp-leases devnet
host$ sudo virsh pool-list --all; sudo virsh vol-list vmpool
```

Change memory or vCPUs (the VM must be shut down; keep RAM well below the host's):

```bash
host$ sudo virsh shutdown devvm
host$ sudo virsh setmaxmem devvm 6G --config && sudo virsh setmem devvm 6G --config
host$ sudo virsh setvcpus devvm 3 --config --maximum && sudo virsh setvcpus devvm 3 --config
host$ sudo virsh start devvm
```

Cold copy of the VM disk (VM shut down; no backups are scheduled by default):

```bash
host$ sudo virsh shutdown devvm
host$ sudo cp --sparse=always /home/libvirt/images/devvm.qcow2 /path/to/target/   # path: virsh domblklist devvm
host$ sudo virsh start devvm
```

## 6. Updates and upkeep

Operating system (host and VM):

```bash
$ sudo apt update && apt list --upgradable             # what is pending
$ sudo apt update && sudo apt full-upgrade -y          # manual upgrade (VM: also covers Docker's own packages)
$ cat /var/run/reboot-required 2>/dev/null || echo "no reboot pending"
$ systemctl list-timers 'apt-daily*'                   # unattended-upgrades schedule
$ sudo tail -n 30 /var/log/unattended-upgrades/unattended-upgrades.log
$ sudo unattended-upgrade --dry-run --debug 2>&1 | tail -n 5
$ sudo apt autoremove -y
```

The host reboots itself at 04:00 when needed (and restarts the VM). The VM does
not: reboot it after kernel updates with `vm$ sudo reboot`.

Container images, about monthly (see the README, "Updating"):

```bash
notebook$ # bump the pins (Dockerfile ARG, compose defaults, .env.example), commit, push
vm$ cd ~/dev-server && ./bootstrap.sh --update && ./bootstrap.sh --check
vm$ docker image prune -f                              # after you verified it works
vm$ docker compose build --pull --no-cache && ./bootstrap.sh   # fresher Node, gh, Claude Code on the same base tag
```

Disk space:

```bash
$ df -h
vm$ docker system df                                   # images, containers, volumes, build cache
vm$ docker image prune -f; docker builder prune -f
$ sudo journalctl --vacuum-size=200M                   # trim the system journal
$ sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail
```

Credentials on a schedule: GitHub fine-grained token (before it expires, see
section 4), code-server password or tunnel token (`./bootstrap.sh --reconfigure`;
refresh the tunnel token in the Cloudflare dashboard first, which invalidates the
old one).

## 7. SSH and firewall (host)

```bash
host$ sudo sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|allowusers'
host$ sudo journalctl -u ssh --since today | grep -Ei 'failed|invalid|accepted'
host$ sudo sshd -t && sudo systemctl reload ssh        # after editing /etc/ssh/sshd_config.d/*.conf
notebook$ ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password devhost   # must say: Permission denied (publickey)
```

Add or replace an SSH key: `notebook$ ssh-copy-id -i ~/.ssh/<new>.pub devhost`, then
remove the old line from `~/.ssh/authorized_keys` on the target.

```bash
host$ sudo nft list ruleset | grep -E 'table|chain'    # hostfw plus libvirt's tables (ip filter / ip nat via iptables-nft)
host$ sudo nft -c -f /etc/nftables.conf                # syntax check only
host$ sudo nft -f /etc/nftables.conf                   # re-apply (replaces only the hostfw table)
host$ sudo nft flush table inet hostfw                 # emergency: remove the rules, e.g. if locked out (use the host's console)
```

Isolation test, run inside the VM after any firewall or network change (every
line must say "blocked (good)"; use your own LAN addresses):

```bash
vm$ for t in 192.168.178.1:80 192.168.178.1:53 192.168.150.1:22 192.168.178.145:22; do
      timeout 3 bash -c "</dev/tcp/${t%:*}/${t#*:}" 2>/dev/null \
        && echo "REACHABLE (BAD): $t" || echo "blocked (good): $t"
    done
vm$ curl -6 -m5 -sS https://ipv6.google.com -o /dev/null || echo "IPv6 blocked (good)"
```

## 8. Rename the host

```bash
host$ sudo hostnamectl set-hostname <new>
host$ sudo sed -i '/^127\.0\.1\.1/s/\bdebian\b/<new>/g' /etc/hosts   # replace the old name shown there
host$ sudo reboot
notebook$ getent hosts <new>.fritz.box                 # wait until it resolves, then update HostName in ~/.ssh/config
```

## 9. Setup scripts (fresh install, test VMs)

```bash
notebook$ setup/notebook-setup.sh [--dry-run]          # key, aliases, copy the key to the host
host$ setup/host-setup.sh [--dry-run]                  # re-runnable: unchanged things are left alone
host$ setup/create-vm.sh                               # new VM from the Debian cloud image
host$ setup/create-vm.sh --finish [--name N]           # after the first boot: remove the seed disk
host$ setup/create-vm.sh --name devvm2 --ip 192.168.150.11 --mac 52:54:00:aa:bb:11   # a test VM
host$ setup/create-vm.sh --remove --name devvm2 --ip 192.168.150.11 --mac 52:54:00:aa:bb:11
notebook$ ssh devvm 'bash -s -- <router-ip> <host-lan-ip> 192.168.150.1' < setup/verify-isolation.sh
notebook$ ssh devvm 'cloud-init status --wait'         # first boot finished? ("status: done")
```

Answers are remembered in `setup/setup.env` (git-ignored). See
[setup-scripts.md](setup-scripts.md) for what each script does.

## 10. Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| Cloudflare **error 1033** | `host$ sudo virsh list --all`, then `vm$ docker compose ps` | Start the VM (`virsh start devvm`), make sure autostart is on; the containers restart by themselves |
| Login page works, code-server page does not load | `vm$ ./bootstrap.sh --check` | Look at the failing line; `docker compose logs code-server` |
| No internet or DNS in the container | `vm$ docker exec code-server cat /etc/resolv.conf` | Compose pins `dns: 192.168.150.1`; `docker compose up -d --force-recreate` |
| Cannot SSH after a firewall change | `ping devhost.fritz.box` | At the host's console: `sudo nft flush table inet hostfw`, fix `/etc/nftables.conf`, re-apply |
| `Could not resolve hostname` | `getent hosts devhost.fritz.box` | Use the IP until the Fritzbox picks up the name (new DHCP lease or reboot) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | rebuilt host or VM? | `ssh-keygen -R <name or IP>` |
| `sudo: command not found` on a fresh Debian | root password was set at install | `su -`, `apt install -y sudo`, `usermod -aG sudo <user>`, log in again |
| VM did not come back after a power cut | `virsh list --all`, `virsh dominfo devvm` | `virsh autostart devvm`; check the BIOS "Power On after AC loss" |
| tmux exits immediately in the container | `echo $SHELL` is `/bin/false` | Fixed by `/etc/tmux.conf` in the image; rebuild if missing |
| `./bootstrap.sh` says permission denied on docker | group not active yet | Log in again, or use `sudo docker` |
| Disk almost full | `df -h`, `docker system df` | Section 6, "Disk space" |
| Clock wrong, tunnel flaps | `timedatectl` | `sudo timedatectl set-ntp true` |
