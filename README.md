# proxmox-qubes-image

Build a **[Proxmox VE](https://www.proxmox.com/) `qcow2`** that boots as a
**fully Qubes-integrated standalone HVM under [Qubes OS](https://www.qubes-os.org/)**,
and publish it to GHCR so others (and future-you on dedicated hardware) can
`oras pull` it instead of sitting through a 20-minute ISO install.

The published image has the **Qubes guest agents baked in** (qrexec + GUI
agent), so it imports as a first-class qube: windows are decorated by the dom0
WM, and a **"Proxmox Web GUI" application-menu shortcut** opens the web
interface in a dom0-decorated browser window — no manual post-import tools
install. (Networking still needs the one-time static-IP edit below, since the
networking agent is deliberately left out so it can't fight Proxmox's `vmbr0`.)

> **Unofficial community build.** Not affiliated with or endorsed by Proxmox
> Server Solutions GmbH. "Proxmox" is their trademark. Proxmox VE itself is
> free software (AGPLv3); this repo only automates installing it and packaging
> the result. Verify the image before trusting it.

## ⚠️ What works and what doesn't (read this first)

This image is meant for the **no-nested-VM** case. Qubes runs on Xen and, by
design, **disables hardware virtualization (VT-x/SVM) inside HVMs**. The exact
same limitation is documented for running Qubes-inside-Qubes (the inner
instance can only run PV guests, never HVMs).

| Inside Proxmox-on-Qubes | Status |
|---|---|
| Proxmox host + web UI (`:8006`) | ✅ works |
| Qubes integration (qrexec, GUI agent, app-menu shortcut) | ✅ baked in |
| **LXC containers** (incl. Docker *inside* an LXC) | ✅ works — namespaces, no VT-x needed |
| **KVM virtual machines** | ❌ won't start — needs nested virtualization |

If you need full VMs or PCIe passthrough, run Proxmox on **bare metal**, not
nested in Qubes. This image is for a management-surface trial and for running
containerized homelab workloads.

## Consuming the image (Qubes dom0)

Once the workflow has published an image:

```bash
# 1. In a NETWORKED qube (dom0 has no network), pull and decompress:
oras pull ghcr.io/<owner>/proxmox-qubes-image/proxmox-ve:9.2-1
zstd -d proxmox-ve.qcow2.zst -o proxmox-ve.qcow2
qemu-img convert -p -O raw proxmox-ve.qcow2 proxmox-ve.raw   # Qubes volumes are raw

# 2. In DOM0: create an empty standalone HVM, then pull the raw image into it.
#    (Run these in a dom0 terminal — they can't be run from inside a VM.)
qvm-create --class StandaloneVM --label orange \
  --property virt_mode=hvm proxmox
qvm-prefs proxmox memory 4096
qvm-prefs proxmox maxmem 8192
qvm-prefs proxmox vcpus 4
qvm-prefs proxmox kernel ''          # empty kernel = boot guest's own bootloader

# Size the root volume to the raw image (round up), then import:
qvm-volume resize proxmox:root 16GiB
qvm-volume import --no-resize proxmox:root \
  /path/in/qube/proxmox-ve.raw       # dom0 reads it via qvm-run/qrexec from the qube

qvm-start proxmox
```

> Getting the raw file from the networked qube to the dom0 `qvm-volume import`:
> the simplest reliable path is `qvm-volume import proxmox:root <(qvm-run -p
> --no-gui <qube> 'cat /path/proxmox-ve.raw')`. See the
> [Qubes volume docs](https://doc.qubes-os.org/en/latest/user/advanced-topics/disk-trim.html)
> and adjust to your transfer preference. For large images, importing from a
> block device or loopback in the qube is faster than a serialized cat.

### Networking (the fiddly part)

The image ships the qrexec + GUI agents but **not** the Qubes *networking*
agent (it would rewrite networking the Qubes way and fight Proxmox's `vmbr0`).
So the qube still won't auto-configure its IP — Qubes hands out a fixed IP via
point-to-point NAT (not DHCP, not a bridge), and you set it once by hand.

```bash
# dom0: find the IP/gateway Qubes assigned to this qube
qvm-ls -n        # note proxmox's IP and GATEWAY columns
```

Then **inside Proxmox** set that exact static address. Edit
`/etc/network/interfaces` so `vmbr0` (or the NIC) uses the Qubes-assigned IP,
the listed gateway, and the gateway IP as DNS:

```
auto vmbr0
iface vmbr0 inet static
        address  10.137.0.X/32      # <- IP from `qvm-ls -n`
        gateway  10.137.0.Y         # <- GATEWAY from `qvm-ls -n`
        bridge-ports ens6           # the virtio NIC name inside the guest
        bridge-stp off
        bridge-fd 0
# DNS:
#   echo "nameserver 10.137.0.Y" > /etc/resolv.conf
```

Reach the web UI at `https://<that-IP>:8006` from a qube on the same NetVM.
Default login: `root` / `proxmox` — **change it immediately**.

Later, point this qube's NetVM at a dedicated `sys-wireguard` ProxyVM to put it
(and other qubes) on your home network / Home Assistant VPN.

### The "Proxmox Web GUI" app-menu shortcut

Because the GUI agent is baked in, the image carries a
`/usr/share/applications/proxmox-web-gui.desktop` entry. To surface it in dom0's
application menu, refresh the qube's apps once after import — in **dom0**:

```bash
qvm-sync-appmenus proxmox        # or: Qube Settings -> Applications -> Refresh
```

Then "Proxmox Web GUI" appears under the qube; launching it opens the local web
interface (`https://localhost:8006`) in a chromeless Chromium window that the
dom0 WM decorates like any native app. dom0 runs it via
`qvm-run -q -a --service -- proxmox qubes.StartApp+proxmox-web-gui`.

## Building it yourself

The build runs entirely in GitHub Actions (no Proxmox host needed):

1. Download the Proxmox ISO.
2. `proxmox-auto-install-assistant prepare-iso` embeds [`answer.toml`](answer.toml)
   for a fully unattended install.
3. Packer's QEMU builder runs the installer headless → `qcow2`
   (KVM-accelerated when the runner exposes `/dev/kvm`, else TCG).
4. **Provision**: boot the qcow2 read-write and bake in the Qubes guest agents
   (`scripts/qubes-provision.sh`) so the change persists into the image.
5. **Smoke-test** the provisioned image (services-domain patterns + Qubes
   integration); a failure **gates** the next step.
6. Compress with zstd and `oras push` to GHCR.

Trigger via **Actions → Build Proxmox qcow2 → Run workflow** (pick the PVE
version), or push a `v*` tag.

### Customizing the install

- **Password / SSH key:** edit [`answer.toml`](answer.toml). Regenerate the
  password hash with `scripts/gen-answer.sh 'newpw' --write`, or uncomment
  `root-ssh-keys`.
- **Provisioning** (no-subscription repo, nag removal, Qubes agents, the app
  shortcut): [`scripts/qubes-provision.sh`](scripts/qubes-provision.sh), run by
  the provision stage. Edit it to add packages or change the shortcut.
- **PVE version:** the `pve_version` workflow input (default tracks the latest
  release).

### Local build

With Packer + QEMU + `proxmox-auto-install-assistant` installed:

```bash
proxmox-auto-install-assistant prepare-iso proxmox.iso \
  --fetch-from iso --answer-file answer.toml --output prepared.iso
packer init proxmox.pkr.hcl
packer build -var "iso_path=$PWD/prepared.iso" proxmox.pkr.hcl
# -> output-proxmox/proxmox-ve.qcow2
```

## Layout

```
answer.toml               Unattended-install answer file (PVE 8.2+ schema)
proxmox.pkr.hcl           Packer QEMU builder -> qcow2
scripts/gen-answer.sh     Regenerate the password hash
scripts/provision.sh      CI: boot the image read-write + run the bake-in script
scripts/qubes-provision.sh CI: in-guest -- no-sub repo, Qubes agents, app shortcut
scripts/smoke-test.sh     CI: boot the image headless + run the in-guest smoke
scripts/proxmox-smoke.sh  CI: in-guest assertions (API, vmbr1 NAT, LXC, NAT-out, Qubes)
.github/workflows/        CI: build -> provision -> smoke -> push to GHCR via ORAS
```

### CI: provision + smoke test

After Packer builds the qcow2, CI does two boots, both KVM-accelerated:

1. **Provision** (`scripts/provision.sh` → `scripts/qubes-provision.sh`): boots
   the real image *read-write* and bakes in the Qubes guest agents, the
   no-subscription repo, and the "Proxmox Web GUI" shortcut, then powers off so
   the changes persist into the published artifact. The networking agent is
   kept out (it would fight `vmbr0`), and the two boot-blocking Qubes units
   (`qubes-rootfs-resize`, `qubes-mount-dirs`, which wait on Xen disk names that
   don't exist on a `vda` layout) are masked.
2. **Smoke** (`scripts/smoke-test.sh` → `scripts/proxmox-smoke.sh`): boots the
   *provisioned* image against a disposable overlay and SSHes in as `root` to
   validate the *services-domain* patterns — Proxmox API alive, internal NAT
   bridge `vmbr1` up, an **unprivileged LXC container** boots on it and reaches
   its gateway + the internet (NAT-out through `vmbr0`) — and the **Qubes
   integration**: the agents are installed, the networking agent is absent, the
   boot-blockers are masked (proven by this very boot succeeding), and the app
   shortcut is a valid desktop entry.

A failure at either stage **gates the GHCR push**, so a broken image is never
published. The smoke overlay keeps the artifact pristine; LXC is
namespaces-only, so the container checks need no nested virtualization. The
`provision-log` and `smoke-log` artifacts capture the full transcripts.

## References

- [Proxmox Automated Installation](https://pve.proxmox.com/wiki/Automated_Installation)
- [Qubes: Standalones and HVMs](https://doc.qubes-os.org/en/latest/user/advanced-topics/standalones-and-hvms.html)
- [Packer QEMU builder](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu)
- [ORAS](https://oras.land/)
