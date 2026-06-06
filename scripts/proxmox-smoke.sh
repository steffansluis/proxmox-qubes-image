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
# FIRST: the vmbr0 uplink must actually exist and be enslaved. The image hardcodes
# `bridge-ports eth0` (after the net.ifnames=0 fix); if that NIC name is wrong for
# the hypervisor, vmbr0 has NO port -> no uplink -> total connectivity loss (the
# enp0s2-vs-enX0 bug that broke the real Qubes qube while CI stayed green). Assert
# vmbr0 has at least one real (non-virtual) enslaved port AND that eth0 is present.
say "2a/5 vmbr0 has a real enslaved uplink (eth0)"
BRIF="$(ls /sys/class/net/vmbr0/brif/ 2>/dev/null || true)"
[ -n "${BRIF}" ] || fail "vmbr0 has NO bridge ports -- uplink missing (bridge-ports name wrong for this hypervisor?)"
echo "vmbr0 ports: ${BRIF}"
ls /sys/class/net/eth0 >/dev/null 2>&1 \
  || fail "no eth0 present -- net.ifnames=0 did not take effect; bridge-ports eth0 would be dangling"
ls /sys/class/net/vmbr0/brif/eth0 >/dev/null 2>&1 \
  || fail "eth0 exists but is NOT enslaved to vmbr0 -- uplink not bridged"
