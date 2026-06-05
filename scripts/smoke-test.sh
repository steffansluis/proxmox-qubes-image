#!/usr/bin/env bash
# Runner-side smoke driver. Boots the freshly built Proxmox qcow2 headless
# under QEMU (KVM-accelerated on the GH runner), waits for SSH, copies in
# scripts/proxmox-smoke.sh, and runs it. Non-zero exit => CI gates the push.
#
# Auth: logs in as root with the image's OWN default password ("proxmox") via
# sshpass. This tests the EXACT artifact we publish, with no CI key baked into
# a public image. Proxmox ships PermitRootLogin yes, so this works unmodified.
#
# Why this is possible inside CI at all: LXC is namespaces-only, so the
# runner -> Proxmox-guest -> container stack needs just ONE level of virt
# (the KVM-accelerated Proxmox guest). No nested VT-x required.
#
# Usage: scripts/smoke-test.sh <image.qcow2>
set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image.qcow2>}"
SSH_PORT=2222
PASSWORD="proxmox"
QEMU_PID=""
OVERLAY=""

# Note: ssh takes the port as -p, scp as -P -- keep the port out of the shared
# opts and add it per-tool, or scp reads "-p <port>" as preserve-times + a
# bogus filename.
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)
sshp() { sshpass -p "${PASSWORD}" ssh "${ssh_opts[@]}" -p "${SSH_PORT}" root@localhost "$@"; }
scpp() { sshpass -p "${PASSWORD}" scp "${ssh_opts[@]}" -P "${SSH_PORT}" "$@"; }

cleanup() {
  [ -n "${QEMU_PID}" ] && kill "${QEMU_PID}" 2>/dev/null || true
  [ -n "${OVERLAY}" ] && rm -f "${OVERLAY}" || true
}
trap cleanup EXIT

# Boot a disposable copy-on-write OVERLAY backed by the real image, so the
# smoke test's writes (vmbr1, downloaded template, container) never touch the
# artifact we publish. The source qcow2 stays pristine.
OVERLAY="$(mktemp --suffix=.qcow2)"
qemu-img create -f qcow2 -b "$(realpath "${IMAGE}")" -F qcow2 "${OVERLAY}" >/dev/null

echo "Booting ${IMAGE} via overlay ${OVERLAY} headless (KVM)..."
# user-net with hostfwd maps localhost:2222 -> guest:22. Generous RAM/CPU so
# the LXC template download + container boot aren't starved.
qemu-system-x86_64 \
  -machine accel=kvm,type=q35 -cpu host -smp 4 -m 4096 \
  -drive file="${OVERLAY}",format=qcow2,if=virtio \
  -netdev user,id=n0,hostfwd=tcp::"${SSH_PORT}"-:22 \
  -device virtio-net-pci,netdev=n0 \
  -nographic -serial null -monitor none &
QEMU_PID=$!

echo "Waiting for Proxmox SSH (up to ~6 min)..."
ready=""
for i in $(seq 1 180); do
  if sshp -o BatchMode=no true 2>/dev/null; then ready=1; break; fi
  # Bail early if QEMU died (e.g. image won't boot) instead of waiting it out.
  kill -0 "${QEMU_PID}" 2>/dev/null || { echo "QEMU exited prematurely" >&2; exit 1; }
  sleep 2
done
[ -n "${ready}" ] || { echo "SSH never came up" >&2; exit 1; }
echo "SSH up after ~$((i*2))s."

echo "Copying smoke test into guest..."
scpp "$(dirname "$0")/proxmox-smoke.sh" root@localhost:/root/proxmox-smoke.sh

echo "Running in-guest smoke test..."
# Capture rc explicitly: under `set -e` a bare failing command would abort the
# script before we could shut the guest down gracefully.
rc=0
sshp 'chmod +x /root/proxmox-smoke.sh && /root/proxmox-smoke.sh' || rc=$?

# Graceful shutdown so QEMU exits cleanly; cleanup() is the hard fallback.
sshp 'poweroff' 2>/dev/null || true
exit "${rc}"
