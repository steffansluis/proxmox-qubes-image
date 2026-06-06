#!/usr/bin/env bash
# Hermetic connectivity test for the QubesDB-driven vmbr0 auto-networking script
# (qubes-vmbr0-netcfg, baked by scripts/qubes-provision.sh).
#
# WHY THIS EXISTS: the auto-net service is ConditionVirtualization=xen-gated, so
# the QEMU smoke test can only check that it GENERATES the right commands -- it
# can't prove those commands yield a WORKING network in the Qubes point-to-point
# /32 environment, because no Qubes/Xen backend exists on a CI runner. This test
# rebuilds that exact L2/L3 topology with veth + network namespaces (pure Linux,
# no Xen, no dom0) and actually PINGS across it. It caught the real bug it now
# guards against: setup-ip pins the gateway MAC to fe:ff:ff:ff:ff:ff (correct for
# a PV `vif`, where eth0 IS the vif), but on our HVM whose NIC is bridged into
# vmbr0 the gateway MAC must be ARP-resolved -- the static pin blackholes ALL
# gateway traffic (100% packet loss, observed on a live qube).
#
# SAFETY: every command runs INSIDE a namespace (`ip -n NS ...` / `ip netns exec
# NS ...`). Nothing touches the host's interfaces, routes, or /etc. Namespaces
# are torn down on EXIT, which removes all veths/bridges with them.
#
# Topology:
#   ns VM  [ vmbr0 (bridge) -- veth_vm ]====( veth_gw )-- ns GW (the netvm/gw)
#   The real qubes-vmbr0-netcfg runs in ns VM and configures vmbr0; ns GW owns
#   the gateway IP and a route back to the VM. Then ns VM pings the gateway.
#
# Run as root (namespaces need CAP_NET_ADMIN): `sudo scripts/test-netcfg-netns.sh`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVISION="${HERE}/qubes-provision.sh"

NS_VM=pqi-netcfg-vm
NS_GW=pqi-netcfg-gw
VM_IP=10.137.0.20
GW_IP=10.138.23.60
IFACE=vmbr0
NETCFG=""

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf '\nNETNS TEST FAIL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "must run as root (network namespaces need CAP_NET_ADMIN)"
[ -f "${PROVISION}" ] || fail "cannot find ${PROVISION}"

ns_cleanup() { # tear down only the namespaces (veths/bridges go with them)
  ip netns del "${NS_VM}" 2>/dev/null || true
  ip netns del "${NS_GW}" 2>/dev/null || true
  return 0
}
cleanup() { # full teardown for EXIT: namespaces AND the extracted temp script
  ns_cleanup
  [ -n "${NETCFG}" ] && rm -f "${NETCFG}"
  return 0  # never let cleanup's last test fail the script under set -e
}
trap cleanup EXIT
ns_cleanup  # clear any leftover namespaces from an interrupted prior run

# Extract the REAL netcfg script body from qubes-provision.sh (single source of
# truth) -- everything between the `cat >/usr/sbin/qubes-vmbr0-netcfg <<'NETCFG'`
# heredoc opener and its closing `NETCFG` line.
NETCFG="$(mktemp /tmp/qubes-vmbr0-netcfg.XXXXXX)"
awk "/^cat >\/usr\/sbin\/qubes-vmbr0-netcfg <<'NETCFG'$/{f=1;next} f&&/^NETCFG$/{f=0} f" \
  "${PROVISION}" >"${NETCFG}"
[ -s "${NETCFG}" ] || fail "could not extract qubes-vmbr0-netcfg body from ${PROVISION}"
chmod +x "${NETCFG}"
echo "extracted $(wc -l <"${NETCFG}") lines of the real qubes-vmbr0-netcfg"

