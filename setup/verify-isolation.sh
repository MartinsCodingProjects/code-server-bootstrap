#!/usr/bin/env bash
# Checks the VM's network isolation. Run it INSIDE the VM, from the notebook:
#
#   ssh devvm 'bash -s -- <router-ip> <host-lan-ip> <vm-gateway-ip> [more LAN ip:port ...]' < setup/verify-isolation.sh
#   e.g.  ssh devvm 'bash -s -- 192.168.178.1 192.168.178.145 192.168.150.1' < setup/verify-isolation.sh
#
# It expects internet access and that everything on your LAN, the host's SSH and
# IPv6 are blocked. Exit code 0 means all checks passed.
set -u
[ $# -ge 3 ] || { echo "usage: $0 <router-ip> <host-lan-ip> <vm-gateway-ip> [ip:port ...]" >&2; exit 2; }
router=$1; host_lan=$2; gw=$3; shift 3
fail=0

echo "Must work:"
if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then echo "  ok    ping 1.1.1.1"; else echo "  FAIL  ping 1.1.1.1 (no internet)"; fail=1; fi
if curl -fsS -m8 -o /dev/null https://deb.debian.org 2>/dev/null; then echo "  ok    https://deb.debian.org (DNS and internet)"; else echo "  FAIL  https://deb.debian.org"; fail=1; fi

echo "Must be blocked:"
for t in "$router:80" "$router:53" "$gw:22" "$host_lan:22" "$@"; do
  if timeout 3 bash -c "</dev/tcp/${t%:*}/${t#*:}" 2>/dev/null; then
    echo "  FAIL  REACHABLE: $t"; fail=1
  else
    echo "  ok    blocked: $t"
  fi
done
if curl -6 -m5 -sS https://ipv6.google.com -o /dev/null 2>/dev/null; then echo "  FAIL  IPv6 works"; fail=1; else echo "  ok    IPv6 blocked"; fi

[ "$fail" -eq 0 ] && echo "All isolation checks passed." || echo "SOME CHECKS FAILED: do not use this VM until fixed."
exit "$fail"