echo "ok: eth0 enslaved to vmbr0 (uplink present)"
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

  # 5f. The app-menu shortcut exists and is valid (qvm-sync-appmenus will see it),
  # and it points at the SELF-HEALING wrapper -- not Chromium directly. The wrapper
  # purges stale caches and waits for :8006 before opening the window, defusing the
  # white-page (stale poisoned bundle) and startup-race failures seen on the live
  # qube. We assert: (i) the .desktop is valid and Exec=the wrapper; (ii) the
  # wrapper exists, is executable, parses as POSIX sh; (iii) it carries the load-
  # bearing Chromium flags (--no-sandbox, --user-data-dir), the cache-purge, and
  # the readiness wait; (iv) the no-op --ignore-certificate-errors hasn't returned.
  DESKTOP=/usr/share/applications/proxmox-web-gui.desktop
  [ -f "${DESKTOP}" ] || fail "missing ${DESKTOP}"
  desktop-file-validate "${DESKTOP}" \
    || fail "proxmox-web-gui.desktop is not a valid desktop entry"
  LAUNCHER=/usr/bin/proxmox-web-gui
  grep -Eq "^Exec=${LAUNCHER}( |\$)" "${DESKTOP}" \
    || fail ".desktop Exec does not invoke ${LAUNCHER} -- shortcut bypasses the self-healing wrapper"
  [ -x "${LAUNCHER}" ] || fail "missing/!executable ${LAUNCHER} (self-healing web-UI launcher)"
  sh -n "${LAUNCHER}" || fail "${LAUNCHER} is not valid POSIX sh"
  grep -q -- '--no-sandbox' "${LAUNCHER}" \
    || fail "${LAUNCHER} missing --no-sandbox -- Chromium refuses to run as root, window never opens"
  grep -q -- '--user-data-dir=' "${LAUNCHER}" \
    || fail "${LAUNCHER} missing --user-data-dir -- singleton/stale-cache wedge (white-page risk)"
  grep -Eq 'rm -rf .*Cache|rm -rf .*CACHE' "${LAUNCHER}" \
    || fail "${LAUNCHER} does not purge stale caches -- a poisoned bundle would persist (white page)"
  grep -Eq 'http_code|401|200' "${LAUNCHER}" && grep -q 'sleep' "${LAUNCHER}" \
    || fail "${LAUNCHER} has no readiness wait for :8006 -- the boot race could cache an error (white page)"
  grep -q -- '--ignore-certificate-errors' "${LAUNCHER}" \
    && fail "${LAUNCHER} still passes --ignore-certificate-errors -- no-op in --app mode, remove it"
  echo "ok: 'Proxmox Web GUI' .desktop -> self-healing wrapper (cache-purge + :8006 readiness wait)"

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

  # 5h. The Proxmox identity is pinned against the Qubes agent's boot-time
  # rename. Under real Xen qubes-early-vm-config.sh renames the host to the qube
  # name unless /etc/hostname is a Qubes "protected file"; a renamed, unresolvable
  # hostname makes pmxcfs (pve-cluster) refuse to start -> /etc/pve unmounted ->
  # pveproxy has no TLS cert -> the web UI blackholes (curl 000 / ERR_TIMED_OUT),
  # with pve-firewall/guests/ha-*/scheduler/statd all cascading. We can't trigger
  # the rename under QEMU (no qubesdb /name), so assert (i) the protected-files
  # entry exists and the Qubes helper agrees it protects /etc/hostname -- proving
  # the agent WILL skip the rename under Xen -- and (ii) the PVE web stack is
  # actually healthy on THIS (un-renamed) boot, a baseline regression guard for
  # the whole pmxcfs -> cert -> pveproxy path.
  PROTCONF=/etc/qubes/protected-files.d/30-keep-proxmox-identity.conf
  [ -f "${PROTCONF}" ] || fail "missing ${PROTCONF} -- host would be renamed under Xen, breaking pmxcfs"
  grep -Fxq '/etc/hostname' "${PROTCONF}" \
    || fail "${PROTCONF} does not list /etc/hostname exactly -- protection won't match"
  QFUNCS=/usr/lib/qubes/init/functions
  if [ -r "${QFUNCS}" ]; then
    ( . "${QFUNCS}"; is_protected_file /etc/hostname ) \
      || fail "is_protected_file /etc/hostname is false -- Qubes agent would still rename host under Xen"
    echo "ok: /etc/hostname is a Qubes protected file (agent skips the rename under Xen)"
  fi
  # 5h'. cron must actually run. qubes-core-agent gates cron.service on
  # ConditionPathExists=/var/run/qubes-service/crond -- a flag that never exists
  # in this image (no networking agent / dom0 qvm-service), so without our
  # condition-clearing drop-in cron silently never starts, killing Proxmox vzdump
  # backups, e2scrub, ZFS maintenance and Debian's logrotate/apt-compat/man-db.
  # Under THIS QEMU boot the flag is likewise absent, so an un-fixed image would
  # show cron inactive here -- making this a real regression guard.
  CRONDROP=/etc/systemd/system/cron.service.d/40-proxmox-force-cron.conf
  [ -f "${CRONDROP}" ] || fail "missing ${CRONDROP} -- cron would stay gated off by the Qubes crond condition"
  if systemctl cat cron.service >/dev/null 2>&1; then
    [ "$(systemctl is-active cron 2>/dev/null)" = "active" ] \
      || fail "cron.service not active -- Qubes crond gate not cleared (vzdump/logrotate would never run)"
    echo "ok: cron.service active (Qubes crond gate cleared)"
  fi
  # anacron shares the same crond gate but is timer-driven (is-active is unreliable),
  # so assert its gate-clearing drop-in exists instead.
  if systemctl cat anacron.service >/dev/null 2>&1; then
    [ -f /etc/systemd/system/anacron.service.d/40-proxmox-force-anacron.conf ] \
      || fail "missing anacron crond-gate drop-in -- anacron stays gated off"
    echo "ok: anacron crond gate cleared (drop-in present)"
  fi

  # 5h''. SELF-DISCOVERING qubes-service-gate audit. cron was found reactively;
  # this generalizes it so an UNKNOWN gate on a Proxmox-needed service fails CI
  # instead of silently disabling a service on the live qube. We enumerate every
  # systemd drop-in qubes-core-agent baked under <unit>.d/ that gates a unit on
  # /var/run/qubes-service/<flag>, and for each unit on our Proxmox MUST-RUN list
  # assert it is actually active on this (flag-less) QEMU boot -- i.e. its gate has
  # been cleared. Units NOT on the must-run list are reported for visibility only
  # (e.g. cups/firewalld/NetworkManager, which Proxmox doesn't want running).
  echo "qubes-service gate audit:"
  # Proxmox needs these running regardless of any Qubes flag. Time sync is covered
  # separately (chrony.service drop-in is empty + qubes-sync-time.timer); included
  # here only if a gate is detected on it.
  # anacron is intentionally NOT here: it's timer-triggered and exits, so is-active
  # is an unreliable signal -- its gate-clearing drop-in is asserted separately below.
  MUSTRUN=" cron postfix rsyslog ssh sshd pveproxy pvedaemon pve-cluster "
  gate_audit_ok=1
  seen=" "   # dedupe: /lib is usually a symlink to /usr/lib -> same unit twice
  # -L so the symlinked tree is walked once; we dedupe by unit name anyway.
  for ddir in /usr/lib/systemd/system/*.d /etc/systemd/system/*.d; do
    [ -d "${ddir}" ] || continue
    # Does any drop-in here gate on a qubes-service flag?
    if grep -rslq 'ConditionPathExists=.*qubes-service' "${ddir}" 2>/dev/null; then
      unit="$(basename "${ddir}" .d)"
      case "${seen}" in *" ${unit} "*) continue ;; esac
      seen="${seen}${unit} "
      flag="$(grep -rho 'ConditionPathExists=[!|]*/\(var/\)\?run/qubes-service/[^ ]*' "${ddir}" 2>/dev/null \
              | head -n1 | sed 's#.*/qubes-service/##')"
      base="${unit%.*}"   # strip .service/.socket/.path
      base="${base%@*}"   # normalize templated units (getty@.service -> getty)
      case " ${MUSTRUN} " in
        *" ${base} "*)
          if systemctl cat "${unit}" >/dev/null 2>&1; then
            if [ "$(systemctl is-active "${unit}" 2>/dev/null)" = "active" ]; then
              echo "  ok ${unit}: gated on '${flag}' but ACTIVE (gate cleared)"
            else
              echo "  FAIL ${unit}: gated on qubes-service '${flag}' and NOT active -- Proxmox needs it; clear the gate"
              gate_audit_ok=0
            fi
          fi ;;
        *)
          echo "  info ${unit}: gated on qubes-service '${flag}' (not on Proxmox must-run list; left gated)" ;;
      esac
    fi
  done
  [ "${gate_audit_ok}" = "1" ] \
    || fail "a Proxmox-required service is still gated off by a Qubes qubes-service flag (see FAIL lines above)"
  echo "ok: no Proxmox-required service left gated by a qubes-service flag"

  # 5h'''. The Qubes apt updates-proxy must NOT be configured -- this image does
  # direct internet over vmbr0 and has no :8082 forwarder, so a baked proxy would
  # hang every apt/Proxmox package operation. qubes-provision.sh removes it; assert.
  [ ! -e /etc/apt/apt.conf.d/01qubes-proxy ] \
    || fail "/etc/apt/apt.conf.d/01qubes-proxy present -- apt would route through the dead Qubes updates proxy"
  if grep -rIls '127\.0\.0\.1:8082\|10\.137\.255\.254:8082' /etc/apt/apt.conf.d/ 2>/dev/null | grep -q .; then
    fail "an apt.conf.d file references the Qubes updates proxy (:8082) -- apt would fail with direct networking"
  fi
  echo "ok: no Qubes apt updates-proxy config (apt uses direct vmbr0 networking)"

  # The PVE cluster fs must be up and the web server must answer TLS on loopback.
  [ "$(systemctl is-active pve-cluster 2>/dev/null)" = "active" ] \
    || fail "pve-cluster (pmxcfs) not active -- /etc/pve won't mount, web UI cert missing"
  HTTP_CODE="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' https://127.0.0.1:8006 2>/dev/null || true)"
  case "${HTTP_CODE}" in
    200|401)
      echo "ok: pveproxy answers TLS on 127.0.0.1:8006 (HTTP ${HTTP_CODE}); web UI reachable" ;;
    000|"")
      fail "pveproxy TLS handshake blackholed on 127.0.0.1:8006 (curl=${HTTP_CODE:-empty}) -- this is the ERR_TIMED_OUT failure" ;;
    *)
      echo "ok: pveproxy answers on 127.0.0.1:8006 (HTTP ${HTTP_CODE})" ;;
  esac

  # 5h3. The web UI must actually RENDER, not just answer on /. A blank/white page
  # with a 500 on /PVE/StdWorkspace.js is ExtJS's class-loader fallback firing
  # because an earlier JS bundle (pvemanagerlib.js / proxmoxlib.js) failed to
  # load or was served truncated. The previous check only fetched index.html and
  # would PASS on a white-page install. Fetch the real bundles the page <script>s
  # and assert each serves 200, a JavaScript content-type, and a non-trivial size
  # -- the regression guard for "UI loads blank". Also assert the loader-fallback
  # path is NOT how StdWorkspace is served (a healthy prod build bundles it).
  ui_ok=1
  for spec in \
    "/pve2/js/pvemanagerlib.js:1000000" \
    "/proxmoxlib.js:300000" \
    "/pve2/ext6/ext-all.js:500000"; do
    url="${spec%%:*}"; min="${spec##*:}"
    read -r code ctype size <<EOF2
