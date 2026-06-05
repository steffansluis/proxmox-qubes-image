#!/usr/bin/env bash
# Runner-side provision driver. Boots the freshly built Proxmox qcow2 headless
# under QEMU (KVM on the GH runner), waits for SSH, copies in
# scripts/qubes-provision.sh, runs it, and powers off cleanly so the changes
# PERSIST into the image we publish.
#
# Unlike scripts/smoke-test.sh (which boots a disposable overlay so its writes
# are thrown away), this writes DIRECTLY to the image -- that is the whole
# point: bake the Qubes guest agents in once, at build time, so the published
# artifact imports as a fully integrated Qubes StandaloneVM.
#
# Auth: root + the image's own default password ("proxmox") over sshpass, same
# as the smoke driver -- tests the exact artifact, no CI key baked into the
# public image.
#
# Usage: scripts/provision.sh <image.qcow2>
set -euo pipefail

IMAGE="${1:?usage: provision.sh <image.qcow2>}"
SSH_PORT=2223          # distinct from smoke's 2222 in case both ever overlap
PASSWORD="proxmox"
QEMU_PID=""

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)
sshp() { sshpass -p "${PASSWORD}" ssh "${ssh_opts[@]}" -p "${SSH_PORT}" root@localhost "$@"; }
scpp() { sshpass -p "${PASSWORD}" scp "${ssh_opts[@]}" -P "${SSH_PORT}" "$@"; }

cleanup() { [ -n "${QEMU_PID}" ] && kill "${QEMU_PID}" 2>/dev/null || true; }
trap cleanup EXIT

echo "Booting ${IMAGE} read-write headless (KVM) to bake Qubes agents..."
# NOTE: no overlay -- we boot the real image so provisioning persists.
qemu-system-x86_64 \
  -machine accel=kvm,type=q35 -cpu host -smp 4 -m 4096 \
  -drive file="${IMAGE}",format=qcow2,if=virtio \
  -netdev user,id=n0,hostfwd=tcp::"${SSH_PORT}"-:22 \
  -device virtio-net-pci,netdev=n0 \
  -nographic -serial null -monitor none &
QEMU_PID=$!

echo "Waiting for Proxmox SSH (up to ~6 min)..."
ready=""
for i in $(seq 1 180); do
  if sshp -o BatchMode=no true 2>/dev/null; then ready=1; break; fi
  kill -0 "${QEMU_PID}" 2>/dev/null || { echo "QEMU exited prematurely" >&2; exit 1; }
  sleep 2
done
[ -n "${ready}" ] || { echo "SSH never came up" >&2; exit 1; }
echo "SSH up after ~$((i*2))s."

echo "Copying provision script into guest..."
scpp "$(dirname "$0")/qubes-provision.sh" root@localhost:/root/qubes-provision.sh

echo "Running in-guest provision (installs Qubes agents)..."
rc=0
sshp 'chmod +x /root/qubes-provision.sh && /root/qubes-provision.sh' || rc=$?

# Graceful shutdown so the qcow2 is left clean and QEMU exits; cleanup() is the
# hard fallback. We must power off BEFORE returning so all writes are flushed.
echo "Powering off guest to flush provisioned changes..."
sshp 'sync; systemctl poweroff' 2>/dev/null || true

# Wait for QEMU to actually exit (clean shutdown) before we hand the image to
# the next stage, up to ~60s, then fall back to the cleanup kill.
for _ in $(seq 1 30); do
  kill -0 "${QEMU_PID}" 2>/dev/null || { QEMU_PID=""; break; }
  sleep 2
done

exit "${rc}"