# --- build the namespaced topology -----------------------------------------
build_topology() {
  ns_cleanup
  ip netns add "${NS_VM}"
  ip netns add "${NS_GW}"
  # veth pair with each end created directly inside its namespace.
  ip link add veth_vm netns "${NS_VM}" type veth peer name veth_gw netns "${NS_GW}"
  # VM side: a bridge named vmbr0 (as on Proxmox) with the veth enslaved to it,
  # mirroring the real box where the NIC is a bridge-port of vmbr0.
  ip -n "${NS_VM}" link add "${IFACE}" type bridge
  ip -n "${NS_VM}" link set veth_vm master "${IFACE}"
  ip -n "${NS_VM}" link set lo up
  ip -n "${NS_VM}" link set veth_vm up
  ip -n "${NS_VM}" link set "${IFACE}" up
  # Gateway side: owns GW_IP and routes back to the VM's /32 on-link (a netvm).
  ip -n "${NS_GW}" link set lo up
  ip -n "${NS_GW}" link set veth_gw up
  ip -n "${NS_GW}" addr add "${GW_IP}/32" dev veth_gw
  ip -n "${NS_GW}" route add "${VM_IP}" dev veth_gw scope link
}

# Run the real netcfg inside the VM namespace (NON-dry-run so it issues the
# actual ip commands). DNS unset so it skips the resolv.conf write (which would
# be the namespace's own /etc anyway, but we keep the test purely about routing).
apply_netcfg() {
  ip netns exec "${NS_VM}" env -i PATH="$PATH" \
    IFACE="${IFACE}" IP="${VM_IP}" GW="${GW_IP}" DNS1="" DNS2="" \
    sh "${NETCFG}"
}

ping_gw() { # <count>
  ip netns exec "${NS_VM}" ping -c"${1:-2}" -W2 "${GW_IP}" >/dev/null 2>&1
}

# --- CASE 1: the real (fixed) script must give working connectivity ---------
say_case() { printf '\n##### %s #####\n' "$*"; }
say_case "CASE 1: real qubes-vmbr0-netcfg -> gateway must be reachable"
build_topology
apply_netcfg
ip netns exec "${NS_VM}" ip -4 addr show "${IFACE}" | sed -n 's/^/  /;/inet/p'
ip netns exec "${NS_VM}" ip route | sed 's/^/  route: /'
# Allow a couple of attempts for ARP/bridge fdb to settle.
ok=""
for _ in 1 2 3; do ping_gw 2 && { ok=1; break; }; sleep 1; done
[ -n "${ok}" ] || fail "real script: gateway ${GW_IP} unreachable (the auto-net config does not actually work)"
pass "real qubes-vmbr0-netcfg yields a working route to the gateway (0% loss)"
# And prove ARP actually resolved the gateway's real MAC (not a pinned one).
ip netns exec "${NS_VM}" ip neigh show "${GW_IP}" dev "${IFACE}" | grep -qi 'lladdr' \
  || fail "gateway neighbour never resolved -- unexpected"
ip netns exec "${NS_VM}" ip neigh show "${GW_IP}" dev "${IFACE}" | grep -qi 'fe:ff:ff:ff:ff:ff' \
  && fail "gateway MAC resolved to the vif placeholder fe:ff:ff:ff:ff:ff -- script pinned it"
pass "gateway MAC was ARP-resolved to its real address (no fe:ff:ff:ff:ff:ff pin)"

# --- CASE 2: the regression we guard against MUST break connectivity --------
# Re-applies the working config, then injects the exact static neigh entry the
# old script emitted. If connectivity SURVIVES this, the test has no discriminating
# power and would silently pass even with the bug -- so we require it to FAIL.
say_case "CASE 2: with the fe:ff:ff:ff:ff:ff neigh pin -> gateway must be UNREACHABLE"
build_topology
apply_netcfg
ip netns exec "${NS_VM}" ip neigh replace "${GW_IP}" dev "${IFACE}" \
  lladdr fe:ff:ff:ff:ff:ff nud permanent
ip netns exec "${NS_VM}" ip neigh show "${GW_IP}" dev "${IFACE}" | sed 's/^/  /'
if ping_gw 2; then
  fail "gateway still reachable WITH the bad neigh pin -- test cannot detect the bug, methodology is invalid"
fi
pass "the fe:ff:ff:ff:ff:ff pin blackholes gateway traffic as expected (test has discriminating power)"

printf '\nNETNS TEST PASS: auto-net routing works AND the bug it guards against is detectable.\n'
