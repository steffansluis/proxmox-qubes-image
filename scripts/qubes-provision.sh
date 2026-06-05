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
#   * Mask the two units that hard-block boot on a non-Qubes disk layout
#     (qubes-rootfs-resize, qubes-mount-dirs order Before=local-fs.target and
#     wait on Xen disk names dev-xvda/dev-xvdb that never appear on Proxmox's
#     vda/sda). With those masked the image boots to login under BOTH real Xen
#     AND plain QEMU (so the CI smoke test, which has no Xen backend, passes).
#   * Everything else (qrexec-agent, qubesdb, meminfo-writer) fails SOFT without
#     a Xen backend -- it retries but never blocks multi-user.target -- so we
#     leave it enabled and it lights up for real once booted under Qubes.
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
say "0/5 switch to Proxmox no-subscription repos"
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
say "1/5 add Qubes R4.3 VM repository (${CODENAME})"
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
cat >"${LIST}" <<EOF
deb [arch=amd64 signed-by=${KEYRING}] https://deb.qubes-os.org/r4.3/vm ${CODENAME} main
EOF

# --- 2. Install the guest agents (NO networking agent) ----------------------
say "2/5 install qubes-core-agent + qubes-gui-agent (no networking agent)"
export DEBIAN_FRONTEND=noninteractive
apt-get update || fail "apt-get update failed (Qubes repo unreachable?)"
# --no-install-recommends is load-bearing: it keeps qubes-core-agent-networking
# (a Recommends of qubes-core-agent) OUT. qubes-gui-agent's hard Depends still
# pull the Xorg server + the dummy video / qubes input drivers it needs.
apt-get install -y --no-install-recommends \
  qubes-core-agent \
  qubes-gui-agent \
  qubes-kernel-vm-support \
  || fail "qubes agent install failed"

# Guard: assert the networking agent really did NOT come in.
if dpkg -l qubes-core-agent-networking 2>/dev/null | grep -q '^ii'; then
  fail "qubes-core-agent-networking got installed -- it will fight Proxmox vmbr0"
fi

# --- 3. Neutralise the boot-blocking units ----------------------------------
# These two oneshots order Before=local-fs.target and block on Xen disk names
# (dev-xvda/dev-xvdb) that don't exist on Proxmox's vda layout -> boot hangs.
# Masking them is safe here precisely because root is a single real qcow2
# partition (not a Qubes split root/private layout needing a 2nd volume).
say "3/5 mask boot-blocking Qubes units (rootfs-resize, mount-dirs)"
systemctl mask qubes-rootfs-resize.service qubes-mount-dirs.service \
  || fail "could not mask boot-blocking units"

# --- 4. A browser to render the web UI, + the app-menu shortcut -------------
# The "Proxmox Web GUI" menu entry opens the local web interface in a chromeless
# Chromium --app window, which the dom0 WM decorates like any native app window.
say "4/5 install chromium + 'Proxmox Web GUI' .desktop"
# desktop-file-utils provides desktop-file-validate, which both this script and
# the smoke test's stage 5 rely on; it isn't guaranteed on a minimal PVE install.
apt-get install -y --no-install-recommends chromium desktop-file-utils \
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
Categories=System;Network;
StartupNotify=true
EOF
desktop-file-validate /usr/share/applications/proxmox-web-gui.desktop \
  || fail "proxmox-web-gui.desktop failed desktop-file-validate"

# --- 5. Done ----------------------------------------------------------------
say "5/5 finalize"
apt-get clean
date -u +%FT%TZ >"${MARKER}"
echo "qubes-provision complete -> ${MARKER}"
printf '\nPROVISION OK: Qubes guest integration baked in.\n'
