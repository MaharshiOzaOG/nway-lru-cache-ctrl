# cache_ctrl UVM testbench v2.1 — split version (study copy)

Author: Maharshi Oza (mmoza@ncsu.edu)

One file per class, each with a banner: what it does, inputs/outputs, timing, anything
non-textbook ("WHY THIS IS DIFFERENT / OTHER WAY") and what to watch out for. Every wait or
delay in the code is tagged `// WAIT:` or `// DELAY:` with what it waits for and why.

## Layout

```
design/rtl, design/sva      the DUT + bound assertions (unchanged)
tb/common/cache_tb_defs.sv  DUT shape, widths, clock, init_byte(), mk_addr()   (no UVM)
tb/top/cache_if.sv          cache_cpu_if (CPU + flush pins), cache_mem_if        <- read first
tb/top/tb_top.sv            clock, reset, DUT, config_db, run_test()             <- read first
tb/pkg/cache_tb_pkg.sv      includes every class below in compile order
tb/common/cache_cfg.sv      all runtime knobs; variants cache_cfg_quiet/_bp/_err picked by FACTORY OVERRIDE
tb/agents/cpu_agent/        ACTIVE   plays the CPU   (2-thread driver, get()/put())
tb/agents/flush_agent/      ACTIVE   drives flush_req/flush_inv only
tb/agents/mem_agent/        REACTIVE plays main memory (monitor -> FIFO -> responder seq)
tb/env/                     ref model (predictor), scoreboard (comparator), coverage,
                            virtual sequencer, env
tb/seq/                     CPU, flush and virtual sequences (the scenarios)
tb/tests/                   base test + one file per test
make_single.py              regenerates ../uvm_tb_single/testbench.sv
```

## Suggested reading order

1. `tb/top/tb_top.sv`, `tb/top/cache_if.sv` (clocking blocks = all the timing)
2. `tb/tests/cache_base_test.sv` → `tb/env/cache_env.sv` (draw the boxes and arrows)
3. the three items, then `cpu_drv` + `cpu_mon`
4. `mem_mon` → `mem_seqr` → `mem_resp_seq` → `mem_drv` (the reactive path)
5. `flush_drv` + `flush_mon`
6. `cache_ref_model` + `cache_scoreboard`
7. `vseq_lib.sv`, then the tests

## Tests

| Test | What it does |
| --- | --- |
| cache_smoke_test | 30 random accesses, no backpressure (default test) |
| cache_directed_test | T1–T9 with exact refill/writeback counts |
| cache_rand_test | 2000 random accesses, flush + memory compare every 500 |
| cache_bp_test | heavy backpressure on both sides, slow memory |
| cache_flush_test | flush / flush again / flush+invalidate |
| cache_flush_race_test | flushes at random moments during CPU traffic |
| cache_err_test | 5% refill and writeback errors |

## Run (VCS)

```
vcs -f filelist.f
./simv +UVM_TESTNAME=cache_smoke_test          # add +UVM_VERBOSITY=UVM_HIGH for every transaction
```

PASS = `*** TEST PASSED ***` at the end **and** no `ENV:` / `DUT:` assertion messages
(the SVA uses `$error`, which UVM does not count).

## Changing things

- Fix code here, then `python3 make_single.py` to refresh the single-file version.
- Different cache shape: edit `DUT_*` in `tb/common/cache_tb_defs.sv` (and the `cp_wstrb`
  bins in `cache_cov.sv` if DATA_W changes).
- Different traffic/timing: add a `cache_cfg` subclass in `tb/common/cache_cfg.sv` and override
  it in a test, before `super.build_phase()`:
  `cache_cfg::type_id::set_type_override(cache_cfg_bp::get_type());`
- Every test is its own simulation and starts from reset. Running them all and merging their
  coverage: see `../regression/README.md`.
