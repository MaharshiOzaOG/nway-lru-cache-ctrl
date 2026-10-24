# cache_ctrl UVM testbench v2.1 — single-file version (for running)

Author: Maharshi Oza (mmoza@ncsu.edu)

Generated from `../uvm_tb_split` by `make_single.py` (comments removed). Do not edit by hand.

## EDA Playground

1. Left pane (`design.sv`): paste `design.sv`.
2. Right pane (`testbench.sv`): paste `testbench.sv`.
3. Tools & Simulators: **Synopsys VCS**. UVM / OVM: **UVM 1.2**.
4. Run options (optional):
   - `+UVM_TESTNAME=cache_smoke_test` — pick a test (default: `cache_smoke_test`)
   - `+RUN_ID=seed1` — tag for the result files `summary_<test>_seed1.txt` / `cov_<test>_seed1.csv`
   - `+UVM_VERBOSITY=UVM_HIGH` — print every transaction
   - `+NODUMP` — no waveform file;  `+DUMP_ALL` — dump everything incl. DUT internals (default dumps only the pins + DUT top level)
5. Tick "Open EPWave after run" for waves.

Tests: `cache_smoke_test`, `cache_directed_test`, `cache_rand_test`, `cache_bp_test`,
`cache_flush_test`, `cache_flush_race_test`, `cache_err_test`.
Each is a separate run from reset. To collect and merge all runs: `../regression/README.md`.

**Pass** = `*** TEST PASSED ***` near the end of the log **and** no `ENV:` / `DUT:` assertion
messages anywhere in the log.

Suggested first run: `cache_smoke_test`. Tick "Download files after run" to keep the result files.
