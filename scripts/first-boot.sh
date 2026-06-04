#!/usr/bin/env bash
# Optional first-boot hook for the unattended install.
# Wire it into answer.toml with:
#
#   [first-boot]
#   source = "from-iso"
#   ordering = "network-online"
#
# and pass `--on-first-boot scripts/first-boot.sh` to prepare-iso.
#
# Runs ONCE inside the freshly installed Proxmox, on first boot, as root.
# Keep it idempotent and dependency-light -- only base PVE tooling is present.
set -euo pipefail

# --- Switch APT to the no-subscription repos -------------------------------
# The stock install points at the enterprise repo, which 401s without a
# subscription and spams errors. Community homelab default: no-subscription.
# (PVE 9 / Debian 13 "trixie" uses the deb822 .sources format.)
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")"

rm -f /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/ceph.list 2>/dev/null || true

cat >/etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# --- Silence the "no valid subscription" login nag -------------------------
# Cosmetic only; touches a JS asset shipped by the web UI. Guarded so an
# upstream layout change can't break first boot.
PROXYLIB="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [ -f "$PROXYLIB" ] && ! grep -q "void({ //NoMoreNagging" "$PROXYLIB"; then
  sed -i "s/data.status.toLowerCase() !== 'active'/void({ \/\/NoMoreNagging/" "$PROXYLIB" || true
fi

echo "first-boot.sh complete: no-subscription repo set, nag patched."
