# results/

Measurement data. **Raw data is never overwritten or edited.**

| Path | Contents | In git |
|---|---|---|
| `results/l0/` | Reports of `lab/checks/link-check.sh` (network back-end spike) | yes, small text files |
| `results/raw/<batch>/` | One directory per measurement batch: run records, pcaps, daemon logs, `batch.json` (configuration IDs, network profile, scenario, commit of the scripts, host and VM specs) | **no** (ignored) until a size and archiving decision is made |

Before every batch:
- stop all non-lab VMs and heavy host processes (`lab/lima/lab.sh status` warns about them);
- record the commit of `lab/` and `analysis/` in `batch.json`.