$(curl -sk --max-time 20 -o /dev/null -w '%{http_code} %{content_type} %{size_download}' "https://127.0.0.1:8006${url}" 2>/dev/null || echo "000 - 0")
EOF2
    if [ "${code}" != "200" ]; then
      echo "  FAIL ${url}: HTTP ${code} (expected 200)"; ui_ok=0; continue
    fi
    case "${ctype}" in
      *javascript*|*ecmascript*) : ;;
      *) echo "  FAIL ${url}: content-type '${ctype}' is not JavaScript"; ui_ok=0; continue ;;
    esac
    if [ "${size:-0}" -lt "${min}" ]; then
      echo "  FAIL ${url}: ${size}B < ${min}B (truncated bundle -> white page)"; ui_ok=0; continue
    fi
    echo "  ok ${url}: HTTP 200, ${ctype}, ${size}B"
  done
  [ "${ui_ok}" = "1" ] \
    || fail "web UI JS bundles did not serve cleanly -- the page would render BLANK (StdWorkspace.js 500 class of bug)"
  # The class PVE.StdWorkspace must live INSIDE pvemanagerlib.js (prod bundle), so
  # the browser never falls back to GET /PVE/StdWorkspace.js. Verify it's bundled.
  curl -sk --max-time 20 "https://127.0.0.1:8006/pve2/js/pvemanagerlib.js" 2>/dev/null \
    | grep -q "PVE.StdWorkspace" \
    || fail "pvemanagerlib.js does not define PVE.StdWorkspace -- browser would 500 on /PVE/StdWorkspace.js (white page)"
  echo "ok: web UI bundles serve cleanly and PVE.StdWorkspace is bundled (no white-page fallback)"

  # 5h4. END-TO-END RENDER: actually load the page in the SAME Chromium that ships
  # in the image (148, baked for the launcher) and prove ExtJS builds the real UI
  # instead of a blank <body>. The HTTP/bundle checks above prove the server side;
  # this proves the client side -- it is the only check that reproduces the user's
  # white-page symptom (a runtime JS exception serves fine over HTTP but renders
  # nothing). --dump-dom prints the DOM *after* scripts run, so a white page yields
  # an empty body and a healthy page yields ExtJS-generated markup + login text.
  # If this passes in CI but the user still sees a white page on the live Xen qube,
  # that itself localizes the bug to the runtime environment (e.g. hostname/pmxcfs
  # state) rather than the baked image. Best-effort on tooling, hard on the verdict.
  CHROME="$(command -v chromium || command -v chromium-browser || true)"
  if [ -n "${CHROME}" ]; then
    RDOM=/tmp/pve-render-dom.html
    # --virtual-time-budget lets ExtJS finish its async class load + layout before
    # the DOM is serialized; --ignore-certificate-errors is honoured in headless
    # (unlike --app mode) so the self-signed cert doesn't abort the navigation.
    timeout 60 "${CHROME}" --headless=new --no-sandbox --disable-gpu \
      --disable-dev-shm-usage --ignore-certificate-errors \
      --virtual-time-budget=20000 \
      --user-data-dir=/tmp/pve-render-profile \
      --dump-dom "https://127.0.0.1:8006" >"${RDOM}" 2>/tmp/pve-render.log || true
    dom_bytes=$(wc -c <"${RDOM}" 2>/dev/null || echo 0)
    # A rendered PVE login page contains the product string and ExtJS form markup.
    # A white page is a near-empty <body> with none of these.
    if grep -qiE 'Proxmox VE Login|pve-login|x-form-item|Ext\.' "${RDOM}" 2>/dev/null; then
      echo "ok: headless Chromium rendered the PVE UI (${dom_bytes}B DOM, login markup present)"
    else
      echo "---- rendered DOM (first 60 lines) ----"; head -n 60 "${RDOM}" 2>/dev/null || true
      echo "---- chromium stderr (last 40 lines) ----"; tail -n 40 /tmp/pve-render.log 2>/dev/null || true
      fail "headless Chromium produced a BLANK page (${dom_bytes}B DOM, no PVE login markup) -- reproduces the white-page bug in CI"
    fi
  else
    echo "warn: no chromium binary in smoke env -- skipped end-to-end render check"
  fi
fi

# Teardown is handled by the EXIT trap (cleanup) so it runs on pass, fail, or
# interrupt, and restores a persistent box to its original state.
printf '\nSMOKE PASS: Proxmox services-domain + Qubes integration validated.\n'
