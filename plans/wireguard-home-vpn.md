# Plan: home-VPN peer-to-peer (Proxmox + personal) via the HA WireGuard add-on

Status: **in progress** (2026-06-06). Image side baked + in CI; HA add-on side
needs the user (token can't reach the Supervisor API).

## Decision (supersedes the earlier `sys-wireguard` shared-gateway idea)

**Per-peer, not a shared gateway.** Each thing that needs a presence on the home
VPN runs its own WireGuard client = its own tunnel IP on the HA add-on subnet
(`172.27.66.0/24`). A shared `sys-wireguard` ProxyVM would NAT every downstream
qube behind one tunnel IP (same invisibility as sys-net's NAT today) and only
earns its cost when a qube must route traffic *for others* — which neither
Proxmox nor personal needs.

| Peer | Mechanism | Tunnel IP (default) | When |
|---|---|---|---|
| Proxmox host | `wg-quick@wg0` on the host, baked into image | 172.27.66.4 | always-on |
| personal qube | `wg-quick` inside the AppVM, `/rw`-persisted | 172.27.66.3 | only when roaming (at home use sys-net directly) |
| HA | the WG add-on (server/hub) | 172.27.66.1 | always |

### Why this respects "don't circumvent sys-firewall"
WG is **outbound-initiated**; sys-firewall allows outbound by default; the tunnel
is bidirectional once up; inner HA→Proxmox traffic rides *inside* the trusted
outbound UDP flow. No inbound rule, no inter-qube `qvm-firewall` exception ever.

### naming ≠ routing (two independent problems)
- **Naming** (AdGuard, the HA add-on): DNS rewrites map `proxmox.home.arpa →
  172.27.66.4`. Use `.home.arpa` (RFC 8375) — never `.lan`/`.local`.
- **Routing/advertisement**: a LAN client still needs a route `172.27.66.0/24 via
  192.168.178.38` (HA is the only host that knows the tunnel). AdGuard DHCP can't
  reliably push it (option 121 flaky, Android ignores) → **one static route on the
  Fritz!Box**. This is the "advertise themselves" piece; DNS alone won't do it.

## Image changes (DONE, in CI)
`scripts/qubes-provision.sh` stage **4d**: install `wireguard-tools` (NOT dkms —
module is built into the PVE kernel), ship a placeholder `/etc/wireguard/wg0.conf`
(`Address = 172.27.66.4/24`, `PrivateKey = __WG_PRIVATE_KEY__`, MTU 1380 + MSS
clamp, ip_forward for LXC routing), and a **user-run** `/usr/sbin/wg-setup-key`
helper that the operator invokes ONCE post-deploy to generate the keypair and
splice in the private key (**no secret is ever baked, AND none is auto-generated —
CI boots the very qcow2 it publishes, so a first-boot keygen oneshot would leak a
real key into the public artifact; hence a user-run helper, not a systemd unit**).
Leaves `wg-quick@wg0` **disabled** (no server pubkey yet → would fail-loop). Not
Xen-gated (must work on future bare metal). `scripts/proxmox-smoke.sh` 5g2 asserts
all of the above incl. "no baked/auto-generated key, no wg-genkey.service".

## personal qube (DONE locally, staged in `~/wg-personal/`)
Keypair generated (X25519 via python `cryptography`, no wireguard-tools needed).
- public key: `ef+C8AHn2fdy12GubVo6kPL0hKyTYAmj9OvR8L2AaAI=`
- `wg0.conf` complete: Address 172.27.66.3/24, [Peer] filled (server pubkey +
  endpoint). Bring up with `wg-quick up /rw/config/wg0.conf` when roaming.

## What needs the user (token can't reach the Supervisor/add-on API — 401)
HA add-on peer config lives behind the Supervisor API; the LLAT is Core-scope.

1. **HA WireGuard add-on UI** → two peers (DONE 2026-06-06, IPs below):
   - `personal` — pubkey `ef+C8AHn2fdy12GubVo6kPL0hKyTYAmj9OvR8L2AaAI=`,
     `addresses: [172.27.66.3]` ✅ added.
   - `proxmox` — `addresses: [172.27.66.4]` ✅ added, **pubkey still TODO**
     (run `wg-setup-key` on Proxmox after re-import, then paste the printed key).
   - server public key `Ca1v7+61kPvd955BlZ19Lx/XbtxWLNCIA8UfeKTEzTM=`, port 51820.
     Deliberately NOT baked into the image (the image `[Peer]` keeps
     `__HA_SERVER_PUBLIC_KEY__` + `__HA_ENDPOINT__` placeholders): the user plans
     to switch the endpoint to a PUBLIC address so the tunnel works while roaming,
     and the operator's address shouldn't ship in a public artifact. Both are
     spliced post-deploy by `wg-setup-key <SERVER_PUBKEY> <ENDPOINT>`.
2. **Router static route** (gateway `192.168.178.1`) → `172.27.66.0/24` via
   `192.168.178.38`. NOTE: the router is NOT a Fritz!Box (serves a Vite/React SPA,
   lighttpd) — model TBD; see "Router" below. Needed so LAN clients other than HA
   can reach the tunnel subnet. NOT required for HA↔Proxmox itself (HA is the WG
   hub, already knows the route).
3. **AdGuard** → DNS rewrites `proxmox.home.arpa → 172.27.66.4` (+ services later).

## Sequence
1. CI green on the WG image → rebuild/pull v8-wg, dom0 re-import (stream over qrexec).
2. Proxmox post-boot: `wg-setup-key <SERVER_PUBKEY> <ENDPOINT>` → generates the
   host key, splices key+peer, prints the host public key. Register that as the
   `proxmox` peer's pubkey in the HA add-on (peer + IP already added).
3. `systemctl enable --now wg-quick@wg0` on Proxmox; `wg-quick up
   /rw/config/wg0.conf` on personal when roaming.
4. Verify HA→Proxmox (`172.27.66.4:8006`) and personal→Proxmox; then the
   container-automation trial via the Proxmox API (`proxmoxer`).
5. (Optional, for other LAN clients) router static route + AdGuard names above.

## Router (gateway 192.168.178.1)
NOT a Fritz!Box — probed 2026-06-06: lighttpd/1.4.67 serving a Vite/React SPA
(`/vite.svg`, `/index.js`, `<div id="root">`), empty `<title>`, no `tr64desc.xml`
on :49000, `jason_boxinfo.xml` returns the SPA. Could be a custom/OpenWrt-LuCI-
replacement UI, a pfSense/OPNsense-style box, or an ISP unit with a React UI.
To add the static route the user needs to ID it (browse to http://192.168.178.1,
check the login/brand) — then: pfSense/OPNsense → System ▸ Routing ▸ Static
Routes; OpenWrt → Network ▸ Routing ▸ Static IPv4; generic → look for
"Static routes"/"LAN routes". Destination `172.27.66.0/24`, gateway
`192.168.178.38`. Only needed for LAN clients beyond HA.

## Notes
- HA Proxmox *integration* is monitor + power-toggle only (can't create
  containers) — deferred. Container creation = Proxmox API directly.
- Exposing services *inside* LXCs over the tunnel = route the container subnet
  (add to `client_allowed_ips` + host ip_forward, already enabled) — second step.
