# lab/: IKEv2 test bed for ML-KEM measurements

The test bed runs on a single laptop. It has three Linux VMs (Lima, Ubuntu 24.04 arm64) and
strongSwan 6.x built from source with ML-KEM support. Thesis chapter 4 describes it, and appendix A lists its configuration.

> **Status: L0–L4 validated on 2026-11-18, L5 on 2026-11-24** (reports in [results/](../results/)).
> The files for L6–L7 (measurement client, profiles other than `lan` and `ltem`) are still a design.

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
| [checks/](checks/) | `link-check.sh` (L0 criteria), `build-check.sh` (L1 criteria), `tunnel-check.sh` (one configuration end to end, L3–L4), `rekey-check.sh` (one rekeying procedure S2–S5, L5), `ike-table.sh` (decodes a capture on `pqc-wan`, with the session keys if given) | L0–L5 |

## Build order

All commands run on the macOS host from the repository root. `lab.sh` copies `lab/` into the VMs;
run `lab/lima/lab.sh sync` after editing a script.

By hand, a configuration is activated with `sudo /opt/pqc-lab/swanctl/use.sh resp <id>` in `pqc-resp`,
the same with `ini` in `pqc-ini`, then `sudo swanctl --initiate --child <id>-lan` in `pqc-ini`.

| Step | Commands | Done when |
|---|---|---|
| L0 network spike | `lab/lima/lab.sh networks`, then `base`, `peers`, `wan`; then `lab/checks/link-check.sh` | all checks PASS; report in `results/l0/` |
| L1 strongSwan | verify the release signature, pin `STRONGSWAN_SHA256` in `lab.env`; `lab/lima/lab.sh base`, then `build` | `build-check.sh` PASS (ML-KEM-512/768/1024 listed) |
| L2 VMs and routing | `lab/lima/lab.sh destroy-peers` (type `delete`), then `peers` (re-clone with strongSwan); `lab/checks/link-check.sh` again | identical binaries on both peers; `ip route get` on each peer goes via `pqc-wan` |
| L3 classical tunnel | `lab/checks/tunnel-check.sh c1` | ESTABLISHED; ESP seen on `pqc-wan`; ping and iperf3 between the namespaces |
| L4 hybrid and pure | `lab/checks/tunnel-check.sh h768`, then `p768`, `p1024` | the decoded capture shows IKE_INTERMEDIATE, the KE sizes, IKE fragments for the hybrid and IP fragments for P1024 |
| L5 rekeying | `lab/checks/rekey-check.sh <id> s2` (Child SA rekey without KE), `s3` (with KE: `use.sh ... --pfs`), `s4` (IKE SA rekey), `s5` (reauthentication); for `c1`, `p768` and `h768` | every procedure visible in the decrypted pcap: S3 and S4 of a hybrid add one IKE_FOLLOWUP_KE per additional key exchange (RFC 9370 §2.2.4); a pure ML-KEM rekey stays in one IKE-fragmented CREATE_CHILD_SA |

## Rules

- **Lab only.** The keys, the PKI and the `save-keys` plugin, which writes session keys to disk for Wireshark, must never be used on a real gateway.
- **Generated material stays out of git.** The lab PKI is generated inside the VMs (`/var/lib/pqc-lab/pki`). Raw results go under `results/raw/`, which is ignored.
- **Lab VMs only.** The scripts touch only VMs whose names start with `pqc-`. During measurement runs, stop every other VM and every heavy host process.
- **Pin and record versions.** Every version change is a commit to `lab.env` and a line in chapter 4.
  The OS packages do not change by themselves: `provision/freeze-packages.sh` (run by `lab.sh base`
  and the setup scripts) masks the apt timers and turns unattended-upgrades off, which is acceptable
  only because the lab is isolated. Every report header lists the kernel and the relevant package
  versions of each VM, and warns when the two peers differ. Upgrade by hand, between campaigns.
- **Clocks.** NTP gets no answer through the `user-v2` networks, and a VM's clock stands still while
  the host sleeps. `lab/lima/lab.sh clock` sets every lab VM from the host clock; `tunnel-check.sh`
  does it before each run. Durations never mix clocks: they come from one pcap or one client.
- **Network state.** The lab addresses, the routes via `pqc-wan` and the blackhole routes are also
  written as systemd-networkd drop-ins (`/etc/systemd/network/10-netplan-<if>.network.d/50-pqc-lab.conf`),
  so a restart of networkd keeps them. Without the drop-ins, networkd drops them as foreign on every
  restart; unattended-upgrades restarted it on 2026-11-19. `tunnel-check.sh` and `link-check.sh`
  first run `lab/lima/lab.sh net-check` and refuse to start without that state, because a run on a
  broken path still writes a plausible report. After a VM reboot, `lab/lima/lab.sh net` restores
  the state, including the namespaces.
- **Wireshark elsewhere.** The key files from `/var/lib/pqc-lab/wireshark` work in Wireshark 4.x
  after two adjustments, which `ike-table.sh` makes itself: AES-GCM entries in `esp_sa` need `NULL`
  authentication and the ICV length in the name, and with RFC 9370 the IKE table holds one line per
  key generation for the same SPIs, while Wireshark uses one line per SPI pair.
