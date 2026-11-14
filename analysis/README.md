# analysis/

Scripts that turn raw measurement data from `results/` into the tables and plots of chapter 6.
They are written in phase P3/P5 and only read raw data. They never modify it.

Planned contents:

| Script | Input | Output |
|---|---|---|
| `pcap_stats.py` | pcaps captured on `pqc-wan` | per-exchange timestamps, IKE messages, IKE fragments, IP fragments, bytes |
| `runs.py` | run records from the measurement client | one tidy CSV per batch: configuration, profile, scenario, run, metrics |
| `plots.py` | tidy CSVs | figures for chapter 6 (medians with IQR/p95) |

Conventions:
- Python 3 with pandas and matplotlib, pinned in `analysis/requirements.txt`.
- Each figure is regenerated from raw data by a single command. Figures are never edited by hand.
