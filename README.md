# proxmox-qubes-image

Build a **bare [Proxmox VE](https://www.proxmox.com/) `qcow2`** suitable for running as a
**standalone HVM under [Qubes OS](https://www.qubes-os.org/)**, and publish it to GHCR so
others (and future-you on dedicated hardware) can `oras pull` it instead of
sitting through a 20-minute ISO install.

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

A bare HVM has **no Qubes tools**, so it won't auto-configure its IP. Qubes
hands out a fixed IP via point-to-point NAT (not DHCP, not a bridge).

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

## Building it yourself

The build runs entirely in GitHub Actions (no Proxmox host needed):

1. Download the Proxmox ISO.
2. `proxmox-auto-install-assistant prepare-iso` embeds [`answer.toml`](answer.toml)
   for a fully unattended install.
3. Packer's QEMU builder runs the installer headless → `qcow2`
   (KVM-accelerated when the runner exposes `/dev/kvm`, else TCG).
4. Compress with zstd and `oras push` to GHCR.

Trigger via **Actions → Build Proxmox qcow2 → Run workflow** (pick the PVE
version), or push a `v*` tag.

### Customizing the install

- **Password / SSH key:** edit [`answer.toml`](answer.toml). Regenerate the
  password hash with `scripts/gen-answer.sh 'newpw' --write`, or uncomment
  `root-ssh-keys`.
- **First-boot tweaks** (no-subscription repo, nag removal):
  [`scripts/first-boot.sh`](scripts/first-boot.sh) — wire it in per the comment
  at the top of that file.
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
answer.toml              Unattended-install answer file (PVE 8.2+ schema)
proxmox.pkr.hcl          Packer QEMU builder -> qcow2
scripts/first-boot.sh    Optional first-boot hook (repos, nag)
scripts/gen-answer.sh    Regenerate the password hash
scripts/smoke-test.sh    CI: boot the image headless + run the in-guest smoke
scripts/proxmox-smoke.sh CI: in-guest assertions (API, vmbr1 NAT, LXC, NAT-out)
.github/workflows/       CI: build -> smoke-test -> push to GHCR via ORAS
```

### CI smoke test

After Packer builds the qcow2, CI boots it headless (KVM) against a disposable
overlay and SSHes in as `root` to validate the *services-domain* patterns the
image exists for: the Proxmox API is alive, an internal NAT bridge `vmbr1`
comes up, an **unprivileged LXC container** boots on it, and that container
reaches both its gateway and the internet (NAT-out through `vmbr0`). A failure
**gates the GHCR push**, so a broken image is never published. The overlay
keeps the published artifact pristine. LXC is namespaces-only, so this needs no
nested virtualization -- it validates exactly the container workloads the Qubes
HVM can run. The full transcript uploads as the `smoke-log` artifact.

## References

- [Proxmox Automated Installation](https://pve.proxmox.com/wiki/Automated_Installation)
- [Qubes: Standalones and HVMs](https://doc.qubes-os.org/en/latest/user/advanced-topics/standalones-and-hvms.html)
- [Packer QEMU builder](https://developer.hashicorp.com/packer/integrations/hashicorp/qemu/latest/components/builder/qemu)
- [ORAS](https://oras.land/)
