# lab/: IKEv2 test bed for ML-KEM measurements

The test bed runs on a single laptop. It has three Linux VMs (Lima, Ubuntu 24.04 arm64) and
strongSwan 6.x built from source with ML-KEM support. Thesis chapter 4 describes it, and appendix A lists its configuration.

> **Status: draft, nothing has been run yet.** Each file is validated in the build step named
> in the table below (L0–L5). Until then, treat it as a design, not as a working tool.

## Topology

```
            pqc-left 10.10.1.0/24                        pqc-right 10.10.2.0/24
 ┌───────────────┐            ┌──────────────────────┐            ┌───────────────┐
 │    pqc-ini    │ .100  .200 │       pqc-wan        │ .200  .100 │   pqc-resp    │
 │  strongSwan   ├────────────┤ router: netem, MTU,  ├────────────┤  strongSwan   │
 │  netns "lan"  │            │ fragment filter,     │            │  netns "lan"  │
 │ 172.16.1.0/24 │            │ tcpdump (one clock)  │            │ 172.16.2.0/24 │
 └───────────────┘            └──────────────────────┘            └───────────────┘
 IKE and ESP:  10.10.1.100 <-> 10.10.2.100, always routed through pqc-wan
 Tunnel:       172.16.1.0/24 <-> 172.16.2.0/24 (site to site)
```

- `pqc-ini` and `pqc-resp` are clones of `pqc-base`, the VM where strongSwan is built once, so both peers run identical binaries.
- The hosts behind each gateway are network namespaces, not extra VMs.
- `pqc-wan` sits in the middle of the path. All impairment and all captures happen there.
- Addresses and versions live in [lab.env](lab.env).

## Layout

| Path | Purpose | Validated in |
|---|---|---|
| [lab.env](lab.env), [lib.sh](lib.sh) | Pinned versions, addressing, shared helpers | L0–L2 |
| [lima/](lima/) | VM templates and the host-side lifecycle script `lab.sh` | L0, L2 |
| [provision/build-strongswan.sh](provision/build-strongswan.sh) | Builds strongSwan from a pinned, checksummed tarball in `pqc-base` | L1 |
| [provision/strongswan-lab.conf](provision/strongswan-lab.conf) | Lab-only daemon settings: file log with ms timestamps, `save-keys` | L1 |
| [provision/setup-peer.sh](provision/setup-peer.sh), [provision/setup-wan.sh](provision/setup-wan.sh) | Addressing, routing, LAN namespaces, forwarding without offloads | L2 |
| [swanctl/](swanctl/) | Configuration matrix (C1, P512–P1024, H512–H1024), connection template, lab PKI | L3–L4 |
| [profiles/](profiles/) | Network profiles on `pqc-wan` (LAN, LTE-M-like, NB-IoT-like, MTU 1280, fragment drop) and the IoT device profile on `pqc-ini` | L0, L7 |
| [checks/](checks/) | `link-check.sh` (L0 criteria), `build-check.sh` (L1 criteria) | L0, L1 |

## Build order

All commands run on the macOS host from the repository root. `lab.sh` copies `lab/` into the VMs.

| Step | Commands | Done when |
|---|---|---|
| L0 network spike | `lab/lima/lab.sh networks`, then `base`, `peers`, `wan`; then `lab/checks/link-check.sh` | all checks PASS; report in `results/l0/` |
| L1 strongSwan | verify the release signature, pin `STRONGSWAN_SHA256` in `lab.env`; `lab/lima/lab.sh build` | `build-check.sh` PASS (ML-KEM-512/768/1024 listed) |
| L2 VMs and routing | `lab/lima/lab.sh destroy-peers`, then `peers` (re-clone with strongSwan) | `ip route get` on each peer goes via `pqc-wan` |
| L3 classical tunnel | in `pqc-resp`, then in `pqc-ini`: `sudo /opt/pqc-lab/swanctl/use.sh <role> c1`; then `sudo swanctl --initiate --child c1-lan` | ESTABLISHED; ESP seen on `pqc-wan`; ping between the namespaces |
| L4 hybrid and pure | the same with `h768`, `p768`, `p1024` | Wireshark shows IKE_INTERMEDIATE, KE sizes, IKE vs IP fragments |
| L5 rekeying | `swanctl --rekey --child`, `--rekey --ike`, `--rekey --ike --reauth`; `use.sh ... --pfs` for Child SA rekey with KE | every procedure visible in the pcap |

## Rules

- **Lab only.** The keys, the PKI and the `save-keys` plugin, which writes session keys to disk for Wireshark, must never be used on a real gateway.
- **Generated material stays out of git.** The lab PKI is generated inside the VMs (`/var/lib/pqc-lab/pki`). Raw results go under `results/raw/`, which is ignored.
- **Lab VMs only.** The scripts touch only VMs whose names start with `pqc-`. During measurement runs, stop every other VM and every heavy host process.
- **Pin and record versions.** Every version change is a commit to `lab.env` and a line in chapter 4.
