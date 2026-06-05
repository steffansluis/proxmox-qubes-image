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
QMP_SOCK=""
# Lossless, ORDERED boot log. The provisioned image bakes console=ttyS0,115200
# into the kernel cmdline (qubes-provision.sh stage 4b), so every systemd job
# result -- including the "Failed to start <unit>" line that NAMES a boot-hang
# culprit -- lands here in order. A single VGA screendump can't show scrollback;
# this can. CI uploads it as an artifact. Override dir via env.
SERIAL_LOG="${SMOKE_SERIAL_LOG:-smoke-boot-serial.log}"
# If boot hangs (e.g. baking the Qubes agents in regresses boot), we screendump
# the guest's VGA console via QMP -- the installed system boots with `quiet` and
# NO console=ttyS0, so serial capture would be empty, but systemd job status and
# any initramfs emergency shell still render on the VGA framebuffer. CI uploads
# the PNG so a hang is diagnosable without a serial console. Override dir via env.
SCREENSHOT="${SMOKE_SCREENSHOT:-smoke-boot-console.png}"

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
  [ -n "${QMP_SOCK}" ] && rm -f "${QMP_SOCK}" || true
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
# Expose a QMP socket so we can screendump the VGA console if boot hangs. Keep
# -nographic (headless) but route the monitor to QMP instead of discarding it.
QMP_SOCK="$(mktemp --suffix=.qmp -u)"
qemu-system-x86_64 \
  -machine accel=kvm,type=q35 -cpu host -smp 4 -m 4096 \
  -drive file="${OVERLAY}",format=qcow2,if=virtio \
  -netdev user,id=n0,hostfwd=tcp::"${SSH_PORT}"-:22 \
  -device virtio-net-pci,netdev=n0 \
  -nographic -serial "file:${SERIAL_LOG}" -qmp "unix:${QMP_SOCK},server,nowait" &
QEMU_PID=$!

# Screendump the guest's current VGA framebuffer (best-effort). Without an arg
# it writes ${SCREENSHOT} (the canonical "boot console" artifact); with an arg
# it writes a numbered frame so we can capture a SERIES during boot -- the
# systemd "Failed to start <unit>" line that names the culprit prints once and
# scrolls off, so a single end-of-timeout shot only catches the [DEPEND] cascade.
grab_console() {
  [ -S "${QMP_SOCK}" ] || return 0
  local out="${SCREENSHOT}"
  [ -n "${1:-}" ] && out="${SCREENSHOT%.png}-${1}.png"
  python3 "$(dirname "$0")/qmp_screendump.py" "${QMP_SOCK}" "${out}" \
    >/dev/null 2>&1 || true
}

# Echo the tail of the ordered serial boot log to CI stdout so a boot hang's
# real culprit is visible in the job output, not just the uploaded artifact.
dump_serial() {
  [ -f "${SERIAL_LOG}" ] || return 0
  echo "----- serial boot log (last 120 lines of ${SERIAL_LOG}) -----" >&2
  tail -n 120 "${SERIAL_LOG}" >&2 || true
  echo "----- end serial boot log -----" >&2
}

echo "Waiting for Proxmox SSH (up to ~6 min)..."
ready=""
for i in $(seq 1 180); do
  if sshp -o BatchMode=no true 2>/dev/null; then ready=1; break; fi
  # Bail early if QEMU died (e.g. image won't boot) instead of waiting it out.
  kill -0 "${QEMU_PID}" 2>/dev/null || {
    echo "QEMU exited prematurely" >&2
    grab_console
    dump_serial
    exit 1
  }
  # Snapshot the console periodically through the boot window so a hang's root
  # cause (the unit that actually failed) is captured before it scrolls away.
  # Frames at ~30s, 60s, 90s, 150s, 240s cover initramfs through emergency mode.
  case "$i" in 15|30|45|75|120) grab_console "$((i*2))s" ;; esac
  sleep 2
done
[ -n "${ready}" ] || {
  echo "SSH never came up -- capturing boot console for diagnosis" >&2
  # Final screendump of the VGA console before we tear QEMU down; CI uploads
  # ${SCREENSHOT} plus the numbered frames above as artifacts.
  grab_console
  # The ordered serial log is the authoritative diagnosis -- echo its tail to
  # the job output and let CI upload the full file as an artifact.
  dump_serial
  exit 1
}
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
