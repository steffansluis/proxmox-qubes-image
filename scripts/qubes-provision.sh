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
