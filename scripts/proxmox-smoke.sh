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
#   5. The baked-in Qubes guest integration is     (qrexec + GUI agent + the
#      present and boot-safe                         "Proxmox Web GUI" shortcut)
#
# Stages 1-4 also serve as a regression check that baking the Qubes agents in
# (scripts/qubes-provision.sh) did NOT break Proxmox or its networking. Stage 5
# is skipped automatically on a not-yet-provisioned image so this script still
# works standalone.
#
# Exits non-zero on the first failed assertion so CI can gate the GHCR push.
# Dependency-light: only stock PVE tooling + busybox in the Alpine guest.
set -euo pipefail

VMID=900
BRIDGE_CIDR="10.10.10.1/24"
BRIDGE_NET="10.10.10.0/24"
CT_IP="10.10.10.10"
GW_IP="10.10.10.1"
IFACES=/etc/network/interfaces

say() { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nSMOKE FAIL: %s\n' "$*" >&2; exit 1; }

# --- teardown ---------------------------------------------------------------
# In CI the qcow2 overlay is thrown away, so cleanup is cosmetic. But this
# script is also meant to run against a REAL, persistent Proxmox qube (booted
# under Xen in dom0), where it must leave the box exactly as it found it and be
# safely re-runnable. So: snapshot the bits we mutate and restore them on EXIT,
# whether we pass, fail, or get interrupted. Set SMOKE_KEEP=1 to leave the
# vmbr1 bridge + container in place for manual inspection.
IFACES_BAK=""              # set once we've taken a backup
TMPL_PREEXISTED=""         # "1" if the template was already downloaded
cleanup() {
  rc=$?
  if [ -n "${SMOKE_KEEP:-}" ]; then
    printf '\n(SMOKE_KEEP set -- leaving vmbr1 + container in place)\n'
    exit "$rc"
  fi
  say "cleanup"
  pct stop "${VMID}"    >/dev/null 2>&1 || true
  pct destroy "${VMID}" >/dev/null 2>&1 || true
  # Restore the network config exactly, then re-apply so vmbr1 is torn down.
  if [ -n "${IFACES_BAK}" ] && [ -f "${IFACES_BAK}" ]; then
    cp -a "${IFACES_BAK}" "${IFACES}" && rm -f "${IFACES_BAK}"
    ifreload -a >/dev/null 2>&1 || true
  fi
  # Drop the template only if WE fetched it (don't evict a pre-existing cache).
  if [ -z "${TMPL_PREEXISTED}" ] && [ -n "${TMPL_NAME:-}" ]; then
    pveam remove "local:vztmpl/${TMPL_NAME}" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

# --- 1. Proxmox is itself healthy ------------------------------------------
say "1/5 Proxmox identity + API"
pveversion || fail "pveversion failed"
pvesh get /version --output-format json || fail "pvesh API unreachable"

# --- 2. Internal NAT bridge vmbr1 ------------------------------------------
# Canonical Proxmox homelab pattern: a port-less bridge that masquerades its
# subnet out through vmbr0. This is the seam that lets many containers share
# one flat network and one controlled exit, instead of per-service plumbing.
say "2/5 internal NAT bridge vmbr1"
# Snapshot interfaces before touching it so the EXIT trap can restore exactly.
IFACES_BAK="$(mktemp)"
cp -a "${IFACES}" "${IFACES_BAK}"
if ! ip link show vmbr1 >/dev/null 2>&1; then
  cat >>"${IFACES}" <<EOF

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
say "3/5 LXC lifecycle (download template, create, start)"
pveam update
# Pick the newest Alpine template dynamically -- robust against version drift.
TMPL_NAME="$(pveam available --section system | awk '/alpine/{print $2}' | sort -V | tail -1)"
[ -n "${TMPL_NAME}" ] || fail "no alpine template available from pveam"
echo "template: ${TMPL_NAME}"
# Note whether this template is already cached, so cleanup only evicts what we
# fetched (avoids thrashing a pre-warmed cache on a real, persistent box).
pveam list local 2>/dev/null | grep -q "${TMPL_NAME}" && TMPL_PREEXISTED=1
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
# Plain `ip addr` (no -br): the container's BusyBox ip lacks the -br/brief flag
# that full iproute2 on the host has, and would print a usage error + exit 1.
pct exec "${VMID}" -- ip addr show eth0

# --- 4. The network seam: container -> gateway, and -> internet via NAT -----
say "4/5 container connectivity (local gateway + NAT-out)"
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

# --- 5. Baked-in Qubes guest integration -----------------------------------
# Verifies scripts/qubes-provision.sh did its job: the guest agents are present,
# the boot-blocking units are masked (so the image boots under Xen AND here),
# the networking agent was kept OUT (it would fight Proxmox vmbr0), and the
# "Proxmox Web GUI" app-menu shortcut is valid. Skipped on an unprovisioned
# image so this script still passes when run standalone against a bare build.
say "5/5 baked-in Qubes guest integration"
if [ ! -f /var/lib/qubes-provision.done ]; then
  echo "skip: image not provisioned with Qubes agents (no marker) -- ok standalone"
else
  # 5a. The agents we want are installed...
  for pkg in qubes-core-agent qubes-gui-agent; do
    dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii' \
      || fail "expected package ${pkg} not installed"
  done
  echo "ok: qubes-core-agent + qubes-gui-agent installed"

  # 5b. ...and the networking agent we deliberately excluded is NOT.
  if dpkg -l qubes-core-agent-networking 2>/dev/null | grep -q '^ii'; then
    fail "qubes-core-agent-networking present -- it would fight Proxmox vmbr0"
  fi
  echo "ok: qubes-core-agent-networking correctly absent"

  # 5c. The wrong-disk-layout units are masked (symlinked to /dev/null), so the
  # image reaches login on a non-Qubes disk layout -- this VERY boot proves it.
  for unit in qubes-rootfs-resize.service qubes-mount-dirs.service; do
    [ "$(systemctl is-enabled "${unit}" 2>/dev/null)" = "masked" ] \
      || fail "${unit} is not masked -- it will hang boot on vda/sda layout"
  done
  echo "ok: rootfs-resize + mount-dirs masked (and we booted fine)"

  # 5d. The Xen-only early units are GATED (not masked): a drop-in adds
  # ConditionVirtualization=xen so they skip under QEMU but run under real Xen.
  # qubes-sysinit busy-waits forever on /dev/xen/xenbus ordered Before=sysinit
  # .target, so without this gate boot wedges -- that we got here proves it skips.
  for unit in qubes-sysinit.service qubes-early-vm-config.service; do
    DROPIN="/etc/systemd/system/${unit}.d/10-skip-without-xen.conf"
    [ -f "${DROPIN}" ] \
      || fail "${unit} missing Xen-gate drop-in ${DROPIN} -- boot would hang off Xen"
    grep -q 'ConditionVirtualization=xen' "${DROPIN}" \
      || fail "${DROPIN} does not gate on ConditionVirtualization=xen"
    # Under this QEMU boot (no Xen) the condition must NOT be met -> inactive.
    [ "$(systemctl is-active "${unit}" 2>/dev/null)" != "active" ] \
      || fail "${unit} is active under QEMU -- Xen gate failed, would have hung"
  done
  echo "ok: qubes-sysinit + early-vm-config gated to Xen (skipped here)"

  # 5e. virtio_blk must be reachable for the QEMU virtio root -- built into the
  # Proxmox kernel (CONFIG_VIRTIO_BLK=y) OR in the initramfs. The PVE kernel
  # builds it in, so it won't show in lsinitramfs; accept either. (We're running
  # off virtio right now, so this is really a regression tripwire.)
  KVER="$(uname -r)"
  vblk_builtin=""; vblk_initrd=""
  [ -f "/boot/config-${KVER}" ] && grep -q '^CONFIG_VIRTIO_BLK=y' "/boot/config-${KVER}" \
    && vblk_builtin=1
  INITRD="/boot/initrd.img-${KVER}"
  if [ -f "${INITRD}" ] && command -v lsinitramfs >/dev/null 2>&1; then
    lsinitramfs "${INITRD}" | grep -q 'virtio_blk' && vblk_initrd=1
  fi
  [ -n "${vblk_builtin}" ] || [ -n "${vblk_initrd}" ] \
    || fail "virtio_blk neither built into kernel ${KVER} nor in its initramfs"
  echo "ok: virtio_blk reachable (builtin=${vblk_builtin:-0} initramfs=${vblk_initrd:-0})"

  # 5e'. The Qubes COW boot script must be ABSENT from the initramfs. It runs
  # `gptfix fix /dev/xvda` and `die`s when that device is missing, dropping to a
  # BusyBox (initramfs) shell before systemd starts -- the real boot-blocker the
  # serial log exposed. This image boots its own pve-root, not the Qubes dmroot/
  # xvda COW scheme, so qubes-provision.sh strips it. Reaching this assertion at
  # all proves it's gone (we booted past initramfs), but verify explicitly too.
  if [ -f "${INITRD}" ] && command -v lsinitramfs >/dev/null 2>&1; then
    lsinitramfs "${INITRD}" | grep -q 'local-top/qubes_cow_setup' \
      && fail "qubes_cow_setup present in initramfs -- gptfix would wedge boot to (initramfs)"
    echo "ok: qubes_cow_setup absent from initramfs (no gptfix/xvda boot wedge)"
  fi

  # 5f. The app-menu shortcut exists and is valid (qvm-sync-appmenus will see it).
  DESKTOP=/usr/share/applications/proxmox-web-gui.desktop
  [ -f "${DESKTOP}" ] || fail "missing ${DESKTOP}"
  desktop-file-validate "${DESKTOP}" \
    || fail "proxmox-web-gui.desktop is not a valid desktop entry"
  echo "ok: 'Proxmox Web GUI' .desktop present and valid"

  # 5g. QubesDB-driven vmbr0 auto-networking is installed, Xen-gated, and its
  # generator emits the canonical Qubes /32 route commands. The service itself
  # must be INACTIVE here (no Xen) -- proving it never touches the vmbr0 that
  # stages 2-4 exercised. We can't read real QubesDB under QEMU, so we re-run the
  # generator in DRY_RUN with injected values and assert the setup-ip-equivalent
  # output (same self-test qubes-provision.sh runs at bake, re-checked here).
  # In /usr/sbin, not /usr/local/sbin: qubes-core-agent bind-mounts /usr/local
  # from persistent /rw/usrlocal, which would shadow a baked-in /usr/local file
  # by the next boot. /usr/sbin is on the immutable root.
  NETCFG=/usr/sbin/qubes-vmbr0-netcfg
  [ -x "${NETCFG}" ] || fail "missing ${NETCFG} (vmbr0 auto-net generator)"
  UNITFILE=/etc/systemd/system/qubes-vmbr0-netcfg.service
  [ -f "${UNITFILE}" ] || fail "missing ${UNITFILE}"
  grep -q 'ConditionVirtualization=xen' "${UNITFILE}" \
    || fail "qubes-vmbr0-netcfg.service is not gated on ConditionVirtualization=xen"
  [ "$(systemctl is-enabled qubes-vmbr0-netcfg.service 2>/dev/null)" = "enabled" ] \
    || fail "qubes-vmbr0-netcfg.service not enabled (won't auto-net under Xen)"
  # Under this QEMU boot (no Xen) the condition must NOT be met -> not active.
  [ "$(systemctl is-active qubes-vmbr0-netcfg.service 2>/dev/null)" != "active" ] \
    || fail "qubes-vmbr0-netcfg.service active under QEMU -- Xen gate failed, would maul vmbr0"
  NETCFG_OUT="$(QUBES_NETCFG_DRY_RUN=1 IP=10.137.0.99 GW=10.138.23.60 \
    DNS1=10.139.1.1 DNS2=10.139.1.2 "${NETCFG}" 2>&1)" \
    || fail "qubes-vmbr0-netcfg dry-run exited non-zero"
  for expect in \
    '+ ip addr add 10.137.0.99/32 dev vmbr0' \
    '+ ip route replace to unicast 10.138.23.60 dev vmbr0 scope link' \
    '+ ip route replace to unicast default via 10.138.23.60 dev vmbr0 onlink'; do
    printf '%s\n' "${NETCFG_OUT}" | grep -qF "${expect}" \
      || fail "qubes-vmbr0-netcfg dry-run missing expected command: ${expect}"
  done
  # Regression guard: must NOT pin the gateway MAC. setup-ip does this for a PV
  # vif, but on our bridged HVM it blackholes all gateway traffic (100% loss).
  printf '%s\n' "${NETCFG_OUT}" | grep -q 'ip neigh' \
    && fail "qubes-vmbr0-netcfg emits 'ip neigh' -- pins gateway MAC, blackholes bridged-HVM traffic"
  # And with NO IP it must be a clean no-op (qube without a netvm). Empty IP=""
  # falls through to qubesdb-read, which returns nothing under QEMU (no daemon).
  QUBES_NETCFG_DRY_RUN=1 IP="" GW="" DNS1="" DNS2="" "${NETCFG}" 2>&1 \
    | grep -q 'no /qubes-ip' \
    || fail "qubes-vmbr0-netcfg did not no-op cleanly when no IP is assigned"
  echo "ok: vmbr0 auto-net installed, Xen-gated (inactive here), generator validated"
fi

# Teardown is handled by the EXIT trap (cleanup) so it runs on pass, fail, or
# interrupt, and restores a persistent box to its original state.
printf '\nSMOKE PASS: Proxmox services-domain + Qubes integration validated.\n'
