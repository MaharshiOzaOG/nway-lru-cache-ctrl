# Cache Controller UVM Testbench v2.1

UVM 1.2 testbench for the parameterized N-way set-associative write-back / write-allocate cache controller.
Author: Maharshi Oza

| Folder | Contents |
|---|---|
| `uvm_tb_split/` | Source: RTL (`design/rtl`), SVA checker (`design/sva`), UVM testbench (`tb/`), docs (`docs/`) |
| `uvm_tb_single/` | Two-file version (`design.sv` + `testbench.sv`) for EDA Playground |
| `regression/` | Test plan (`testplan.csv`), coverage merge (`merge_cov.py`), regression script |

**Testbench:** CPU agent, flush agent, reactive memory agent (TLM analysis FIFO), scoreboard with reference model,
functional coverage, SVA checks split into ENV_ (testbench) and DUT_ assertions.

**Tests** (each its own run, config set by factory override): `cache_smoke_test`, `cache_directed_test`,
`cache_rand_test`, `cache_bp_test`, `cache_flush_test`, `cache_flush_race_test`, `cache_err_test`.

**Run (EDA Playground, UVM 1.2):** `+UVM_TESTNAME=<test> +RUN_ID=seed1`.
Pass = `*** TEST PASSED ***` and no `ENV:` / `DUT:` messages in the log. See `regression/README.md` for coverage merging.

**Status:** `cache_err_test` passes on Questa (0 UVM errors, 0 mismatches). Other tests not yet run on v2.1.
