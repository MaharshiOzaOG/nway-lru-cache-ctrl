# regression/ — running all tests and merging coverage (v2.1)

Author: Maharshi Oza (mmoza@ncsu.edu)

Kept separate from the testbench code on purpose. Nothing here is compiled.

| File | What |
| --- | --- |
| `testplan.csv` | the test plan (open in Excel); fill the Status column as you go |
| `merge_cov.py` | merges the coverage of many runs — needs only Python 3 |
| `run_regression.sh` | runs every test with VCS or Questa (for later; not for EDA Playground) |
| `results/` | put each run's downloaded files here, one folder per run |

## EDA Playground flow (what you can do today)

For each test in `testplan.csv`:
1. Run options: `+UVM_TESTNAME=<test> +RUN_ID=seed1` (change the tag for repeat runs).
2. Tick **Download files after run** (allow pop-ups for edaplayground.com).
3. Unzip the download into its own folder, e.g. `results/cache_bp_test_seed1/`.
   It contains the log, `summary_<test>_seed1.txt` and `cov_<test>_seed1.csv`.

Then on your laptop:
```
cd regression
python3 merge_cov.py
```
It prints every run's PASS/FAIL, the coverage of ALL runs together (per covergroup and
coverpoint), the bins no run has hit, and writes `results/merged_coverage.csv`.

Logs are never merged: each stays in its own run folder.

## Machine with VCS or Questa (later)

```
./run_regression.sh vcs 1 2 3        # every test x seeds 1,2,3
./run_regression.sh questa 1
```
Same folder layout, plus the simulator's own coverage merge (`urg` / `vcover merge`).
This script could not be run here (no simulator available), so expect to adjust tool options.
