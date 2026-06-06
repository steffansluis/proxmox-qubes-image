#!/usr/bin/env bash
# Bake Qubes guest integration INTO the Proxmox VE image. Runs as root inside
# the freshly built image during a CI provision boot (copied + executed by
# scripts/provision.sh) so the changes persist into the PUBLISHED qcow2 -- the
# user then imports an image that already boots as a fully integrated Qubes
# StandaloneVM (qrexec, GUI agent, app-menu shortcut) with NO post-import steps.
#
# Design constraints (all verified against the live r4.3 repo, 2026-06-05):
#   * Install the GUI + qrexec agents but NOT qubes-core-agent-networking --
#     under real Xen it rewrites networking the Qubes /32 way and fights the
#     Proxmox vmbr0 + ifupdown2 static setup. qrexec + GUI work over vchan,
#     independent of networking. core-agent *Recommends* the networking pkg, so
#     --no-install-recommends is mandatory, not just tidy.
#   * Make boot Xen-OPTIONAL so the image comes up under BOTH real Xen and plain
#     QEMU (the CI smoke test has no Xen backend). Two distinct boot-blockers:
#       - Wrong-layout units -> MASK. qubes-rootfs-resize/qubes-mount-dirs/
#         dev-xvdc1-swap wait on Qubes split-disk names (xvda/xvdb/xvdc) that
#         never exist on this single-qcow2 image, even under Xen.
#       - Xen-needing units -> GATE the WHOLE set with ConditionVirtualization
#         =xen drop-ins (qubes-sysinit, qubes-early-vm-config, qubes-db,
#         qubes-qrexec-agent, qubes-misc-post, qubes-meminfo-writer,
#         qubes-updates-proxy-forwarder). qubes-sysinit busy-waits FOREVER on
#         /dev/xen/xenbus and qubes-db (Type=notify) never signals readiness
#         without a backend; several order Before=sysinit.target, so off-Xen they
#         wedge or cascade-fail boot. The gate runs them all under Qubes (a domU
#         IS a Xen guest) but skips them cleanly under QEMU. The packages stay
#         installed and the gate self-lifts under Xen, so the integration is
#         fully preserved -- nothing is lost by gating vs leaving enabled.
#   * Initramfs: the Proxmox kernel builds virtio in (CONFIG_VIRTIO_BLK=y), so
#     the virtio root is always reachable; we still restore MODULES=most (which
#     qubes-kernel-vm-support flips to dep) as portability insurance and guard
#     that virtio_blk is reachable built-in OR via the initramfs.
#
# Idempotent: safe to re-run. Writes /var/lib/qubes-provision.done on success.
set -euo pipefail

MARKER=/var/lib/qubes-provision.done
# Two distinct Qubes keys, do not confuse them (this bit us once):
#   * MASTER release key (F3FA...7F3FADA4) signs the package-signing keys; it is
#     what keys.qubes-os.org/.../qubes-release-4.3-signing-key.asc serves.
#   * DEBIAN packages key (1B49...0AB8C804) is what actually signs the apt repo
#     metadata (InRelease). apt needs the DEBIAN key, NOT the master key -- the
#     earlier failure ("Missing key 1B49...") was from installing the master key.
# The Debian key lives in qubes-secpack (not on keys.qubes-os.org). We pin it by
# fingerprint so a tampered URL can't slip a rogue key past us.
DEB_KEY_URL="https://raw.githubusercontent.com/QubesOS/qubes-secpack/master/keys/template-keys/qubes-release-4.3-debian.asc"
DEB_FPR="1B496066C096FE93D4CF0A6E720415900AB8C804"
KEYRING=/etc/apt/keyrings/qubes-release-4.3.gpg
LIST=/etc/apt/sources.list.d/qubes-r4.3-vm.list

say() { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nPROVISION FAIL: %s\n' "$*" >&2; exit 1; }

# Debian codename of the running Proxmox (trixie on PVE 9). The Qubes VM repo
# publishes a matching suite, so derive it rather than hard-coding.
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")"

# --- 0. Switch APT off the enterprise repos (else apt-get update 401s) -------
# The stock install enables BOTH pve-enterprise and ceph-*-enterprise, which
# 401 without a subscription and make `apt-get update` exit non-zero -- that
# would abort this script before it starts. The exact filenames vary by PVE
# point release (pve-enterprise.list, ceph.sources, ceph-squid trixie, ...), so
# rather than enumerate them, disable EVERY apt source that points at
# enterprise.proxmox.com. Then add the no-subscription repo -- the community
# homelab default (part of "best practices"). PVE 9 uses deb822 .sources.
say "0/6 switch to Proxmox no-subscription repos"
# Rename any apt source file referencing the enterprise host to *.disabled (apt
# ignores files not ending in .list/.sources). Iterate the .list/.sources files
# directly -- /etc/apt filenames never contain spaces, so a simple loop is safe
# and avoids the enterprise repos' 401 that would abort `apt-get update`.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
         /etc/apt/sources.list.d/*.sources; do
  [ -f "$f" ] || continue
  if grep -q 'enterprise\.proxmox\.com' "$f"; then
    mv -f "$f" "$f.disabled"
    echo "disabled enterprise source: $f"
  fi
done
cat >/etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
# Silence the "no valid subscription" login nag (cosmetic; guarded so an
# upstream layout change can't break provisioning).
PROXYLIB="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [ -f "$PROXYLIB" ] && ! grep -q "void({ //NoMoreNagging" "$PROXYLIB"; then
  sed -i "s/data.status.toLowerCase() !== 'active'/void({ \/\/NoMoreNagging/" \
    "$PROXYLIB" || true
fi

# --- 1. Qubes R4.3 VM apt repository ---------------------------------------
say "1/6 add Qubes R4.3 VM repository (${CODENAME})"
install -d -m 0755 /etc/apt/keyrings
GNUPGHOME="$(mktemp -d)"; export GNUPGHOME

# Fetch the Debian packages key and PIN it by fingerprint: import it into a
# throwaway keyring, then require that the pinned fingerprint is present. If a
# tampered URL served any other key, ${DEB_FPR} won't be there and we abort --
# this is the real trust anchor (the fingerprint is hard-coded above).
curl -fsSL "${DEB_KEY_URL}" -o "${GNUPGHOME}/deb.asc" \
  || { rm -rf "${GNUPGHOME}"; fail "could not fetch Debian packages key from ${DEB_KEY_URL}"; }
gpg --import "${GNUPGHOME}/deb.asc" 2>/dev/null \
  || { rm -rf "${GNUPGHOME}"; fail "could not import Debian packages key"; }
if ! gpg --fingerprint "${DEB_FPR}" >/dev/null 2>&1; then
  rm -rf "${GNUPGHOME}"
  fail "fetched key does not contain pinned fingerprint ${DEB_FPR} -- refusing"
fi
# Export the pinned key in binary form as the repo's signed-by keyring.
gpg --export "${DEB_FPR}" >"${KEYRING}" \
  || { rm -rf "${GNUPGHOME}"; fail "could not export pinned key to ${KEYRING}"; }
rm -rf "${GNUPGHOME}"; unset GNUPGHOME
# This is only a BOOTSTRAP source, used to fetch qubes-core-agent. The package
# itself ships the canonical /etc/apt/sources.list.d/qubes-r4.list +
# /usr/share/keyrings/qubes-archive-keyring-4.3.gpg, which point at the SAME
# repo with a different signed-by path. Leaving both in place makes apt abort
# with "Conflicting values set for option Signed-By", so stage 2 deletes this
# bootstrap pair right after install and lets the package's own config stand.
cat >"${LIST}" <<EOF
deb [arch=amd64 signed-by=${KEYRING}] https://deb.qubes-os.org/r4.3/vm ${CODENAME} main
EOF

# --- 2. Install the guest agents (NO networking agent) ----------------------
say "2/6 install qubes-core-agent + qubes-gui-agent (no networking agent)"
export DEBIAN_FRONTEND=noninteractive
# DEBIAN_FRONTEND=noninteractive suppresses debconf prompts but NOT dpkg's
# conffile prompts. qubes-core-agent ships its own /etc/fstab (built for the
# Qubes split xvda/xvdb layout), so dpkg stops to ask "keep or replace?" -- on
# a non-interactive SSH stdin that EOFs and the install errors. We must KEEP
# Proxmox's existing fstab (replacing it would break boot: wrong/missing
# mounts), so force-confold keeps current files and force-confdef takes the
# package default where there's no local edit. Applied to every apt install.
APT_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
apt-get update || fail "apt-get update failed (Qubes repo unreachable?)"
# --no-install-recommends is load-bearing: it keeps qubes-core-agent-networking
# (a Recommends of qubes-core-agent) OUT. qubes-gui-agent's hard Depends still
# pull the Xorg server + the dummy video / qubes input drivers it needs.
apt-get install -y --no-install-recommends "${APT_OPTS[@]}" \
  qubes-core-agent \
  qubes-gui-agent \
  qubes-kernel-vm-support \
  || fail "qubes agent install failed"

# Guard: assert the networking agent really did NOT come in.
if dpkg -l qubes-core-agent-networking 2>/dev/null | grep -q '^ii'; then
  fail "qubes-core-agent-networking got installed -- it will fight Proxmox vmbr0"
fi

# Guard: confirm both agents actually configured (force-confold must not have
# left them half-installed) and Proxmox's fstab survived. qubes-core-agent ships
# a Qubes-layout /etc/fstab; if it had replaced ours the box wouldn't boot.
for pkg in qubes-core-agent qubes-gui-agent; do
  dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii' \
    || fail "${pkg} did not reach 'installed' state (dpkg conffile/EOF?)"
done
# The Qubes fstab mounts /rw and /usr/local off xvdb; if those markers appear,
# our fstab was clobbered by the package version and the box won't boot right.
if grep -Eq 'xvd[ab]|/dev/xvd' /etc/fstab; then
  fail "/etc/fstab contains Qubes xvd* mounts -- confold failed, boot would break"
fi

# Drop the bootstrap repo + keyring now that qubes-core-agent has shipped its
# own canonical /etc/apt/sources.list.d/qubes-r4.list +
# /usr/share/keyrings/qubes-archive-keyring-4.3.gpg. Both point at the SAME
# repo but via a different signed-by path, so leaving the bootstrap pair in
# place makes the very next apt-get abort with "Conflicting values set for
# option Signed-By". Remove ours and let the package's own config stand.
rm -f "${LIST}" "${KEYRING}"

# --- 3. Make boot Xen-optional (systemd) ------------------------------------
# Several Qubes units assume a Xen backend and HARD-block boot without one, so
# this image -- which must ALSO boot under plain QEMU (CI smoke) and as a
# Proxmox VM -- would hang. Two classes, handled differently:
#
#   a) Units that are simply WRONG for this image's disk layout -> MASK. Root is
#      one real qcow2 partition, not the Qubes split xvda/xvdb/xvdc layout, so
#      qubes-rootfs-resize (waits dev-xvda), qubes-mount-dirs (mounts /rw,/home
#      off xvdb) and dev-xvdc1-swap (swapon /dev/xvdc1) can never succeed even
#      under real Xen here. Masking is correct, not just expedient.
#
#   b) Units we DO want under real Xen (they power the integration) but that
#      stall or FAIL without Xen -> gate on ConditionVirtualization=xen via a
#      drop-in, so they SKIP cleanly under QEMU yet run normally under Qubes (a
#      Qubes domU IS a Xen guest, so the condition is true there). This is the
#      right tool for the WHOLE Qubes early-boot set, not just one unit:
#      qubes-sysinit busy-waits forever on /dev/xen/xenbus ordered
#      Before=sysinit.target; qubes-db is Type=notify ordered Before=sysinit
#      .target and never signals readiness without a backend (so it FAILS and
#      cascades "Dependency failed" up through sysinit.target -> multi-user
#      .target -> ssh, dropping boot to emergency mode -- exactly the CI hang).
#      Gating them ALL (vs hand-picking) is both correct and robust: under QEMU
#      none run -> clean boot; under Qubes all run -> full integration. The
#      packages stay installed and the gate self-lifts under Xen, so nothing is
#      lost. (qubes-gui-agent already self-skips via its own qubesdb ExecCondition.)
say "3/6 make boot Xen-optional (mask wrong-layout units, gate Xen-only units)"
systemctl mask qubes-rootfs-resize.service qubes-mount-dirs.service \
  || fail "could not mask wrong-layout Qubes units"
# dev-xvdc1-swap (swapon /dev/xvdc1) is also wrong for this single-disk image;
# mask only if the preset actually shipped the unit (tolerate its absence).
if systemctl cat dev-xvdc1-swap.service >/dev/null 2>&1; then
  systemctl mask dev-xvdc1-swap.service || fail "could not mask dev-xvdc1-swap"
fi
# Gate every enabled Qubes early/daemon unit that needs a Xen backend. Each is
# optional (the preset may not ship all), so only write the drop-in for units
# that actually exist. They run under real Xen, skip cleanly under QEMU.
GATE_UNITS=(
  qubes-sysinit.service
  qubes-early-vm-config.service
  qubes-db.service
  qubes-qrexec-agent.service
  qubes-misc-post.service
  qubes-meminfo-writer.service
  qubes-updates-proxy-forwarder.service
)
for unit in "${GATE_UNITS[@]}"; do
  systemctl cat "${unit}" >/dev/null 2>&1 || continue
  d="/etc/systemd/system/${unit}.d"
  install -d -m 0755 "${d}"
  cat >"${d}/10-skip-without-xen.conf" <<'EOF'
[Unit]
# Baked by qubes-provision.sh. This image must also boot under plain QEMU (no
# Xen). These Qubes units stall or fail without a Xen backend (qubes-sysinit
# busy-waits on /dev/xen/xenbus; qubes-db is Type=notify and never signals
# ready), and several are ordered Before=sysinit.target, so without Xen they
# wedge or cascade-fail the whole boot. Run only under real Xen (Qubes); skip
# cleanly (condition-not-met, treated as success) everywhere else.
ConditionVirtualization=xen
EOF
  echo "gated ${unit} on ConditionVirtualization=xen"
done

# THE sysinit.target trigger (named by the OnFailure serial diagnostic, run
# 27043769421): qubes-core-agent drops
# /usr/lib/systemd/system/systemd-random-seed.service.d/30_qubes.conf which adds
# `Before=sysinit.target` + `ExecStartPre=/usr/lib/qubes/init/qubes-random-seed
# .sh`. That script runs `qubesdb-read -w /qubes-random-seed`; with no qubesd it
# prints "Failed connect to local daemon" and exits 1 -> the ExecStartPre fails
# the whole (stock) systemd-random-seed.service. A SECOND drop-in,
# sysinit.target.d/30_qubes.conf, adds `Requires=systemd-random-seed.service`,
# making that failure HARD -> sysinit.target fails -> the entire boot cascades
# (no SSH). We can't ConditionVirtualization=xen the stock unit (that would
# disable legitimate random-seed save/restore under QEMU). Instead override the
# Qubes drop-in so its ExecStartPre is NON-FATAL (`-` prefix): under real Xen
# qubesdb is up and it seeds normally; under QEMU it fails harmlessly and is
# ignored, the stock ExecStart still runs, and sysinit's Requires= is satisfied.
RSEED_DROPIN="/usr/lib/systemd/system/systemd-random-seed.service.d/30_qubes.conf"
if [ -f "${RSEED_DROPIN}" ]; then
  d="/etc/systemd/system/systemd-random-seed.service.d"
  install -d -m 0755 "${d}"
  cat >"${d}/40-qubes-seed-nonfatal.conf" <<'EOF'
[Service]
# Baked by qubes-provision.sh. Qubes' 30_qubes.conf adds an ExecStartPre that
# calls qubesdb (qubes-random-seed.sh); off-Xen it exits 1 ("Failed connect to
# local daemon") and fails this unit, which Qubes makes a hard Requires= of
# sysinit.target -> whole boot cascades. Reset the ExecStartPre list and re-add
# the Qubes seeding NON-FATALLY: empty assignment clears it, `-` ignores its
# exit status. Seeds under Xen; harmless no-op under plain QEMU.
ExecStartPre=
ExecStartPre=-/usr/lib/qubes/init/qubes-random-seed.sh
EOF
  echo "made qubes-random-seed ExecStartPre non-fatal (unblocks sysinit.target off-Xen)"
fi

# --- 4. Keep the initramfs able to mount the virtio root --------------------
# qubes-kernel-vm-support drops /usr/share/initramfs-tools/conf.d/qubes.conf
# with `MODULES=dep` (overriding Debian's `MODULES=most`) + a hook that
# force-loads xen-blkfront but NO virtio. On a kernel where virtio is a MODULE
# that would strip virtio_blk from the initramfs and a QEMU virtio root would be
# unfindable. The Proxmox kernel actually builds virtio in (CONFIG_VIRTIO_BLK=y,
# CONFIG_VIRTIO_PCI=y, CONFIG_BLK_DEV_DM=y), so it's always present regardless of
# the initramfs -- which is why the bare image always booted under QEMU. We still
# restore `MODULES=most` (cheap, portable insurance via a higher-priority conf.d
# file -- last sorted wins) and rebuild, but the real GUARD is: virtio_blk must
# be reachable either built-in OR in the initramfs. (The previous guard checked
# only the initramfs and false-failed on this built-in kernel.)
say "4/6 keep initramfs able to mount the virtio root"
# THE boot-blocker (proven by the CI serial log, not the VGA screendumps):
# qubes-kernel-vm-support ships an initramfs-tools local-top boot script
# `qubes_cow_setup` that runs `gptfix fix /dev/xvda` and, when that device is
# absent, executes `die 'Fatal error reading partition table'` -- dropping to a
# BusyBox (initramfs) shell BEFORE systemd ever starts. /dev/xvda is the Qubes
# split-volume disk name; this image instead boots its OWN LVM root
# (/dev/mapper/pve-root) via its own bootloader, so the Qubes COW/gptfix
# machinery must never run -- not under QEMU and not under a real Qubes HVM
# StandaloneVM (which boots with kernel='' off its own root, never the dom0
# dmroot/xvda/xvdc scheme). Remove the COW boot scripts + the hook that pulls
# gptfix/sfdisk/xen-blkfront in, so the rebuilt initramfs is clean. This is
# orthogonal to qrexec/GUI, which are userspace vchan services.
for f in \
  /usr/share/initramfs-tools/scripts/local-top/qubes_cow_setup \
  /usr/share/initramfs-tools/scripts/local-top/scrub_pages \
  /usr/share/initramfs-tools/hooks/qubes_vm \
  /usr/share/initramfs-tools/conf.d/qubes.conf; do
  if [ -e "${f}" ]; then
    rm -f "${f}" && echo "removed Qubes initramfs file ${f}"
  fi
done
cat >/etc/initramfs-tools/conf.d/zz-proxmox-force-most.conf <<'EOF'
# Baked by qubes-provision.sh. Overrides qubes.conf's MODULES=dep so a virtio
# root stays reachable if virtio is ever a module rather than built-in. `most`
# bundles the common storage drivers like a stock Debian initramfs.
MODULES=most
EOF
for m in virtio_pci virtio_blk virtio_scsi dm_mod dm_snapshot; do
  grep -qxF "$m" /etc/initramfs-tools/modules 2>/dev/null \
    || echo "$m" >>/etc/initramfs-tools/modules
done
update-initramfs -u -k all || fail "update-initramfs failed"
# Tripwire: the COW boot script must NOT survive into the rebuilt initramfs --
# its presence is exactly what wedged boot to (initramfs) on every prior run.
KVER_CHK="$(ls -1 /boot/initrd.img-* 2>/dev/null | sed 's#.*/initrd.img-##' | sort -V | tail -1)"
if [ -n "${KVER_CHK}" ] && command -v lsinitramfs >/dev/null 2>&1; then
  if lsinitramfs "/boot/initrd.img-${KVER_CHK}" | grep -q 'local-top/qubes_cow_setup'; then
    fail "qubes_cow_setup still in initramfs ${KVER_CHK} -- gptfix would re-wedge boot"
  fi
  echo "ok: qubes_cow_setup absent from initramfs ${KVER_CHK}"
fi
# Hard guard: assert virtio_blk is available to the boot path -- built into the
# kernel (CONFIG_VIRTIO_BLK=y in /boot/config-*) OR shipped in the initramfs.
# Either satisfies a QEMU virtio root; failing BOTH means the image won't boot.
KVER="$(ls -1 /boot/initrd.img-* 2>/dev/null | sed 's#.*/initrd.img-##' | sort -V | tail -1)"
if [ -n "${KVER}" ]; then
  builtin_ok=""; initrd_ok=""
  [ -f "/boot/config-${KVER}" ] && grep -q '^CONFIG_VIRTIO_BLK=y' "/boot/config-${KVER}" \
    && builtin_ok=1
  if command -v lsinitramfs >/dev/null 2>&1; then
    lsinitramfs "/boot/initrd.img-${KVER}" | grep -q 'virtio_blk' && initrd_ok=1
  fi
  [ -n "${builtin_ok}" ] || [ -n "${initrd_ok}" ] \
    || fail "virtio_blk neither built into kernel ${KVER} nor in its initramfs -- would not boot on QEMU"
  echo "ok: virtio_blk reachable (builtin=${builtin_ok:-0} initramfs=${initrd_ok:-0}) for ${KVER}"
fi

# --- 4b. Serial console on the kernel cmdline -------------------------------
# Best practice for a headless server image: emit the kernel + systemd console
# to ttyS0 so boot is observable over a serial line (and the CI smoke test can
# capture a lossless, ordered boot log to diagnose any early-boot failure --
# VGA screendumps only catch a frozen frame, not scrollback). Keep tty0 too so
# the VGA console still works. Append once, idempotently, then refresh grub.
say "4b/6 add serial console (console=ttyS0) to kernel cmdline"
# SECOND boot-blocker found via serial log (run 27041811829): after the COW/
# gptfix removal, boot cleared the initramfs (pve LVM activated) but then hit
# `ALERT! /dev/mapper/dmroot does not exist. Dropping to a shell!`. Cause:
# qubes-core-agent ships /etc/default/grub.d/30-qubes.cfg which forces
# `GRUB_DEVICE=/dev/mapper/dmroot` and appends `root=/dev/mapper/dmroot` -- the
# Qubes split-volume root name. The bare image booted on Proxmox's
# `root=/dev/mapper/pve-root`; this drop-in only took effect once we regenerated
# grub below. This image boots its OWN pve-root (under QEMU AND a real Qubes HVM
# StandaloneVM, which boots its own kernel off its own root, never dom0's
# dmroot), so the override is wrong everywhere -- remove it before update-grub.
# It also sets GRUB_TIMEOUT=0 + console=hvc0; dropping it restores Proxmox's.
QUBES_GRUB_DROPIN=/etc/default/grub.d/30-qubes.cfg
if [ -e "${QUBES_GRUB_DROPIN}" ]; then
  rm -f "${QUBES_GRUB_DROPIN}" && echo "removed Qubes grub override ${QUBES_GRUB_DROPIN} (forced root=dmroot)"
fi
SERIAL_ARGS="console=tty0 console=ttyS0,115200"
refreshed=""
# Proxmox boots EITHER via systemd-boot/proxmox-boot-tool (cmdline lives in
# /etc/kernel/cmdline) OR via classic grub (GRUB_CMDLINE_LINUX_DEFAULT in
# /etc/default/grub). Patch whichever source the box actually uses, else the
# edit is a silent no-op and the serial console never appears. Keep tty0 so the
# VGA console still works for screendumps.

# --- systemd-boot path (proxmox-boot-tool) ---------------------------------
KCMDLINE=/etc/kernel/cmdline
if command -v proxmox-boot-tool >/dev/null 2>&1 \
   && proxmox-boot-tool status >/dev/null 2>&1; then
  if [ -f "${KCMDLINE}" ]; then
    if ! grep -q 'console=ttyS0' "${KCMDLINE}"; then
      # Single-line file: append the args to the end of the (only) line.
      sed -i "1 s|\$| ${SERIAL_ARGS}|" "${KCMDLINE}"
    fi
  else
    echo "root=/dev/mapper/pve-root ro quiet ${SERIAL_ARGS}" >"${KCMDLINE}"
  fi
  proxmox-boot-tool refresh || fail "proxmox-boot-tool refresh failed"
  refreshed=1
  echo "ok: ${SERIAL_ARGS} via proxmox-boot-tool (${KCMDLINE})"
fi

# --- classic grub path ------------------------------------------------------
GRUBDEF=/etc/default/grub
if [ -z "${refreshed}" ] && [ -f "${GRUBDEF}" ]; then
  if ! grep -q 'console=ttyS0' "${GRUBDEF}"; then
    # Append to GRUB_CMDLINE_LINUX_DEFAULT, preserving any existing value.
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "${GRUBDEF}"; then
      sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 ${SERIAL_ARGS}\"/" \
        "${GRUBDEF}"
    else
      echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet ${SERIAL_ARGS}\"" >>"${GRUBDEF}"
    fi
  fi
  if command -v update-grub >/dev/null 2>&1; then
    update-grub || fail "update-grub failed"
    refreshed=1
    echo "ok: ${SERIAL_ARGS} via update-grub (${GRUBDEF})"
  fi
fi

[ -n "${refreshed}" ] || fail "no bootloader cmdline source found -- serial console not applied"

# Tripwire: the regenerated boot config must point root at Proxmox's pve-root,
# NOT the Qubes dmroot (the 30-qubes.cfg override we just removed). A stray
# `root=/dev/mapper/dmroot` is exactly what dropped boot to (initramfs) last run.
for cfg in /boot/grub/grub.cfg /boot/efi/EFI/proxmox/*/grub.cfg /etc/kernel/cmdline; do
  [ -f "${cfg}" ] || continue
  if grep -q 'root=/dev/mapper/dmroot' "${cfg}"; then
    fail "boot config ${cfg} still sets root=/dev/mapper/dmroot -- would wedge boot"
  fi
done
echo "ok: boot config targets pve-root (no stray root=dmroot)"

# --- 4c. Qubes auto-networking for vmbr0 (QubesDB-driven) -------------------
# Goal: the qube auto-configures its IP/gateway/DNS like any other Qubes VM,
# WITHOUT qubes-core-agent-networking (which configures the RAW NIC the Qubes /32
# way and drags NetworkManager in -- both destroy Proxmox's vmbr0 bridge, the
# seam LXC + the firewall hole hang off). The trick: QubesDB is served over
# XenBus, NOT the network, so we read the dom0-assigned addressing with
# qubesdb-read and apply it OURSELVES to the vmbr0 BRIDGE -- keeping Proxmox's
# model (enslaved NIC + container ports) while gaining auto-addressing. Same
# pattern as qubes-mirage-firewall and Windows QWT (read QubesDB at boot, keep
# own net stack); the route logic is a faithful copy of qubes-core-agent's
# network/setup-ip (point-to-point /32: scope-link host route to the gateway +
# onlink default + permanent gateway-MAC neigh).
#
# Xen-gated (ConditionVirtualization=xen) so it ONLY runs under real Qubes/Xen.
# Under plain QEMU (CI smoke) it never fires, so the vmbr0 that CI's NAT-out
# relies on is left exactly as built -- zero regression risk. CI validates the
# GENERATOR LOGIC instead, by running the script in DRY_RUN with injected values.
say "4c/6 install QubesDB-driven vmbr0 auto-networking (Xen-gated)"
# Install into /usr/sbin, NOT /usr/local/sbin: qubes-core-agent turns /usr/local
# into a persistent per-VM bind-mount from /rw/usrlocal (and seeds it from
# /usr/local.orig), so anything baked under /usr/local on the read-only root is
# SHADOWED on the next boot -- the file passes the provision self-test but
# vanishes by the smoke boot. /usr/sbin is part of the immutable root (never a
# Qubes bind target) and is the correct FHS home for an OS-shipped admin script.
cat >/usr/sbin/qubes-vmbr0-netcfg <<'NETCFG'
#!/bin/sh
# Apply Qubes-assigned networking to the Proxmox vmbr0 bridge.
#
# Reads IP/gateway/DNS from QubesDB (XenBus -- needs no network) and applies the
# Qubes point-to-point /32 model to vmbr0, faithfully following the route logic
# in qubes-core-agent network/setup-ip. Installed by qubes-provision.sh and run
# at boot by qubes-vmbr0-netcfg.service (which is ConditionVirtualization=xen).
#
# Manual override / escape hatch: kernelopts is NOT delivered to a kernel=''
# StandaloneVM (it boots its own kernel via GRUB, so dom0 never sets the kernel
# cmdline), so the override lives in a FILE -- /etc/default/qubes-vmbr0-netcfg --
# which may set IP/GW/DNS1/DNS2 (and IFACE). CI injects the same vars + DRY_RUN
# to exercise the generator without a Xen backend.
set -eu

IFACE="${IFACE:-vmbr0}"
DRY_RUN="${QUBES_NETCFG_DRY_RUN:-}"

log() { echo "qubes-vmbr0-netcfg: $*"; }

# In-guest manual override / CI injection point (may set IP/GW/DNS1/DNS2/IFACE).
[ -r /etc/default/qubes-vmbr0-netcfg ] && . /etc/default/qubes-vmbr0-netcfg

# Value resolution: an explicit env/override value wins, else read from QubesDB.
qdb() { # <qubesdb-key> <current-value>
  if [ -n "$2" ]; then printf '%s' "$2"; return 0; fi
  qubesdb-read "$1" 2>/dev/null || true
}
IP="$(qdb /qubes-ip "${IP:-}")"
GW="$(qdb /qubes-gateway "${GW:-}")"
DNS1="$(qdb /qubes-primary-dns "${DNS1:-}")"
DNS2="$(qdb /qubes-secondary-dns "${DNS2:-}")"

# No /qubes-ip => the qube has no netvm; leave Proxmox's own config untouched.
[ -n "$IP" ] || { log "no /qubes-ip (no netvm?) -- leaving ${IFACE} unchanged"; exit 0; }
[ -n "$GW" ] || { log "have IP ${IP} but no /qubes-gateway -- refusing partial config"; exit 1; }

run() { if [ -n "$DRY_RUN" ]; then echo "+ $*"; else "$@"; fi; }

# Point-to-point /32 model (mirrors setup-ip): replace the interface address
# with our /32 (flushing the build-time placeholder the installer left), pin the
# gateway MAC (anti-spoof), add a scope-link host route to the gateway (it sits
# OUTSIDE our subnet), then the default route via it with onlink.
run ip -4 addr flush dev "$IFACE"
run ip addr add "${IP}/32" dev "$IFACE"
run ip neigh replace to "$GW" dev "$IFACE" lladdr fe:ff:ff:ff:ff:ff nud permanent
run ip route replace to unicast "$GW" dev "$IFACE" scope link
run ip route replace to unicast default via "$GW" dev "$IFACE" onlink

# DNS: Qubes hands out placeholder resolvers that the netvm DNATs upstream.
if [ -n "$DNS1" ]; then
  RESOLV="# written by qubes-vmbr0-netcfg (Qubes-assigned resolvers)
nameserver $DNS1"
  [ -n "$DNS2" ] && RESOLV="$RESOLV
nameserver $DNS2"
  if [ -n "$DRY_RUN" ]; then
    echo "+ write /etc/resolv.conf: nameserver $DNS1${DNS2:+, $DNS2}"
  else
    printf '%s\n' "$RESOLV" >/etc/resolv.conf
  fi
fi

log "applied ${IP}/32 gw ${GW} on ${IFACE}"
NETCFG
chmod 0755 /usr/sbin/qubes-vmbr0-netcfg

cat >/etc/systemd/system/qubes-vmbr0-netcfg.service <<'UNIT'
[Unit]
Description=Apply Qubes-assigned networking to the Proxmox vmbr0 bridge
Documentation=https://github.com/steffansluis/proxmox-qubes-image
# Only under real Xen (a Qubes domU). Under plain QEMU (CI) this never runs, so
# the vmbr0 the smoke test's NAT-out depends on is left exactly as built.
ConditionVirtualization=xen
# vmbr0 must exist (ifupdown2) and qubesdb must be up (it serves our addresses).
After=networking.service qubes-db.service qubes-sysinit.service
Wants=qubes-db.service
# Be addressed before the web UI + guests come up so they bind the right IP.
Before=pveproxy.service pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/qubes-vmbr0-netcfg

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable qubes-vmbr0-netcfg.service \
  || fail "could not enable qubes-vmbr0-netcfg.service"

# Self-test the generator at bake time (no Xen here, so the service itself stays
# idle): assert no syntax errors, then inject fake dom0-assigned values + DRY_RUN
# and require it to emit the canonical setup-ip route commands. Catches a broken
# generator BEFORE publish -- the same path CI's smoke stage re-checks.
sh -n /usr/sbin/qubes-vmbr0-netcfg \
  || fail "qubes-vmbr0-netcfg has a shell syntax error"
NETCFG_OUT="$(QUBES_NETCFG_DRY_RUN=1 IP=10.137.0.99 GW=10.138.23.60 \
  DNS1=10.139.1.1 DNS2=10.139.1.2 /usr/sbin/qubes-vmbr0-netcfg 2>&1)" \
  || fail "qubes-vmbr0-netcfg dry-run exited non-zero"
for expect in \
  '+ ip addr add 10.137.0.99/32 dev vmbr0' \
  '+ ip route replace to unicast 10.138.23.60 dev vmbr0 scope link' \
  '+ ip route replace to unicast default via 10.138.23.60 dev vmbr0 onlink' \
  '+ ip neigh replace to 10.138.23.60 dev vmbr0 lladdr fe:ff:ff:ff:ff:ff nud permanent'; do
  printf '%s\n' "${NETCFG_OUT}" | grep -qF "${expect}" \
    || fail "qubes-vmbr0-netcfg dry-run missing expected command: ${expect}"
done
echo "ok: qubes-vmbr0-netcfg installed + enabled (Xen-gated), generator self-test passed"

# --- 5. A browser to render the web UI, + the app-menu shortcut -------------
# The "Proxmox Web GUI" menu entry opens the local web interface in a chromeless
# Chromium --app window, which the dom0 WM decorates like any native app window.
say "5/6 install chromium + 'Proxmox Web GUI' .desktop"
# desktop-file-utils provides desktop-file-validate, which both this script and
# the smoke test's stage 5 rely on; it isn't guaranteed on a minimal PVE install.
apt-get install -y --no-install-recommends "${APT_OPTS[@]}" \
  chromium desktop-file-utils \
  || fail "chromium / desktop-file-utils install failed"

# Resolve the chromium binary name across Debian variants (chromium vs
# chromium-browser) so the Exec line is always valid.
CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || true)"
[ -n "${CHROMIUM_BIN}" ] || fail "no chromium binary found after install"

# .desktop lives in /usr/share/applications so qubes.GetAppMenus enumerates it;
# dom0's qvm-sync-appmenus then rewrites Exec to qubes.StartApp+proxmox-web-gui.
# Name uses only ASCII/-/space (passes desktop-file-validate). The --app window
# is a single-purpose kiosk-ish window pointed at the local web UI over HTTPS.
install -d -m 0755 /usr/share/applications
cat >/usr/share/applications/proxmox-web-gui.desktop <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Proxmox Web GUI
GenericName=Proxmox VE Management
Comment=Open the Proxmox VE web interface
Exec=${CHROMIUM_BIN} --app=https://localhost:8006 --ignore-certificate-errors
Icon=proxmox-ve
Terminal=false
Categories=Network;
StartupNotify=true
EOF
desktop-file-validate /usr/share/applications/proxmox-web-gui.desktop \
  || fail "proxmox-web-gui.desktop failed desktop-file-validate"

# --- 6. Done ----------------------------------------------------------------
say "6/6 finalize"
apt-get clean
date -u +%FT%TZ >"${MARKER}"
echo "qubes-provision complete -> ${MARKER}"
printf '\nPROVISION OK: Qubes guest integration baked in.\n'
