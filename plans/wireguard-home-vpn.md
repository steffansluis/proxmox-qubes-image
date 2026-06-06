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
| Proxmox host | `wg-quick@wg0` on the host, baked into image | 172.27.66.3 | always-on |
| personal qube | `wg-quick` inside the AppVM, `/rw`-persisted | 172.27.66.2 | only when roaming (at home use sys-net directly) |
| HA | the WG add-on (server/hub) | 172.27.66.1 | always |

### Why this respects "don't circumvent sys-firewall"
WG is **outbound-initiated**; sys-firewall allows outbound by default; the tunnel
is bidirectional once up; inner HA→Proxmox traffic rides *inside* the trusted
outbound UDP flow. No inbound rule, no inter-qube `qvm-firewall` exception ever.

### naming ≠ routing (two independent problems)
- **Naming** (AdGuard, the HA add-on): DNS rewrites map `proxmox.home.arpa →
  172.27.66.3`. Use `.home.arpa` (RFC 8375) — never `.lan`/`.local`.
- **Routing/advertisement**: a LAN client still needs a route `172.27.66.0/24 via
  192.168.178.38` (HA is the only host that knows the tunnel). AdGuard DHCP can't
  reliably push it (option 121 flaky, Android ignores) → **one static route on the
  Fritz!Box**. This is the "advertise themselves" piece; DNS alone won't do it.

## Image changes (DONE, in CI)
`scripts/qubes-provision.sh` stage **4d**: install `wireguard-tools` (NOT dkms —
module is built into the PVE kernel), ship a placeholder `/etc/wireguard/wg0.conf`
(`PrivateKey = __WG_PRIVATE_KEY__`, MTU 1380 + MSS clamp, ip_forward for LXC
routing), a `wg-genkey.service` first-boot oneshot that generates a UNIQUE keypair
iff absent and splices it in (**no secret is ever baked — repo+image are public**),
and leaves `wg-quick@wg0` **disabled** (no server pubkey yet → would fail-loop).
Not Xen-gated (must work on future bare metal). `scripts/proxmox-smoke.sh` 5g2
asserts all of the above incl. "no baked privatekey".

## personal qube (DONE locally, staged in `~/wg-personal/`)
Keypair generated (X25519 via python `cryptography`, no wireguard-tools needed).
- public key: `ef+C8AHn2fdy12GubVo6kPL0hKyTYAmj9OvR8L2AaAI=`
- `wg0.conf` templated (needs the HA server pubkey + confirmed assigned IP).

## What needs the user (token can't reach the Supervisor/add-on API — 401)
HA add-on peer config lives behind the Supervisor API; the LLAT is Core-scope.

1. **HA WireGuard add-on UI** → add two peers:
   - `proxmox` — pubkey = (read from Proxmox `/etc/wireguard/publickey` after
     first boot of the new image), `addresses: [172.27.66.3]`,
     `allowed_ips: [172.27.66.3/32]`, `client_allowed_ips:
     [172.27.66.0/24, 192.168.178.0/24]` (+ the LXC container subnet later).
   - `personal` — pubkey `ef+C8AHn2fdy12GubVo6kPL0hKyTYAmj9OvR8L2AaAI=`,
     `addresses: [172.27.66.2]`, `client_allowed_ips:
     [172.27.66.0/24, 192.168.178.0/24]`.
   - note the add-on's **server public key**, **host**, **port** (default 51820)
     and the **actual assigned IPs/subnet** (defaults assumed above).
2. **Fritz!Box** → static route `172.27.66.0/24` via `192.168.178.38`.
3. **AdGuard** → DNS rewrites `proxmox.home.arpa → 172.27.66.3` (+ services later).
4. Fill `__HA_SERVER_PUBLIC_KEY__` / endpoint in both wg0.confs.

## Sequence
1. CI green on the WG image → rebuild/pull v8-wg, dom0 re-import (stream over qrexec).
2. Proxmox first boot generates its key → read `/etc/wireguard/publickey`.
3. User adds both peers in the add-on + Fritz route + AdGuard names (above).
4. Fill peer blocks; `systemctl enable --now wg-quick@wg0` on Proxmox;
   `wg-quick up /rw/config/wg0.conf` on personal when roaming.
5. Verify HA→Proxmox (`172.27.66.3:8006`) and personal→Proxmox; then the
   container-automation trial via the Proxmox API (`proxmoxer`).

## Notes
- HA Proxmox *integration* is monitor + power-toggle only (can't create
  containers) — deferred. Container creation = Proxmox API directly.
- Exposing services *inside* LXCs over the tunnel = route the container subnet
  (add to `client_allowed_ips` + host ip_forward, already enabled) — second step.
