# Setup and bootstrap review: main suggested fixes

Scope: `bootstrap.sh`, `Dockerfile`, `docker-compose.yml`, `.env.example`,
`README.md`, `dev-server-plan.md`. Findings are from reading; nothing was tested.

The design is sound: the VM is the trust boundary, the tunnel is outbound only,
port 8443 binds to `127.0.0.1`, and there are two authentication layers. The
fixes below close the remaining gaps, in priority order.

## High priority

1. **Backups (plan marks them out of scope).** Back up `config/` (Claude and `gh`
   logins) and `projects/` regularly (e.g. nightly `restic` or `tar` from the VM).
   Also snapshot the VM disk periodically from the host. Test a restore.
2. **Stale `.env` on a rebuilt or moved VM.** A re-run keeps the old `.env`, so
   `PUID`, `PGID`, `DOCKER_GID`, `PROJECTS_DIR` and `TZ` can be wrong after a
   restore or move (different `docker` group GID or clone path breaks the socket
   and the mounts). Recompute these derived values on every run and keep only
   `PASSWORD` and `TUNNEL_TOKEN` from the existing file.
3. **`--update` rewrites the running script.** `git pull` replaces `bootstrap.sh`
   while bash is still reading it. Pull first, then `exec "$0"` the new copy (with
   a flag to skip the pull).
4. **Secrets are visible in plain text.** `PASSWORD` and `TUNNEL_TOKEN` show up in
   `docker inspect` and in the container environment, which any process with the
   Docker socket can read. Use `HASHED_PASSWORD` (or `FILE__PASSWORD`) for
   code-server, and `--token-file` or Docker secrets for `cloudflared`.
5. **`config/` permissions.** Plan decision 8 requires restrictive permissions, but
   `mkdir -p config` uses the default umask. Use `chmod 700 config` and make sure it
   is owned by `PUID`.

## Medium priority

6. **Unpinned build inputs.** Pin or digest-pin the base image, `docker:cli`,
   `@anthropic-ai/claude-code`, and the `docker-ce` and `containerd.io` packages.
   Verify the GPG key fingerprints for the Docker, NodeSource and `gh` apt
   repositories instead of trusting the download alone. Add Renovate or Dependabot
   for the pinned versions.
7. **Docker install is only partly idempotent.** `command -v docker` returns early,
   so a missing compose plugin or a stopped daemon is not repaired. Check
   `docker compose version` and `systemctl is-active docker`.
8. **Preflight and verification.** Add checks for time sync (a wrong clock breaks
   the tunnel), DNS and egress, free disk space, and `docker compose config -q`
   before `up`. Add a `--check` mode that runs the plan's verification steps
   (2.3 and 5.4) in one command.
9. **Unbounded Docker logs.** Set `log-driver json-file` with `max-size` and
   `max-file` in `/etc/docker/daemon.json`, otherwise logs can fill the VM disk.
10. **Container hardening.** Add `cap_drop: [ALL]` (re-add only what is needed),
    `mem_limit` and `pids_limit`. Make `cloudflared` read-only and give it a
    healthcheck.

## Hardware-host change / rebuild stability

11. **Do not tie the VM to the CPU model.** Replace `--cpu host-passthrough` with
    `host-model` or a named baseline CPU, and pin the machine type (e.g. `q35`).
12. **Record host state.** Keep these in a backup or in a runbook: `virsh dumpxml
    devvm`, `devnet.xml`, `/etc/nftables.conf`, `/etc/default/libvirt-guests`, the
    libvirtd drop-in, the UEFI NVRAM file, the qcow2 disk, and the host SSH host
    keys (so the notebook sees no host-key warnings). The fixed MAC and IP in
    `devnet.xml` already keep the guest address stable.
13. **Add a "rebuild from scratch" runbook** to the plan: restore the VM, `git
    clone`, `./bootstrap.sh`, restore `config/` and `projects/`, run the
    acceptance checks. Include the firmware "Power On after AC loss" setting on the
    new hardware, and avoid hard-coding physical NIC names in firewall rules.

## Residual risks to accept knowingly

- The mounted Docker socket is root on the VM. The Cloudflare Access policy
  (single identity, short session) and the code-server password are the only
  barriers, and the VM egress rules matter. Do not run Claude with permission
  prompts disabled in this container.
- Use a narrowly scoped GitHub login (fine-grained token) for `gh`.
- Add basic monitoring (tunnel status, disk space) and document rotating the
  password and tunnel token.
