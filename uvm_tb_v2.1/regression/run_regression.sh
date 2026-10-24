#!/usr/bin/env bash
# ==============================================================================
#  run_regression.sh - run every test as its own simulation (VCS or Questa)
#  Author : Maharshi Oza (mmoza@ncsu.edu)
# ------------------------------------------------------------------------------
#  NOT usable on EDA Playground (it runs one simulation per click). Use it on a
#  machine where VCS or Questa is installed.
#
#    ./run_regression.sh vcs    [seeds...]     default seeds: 1
#    ./run_regression.sh questa [seeds...]
#
#  Each run goes to results/<test>_seed<N>/ with its log, summary_*.txt and
#  cov_*.csv, so merge_cov.py works on it exactly like on EDA Playground runs.
#  The simulator's own coverage databases are merged too (urg / vcover).
# ==============================================================================
set -u
SIM=${1:-vcs}; shift || true
SEEDS=${*:-1}
HERE=$(cd "$(dirname "$0")" && pwd)
SPLIT="$HERE/../uvm_tb_split"
RES="$HERE/results"
TESTS="cache_smoke_test cache_directed_test cache_rand_test cache_bp_test
       cache_flush_test cache_flush_race_test cache_err_test"
mkdir -p "$RES"

# ---- compile once ----------------------------------------------------------
cd "$SPLIT" || exit 1
if [ "$SIM" = vcs ]; then
  vcs -f filelist.f -cm line+cond+fsm+tgl+assert -o "$RES/simv" -l "$RES/compile.log" || exit 1
else
  vlib "$RES/work" && vlog -work "$RES/work" -sv +incdir+tb +cover \
     -L uvm design/rtl/*.sv design/sva/*.sv tb/common/cache_tb_defs.sv \
     tb/top/cache_if.sv tb/pkg/cache_tb_pkg.sv tb/top/tb_top.sv -l "$RES/compile.log" || exit 1
fi

# ---- run every test x seed, each in its own folder ------------------------
for t in $TESTS; do
  for s in $SEEDS; do
    d="$RES/${t}_seed${s}"; mkdir -p "$d"; cd "$d" || exit 1
    if [ "$SIM" = vcs ]; then
      "$RES/simv" +UVM_TESTNAME=$t +ntb_random_seed=$s +RUN_ID=seed$s +NODUMP \
        -cm line+cond+fsm+tgl+assert -cm_dir "$RES/cov.vdb" -cm_name "${t}_${s}" -l sim.log
    else
      vsim -c -lib "$RES/work" tb_top -sv_seed $s +UVM_TESTNAME=$t +RUN_ID=seed$s +NODUMP \
        -coverage -do "coverage save -onexit cov.ucdb; run -all; quit" -l sim.log
    fi
    grep -q "TEST PASSED" sim.log && echo "PASS  $t seed$s" || echo "FAIL  $t seed$s"
  done
done

# ---- merge the simulator's coverage databases ------------------------------
cd "$RES" || exit 1
if [ "$SIM" = vcs ]; then
  urg -dir cov.vdb -report urg_report && echo "merged coverage: $RES/urg_report/dashboard.html"
else
  vcover merge merged.ucdb */cov.ucdb && vcover report -summary merged.ucdb > merged_report.txt \
    && echo "merged coverage: $RES/merged_report.txt"
fi

# ---- and the simple TB-side merge (same as for EDA Playground runs) --------
python3 "$HERE/merge_cov.py" "$RES"
