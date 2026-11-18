# results/

Measurement data. **Raw data is never overwritten or edited.**

| Path | Contents | In git |
|---|---|---|
| `results/l0/` | Reports of `lab/checks/link-check.sh` (network back-end spike) | yes, small text files |
| `results/l1/` | strongSwan build report: release verification, plugins, build check, lab PKI | yes |
| `results/l2/` | Peer clones: identical binaries, addressing, path through `pqc-wan` | yes |
| `results/tunnel/` | Reports of `lab/checks/tunnel-check.sh`: one configuration end to end, decoded IKE exchanges | yes |
| `results/raw/tunnel/<run>/` | pcaps, session keys and charon logs behind each tunnel report | **no**: the keys decrypt the captures |
| `results/raw/<batch>/` | One directory per measurement batch: run records, pcaps, daemon logs, `batch.json` (configuration IDs, network profile, scenario, commit of the scripts, host and VM specs) | **no** (ignored) until a size and archiving decision is made |

Before every batch:
- stop all non-lab VMs and heavy host processes (`lab/lima/lab.sh status` warns about them);
- record the commit of `lab/` and `analysis/` in `batch.json`.
