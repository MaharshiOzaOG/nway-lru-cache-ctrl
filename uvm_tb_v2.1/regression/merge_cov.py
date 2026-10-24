#!/usr/bin/env python3
# ==============================================================================
#  merge_cov.py  -  merge the coverage of many test runs (no EDA tools needed)
#  Author : Maharshi Oza (mmoza@ncsu.edu)
# ------------------------------------------------------------------------------
#  Every run of the testbench writes (into the EDA Playground download):
#     cov_<test>[_<RUN_ID>].csv      group,coverpoint,bin,hits
#     summary_<test>[_<RUN_ID>].txt  result, errors, config, scoreboard numbers
#
#  Put each run's files in its own folder under results/, e.g.
#     results/smoke_seed1/   results/bp_seed1/   results/err_seed7/ ...
#  then run:
#     python3 merge_cov.py                 (looks in ./results)
#     python3 merge_cov.py path/to/results
#
#  Output:
#     - table of every run: test, run id, PASS/FAIL, errors, its own coverage
#     - merged coverage per covergroup and coverpoint (hits added together)
#     - every bin NO run has hit (the coverage holes)
#     - merged_coverage.csv (all bins, total hits, which runs hit each one)
# ==============================================================================
import csv, sys, pathlib
from collections import OrderedDict, defaultdict


def read_summary(path):
    d = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parent / "results")
    cov_files = sorted(root.rglob("cov_*.csv"))
    if not cov_files:
        print(f"No cov_*.csv files found under {root}")
        return 1

    merged = OrderedDict()                 # (group, cp, bin) -> total hits
    who    = defaultdict(list)             # (group, cp, bin) -> runs that hit it
    runs   = []

    for f in cov_files:
        run_name = f"{f.parent.name}/{f.stem[4:]}"
        hit_bins = total_bins = 0
        with f.open() as fh:
            for row in csv.DictReader(fh):
                key  = (row["group"], row["coverpoint"], row["bin"])
                hits = int(row["hits"])
                merged[key] = merged.get(key, 0) + hits
                total_bins += 1
                if hits:
                    hit_bins += 1
                    who[key].append(run_name)
        summ = {}
        sfile = f.with_name("summary_" + f.stem[4:] + ".txt")
        if sfile.exists():
            summ = read_summary(sfile)
        runs.append((run_name, summ.get("result", "?"), summ.get("uvm_errors", "?"),
                     100.0 * hit_bins / total_bins if total_bins else 0.0))

    # ---- per-run table ----------------------------------------------------
    print("\nRUNS")
    print(f"  {'run':45s} {'result':6s} {'errors':>6s} {'own cov':>8s}")
    for name, res, err, cov in runs:
        print(f"  {name:45s} {res:6s} {err:>6s} {cov:7.1f}%")
    n_fail = sum(1 for r in runs if r[1] != "PASS")
    print(f"  -> {len(runs)} run(s), {n_fail} not PASS")

    # ---- merged coverage --------------------------------------------------
    by_group = OrderedDict()
    by_cp    = OrderedDict()
    for (g, cp, b), hits in merged.items():
        by_group.setdefault(g, [0, 0])
        by_cp.setdefault((g, cp), [0, 0])
        for d, k in ((by_group, g), (by_cp, (g, cp))):
            d[k][1] += 1
            d[k][0] += 1 if hits else 0

    print("\nMERGED COVERAGE (all runs together)")
    for g, (h, t) in by_group.items():
        print(f"  {g:10s} {100.0*h/t:6.1f}%   ({h}/{t} bins)")
        for (gg, cp), (h2, t2) in by_cp.items():
            if gg == g:
                print(f"      {cp:14s} {100.0*h2/t2:6.1f}%   ({h2}/{t2})")
    h_all = sum(1 for v in merged.values() if v)
    print(f"  {'TOTAL':10s} {100.0*h_all/len(merged):6.1f}%   ({h_all}/{len(merged)} bins)")

    holes = [k for k, v in merged.items() if v == 0]
    print("\nHOLES (no run hit these bins)")
    if holes:
        for g, cp, b in holes:
            print(f"  {g}.{cp}.{b}")
    else:
        print("  none - every bin was hit by at least one run")

    out = root / "merged_coverage.csv"
    with out.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["group", "coverpoint", "bin", "total_hits", "hit_by_runs"])
        for (g, cp, b), hits in merged.items():
            w.writerow([g, cp, b, hits, " ".join(who[(g, cp, b)])])
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
