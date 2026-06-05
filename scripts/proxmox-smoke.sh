#!/usr/bin/env bash
# In-guest smoke test -- runs as root INSIDE the freshly built Proxmox VE image
# (copied in over SSH by scripts/smoke-test.sh). Validates the "services
# consolidation domain" patterns the image exists to serve:
#
#   1. Proxmox identity + API are alive          (pveversion, pvesh)
#   2. The internal NAT bridge `vmbr1` comes up   (the homelab pattern)
#   3. An unprivileged LXC container boots         (containers, not KVM VMs --
#      LXC is namespaces-only so it works even nested under Qubes/QEMU)
#   4. The container reaches its gateway AND the   (the network seam: local
#      internet via NAT-out through vmbr0           bridge + masquerade)
#
# Exits non-zero on the first failed assertion so CI can gate the GHCR push.
# Dependency-light: only stock PVE tooling + busybox in the Alpine guest.
set -euo pipefail

VMID=900
BRIDGE_CIDR="10.10.10.1/24"
BRIDGE_NET="10.10.10.0/24"
CT_IP="10.10.10.10"
GW_IP="10.10.10.1"

say() { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nSMOKE FAIL: %s\n' "$*" >&2; exit 1; }

# --- 1. Proxmox is itself healthy ------------------------------------------
say "1/4 Proxmox identity + API"
pveversion || fail "pveversion failed"
pvesh get /version --output-format json || fail "pvesh API unreachable"

# --- 2. Internal NAT bridge vmbr1 ------------------------------------------
# Canonical Proxmox homelab pattern: a port-less bridge that masquerades its
# subnet out through vmbr0. This is the seam that lets many containers share
# one flat network and one controlled exit, instead of per-service plumbing.
say "2/4 internal NAT bridge vmbr1"
if ! ip link show vmbr1 >/dev/null 2>&1; then
  cat >>/etc/network/interfaces <<EOF

auto vmbr1
iface vmbr1 inet static
        address ${BRIDGE_CIDR}
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up iptables -t nat -A POSTROUTING -s '${BRIDGE_NET}' -o vmbr0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '${BRIDGE_NET}' -o vmbr0 -j MASQUERADE
EOF
  ifreload -a
fi
ip -br addr show vmbr1 | grep -q "${GW_IP}" || fail "vmbr1 did not come up with ${GW_IP}"
echo "vmbr1 up: $(ip -br addr show vmbr1)"

# --- 3. Unprivileged LXC container -----------------------------------------
say "3/4 LXC lifecycle (download template, create, start)"
pveam update
# Pick the newest Alpine template dynamically -- robust against version drift.
TMPL_NAME="$(pveam available --section system | awk '/alpine/{print $2}' | sort -V | tail -1)"
[ -n "${TMPL_NAME}" ] || fail "no alpine template available from pveam"
echo "template: ${TMPL_NAME}"
pveam download local "${TMPL_NAME}"

# Static IP on vmbr1 (no DHCP server on the internal bridge); host is the gw.
# nameserver 1.1.1.1 so name resolution works through the NAT, though the
# connectivity probe below uses a bare IP to stay DNS-independent.
pct create "${VMID}" "local:vztmpl/${TMPL_NAME}" \
  --hostname smoke-ct \
  --cores 1 --memory 256 --swap 0 \
  --rootfs local-lvm:1 \
  --net0 "name=eth0,bridge=vmbr1,ip=${CT_IP}/24,gw=${GW_IP}" \
  --nameserver 1.1.1.1 \
  --unprivileged 1 \
  --features nesting=1 \
  || fail "pct create failed"
pct start "${VMID}" || fail "pct start failed"

# No `pct start --wait` exists; poll until the container reports running.
for _ in $(seq 1 30); do
  pct status "${VMID}" | grep -q running && break
  sleep 1
done
pct status "${VMID}" | grep -q running || fail "container ${VMID} never reached running"

# Poll until eth0 has its address inside the container.
for _ in $(seq 1 30); do
  pct exec "${VMID}" -- ip -4 addr show eth0 2>/dev/null | grep -q "${CT_IP}" && break
  sleep 1
done
pct exec "${VMID}" -- ip -4 addr show eth0 | grep -q "${CT_IP}" \
  || fail "container did not get ${CT_IP} on eth0"
echo "container networked:"
pct exec "${VMID}" -- ip -br addr show eth0

# --- 4. The network seam: container -> gateway, and -> internet via NAT -----
say "4/4 container connectivity (local gateway + NAT-out)"
# 4a. Local: container can reach the host on the internal bridge.
pct exec "${VMID}" -- ping -c2 -W2 "${GW_IP}" >/dev/null \
  || fail "container cannot reach its gateway ${GW_IP} on vmbr1"
echo "ok: container -> ${GW_IP} (vmbr1 local)"

# 4b. NAT-out: open a raw TCP connection to a bare internet IP. We probe TCP,
# NOT ICMP, because QEMU's slirp user-net drops outbound ping but forwards TCP.
# A bare connect (BusyBox `nc` to 1.1.1.1:53, Cloudflare DNS-over-TCP) proves
# the masquerade path end-to-end with NO dependency on DNS, TLS, or HTTP status
# semantics -- it succeeds iff a SYN/ACK comes back through the vmbr0 NAT.
pct exec "${VMID}" -- sh -c 'nc -w8 1.1.1.1 53 </dev/null' \
  || fail "container has no NAT-out internet via vmbr0 masquerade (TCP 1.1.1.1:53)"
echo "ok: container -> 1.1.1.1:53 TCP (NAT-out through vmbr0)"

# --- teardown (best-effort; CI throws the VM away anyway) -------------------
say "cleanup"
pct stop "${VMID}" >/dev/null 2>&1 || true
pct destroy "${VMID}" >/dev/null 2>&1 || true

printf '\nSMOKE PASS: Proxmox services-domain patterns validated.\n'
