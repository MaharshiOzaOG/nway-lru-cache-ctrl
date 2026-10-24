# cache_ctrl UVM test plan (v1, blocking DUT)

Author: Maharshi Oza (mmoza@ncsu.edu)

## Checks that run in every test

| Check | Where | Fails when |
| --- | --- | --- |
| Load data | scoreboard | any predictable byte of `rsp_rdata` differs from the reference model |
| Error flag | scoreboard | `rsp_err` ≠ (refill error OR writeback error during that access) |
| Echo | scoreboard | `rsp_we` ≠ request `we` |
| Memory image | scoreboard, after every flush | any byte of main memory ≠ reference model (unknown lines skipped) |
| Flush error | scoreboard | `flush_err` ≠ any writeback error during that flush |
| Response ids | cpu_mon | response with no matching request, or id reused while in flight |
| Hang | cpu_mon | no response after `cfg.rsp_timeout` cycles |
| Nothing left over | cpu_mon, mem_mon | requests still waiting at end of test |
| Protocol (TB side) | SVA ENV_* | drivers break valid/ready or flush rules |
| Protocol / design (DUT) | SVA DUT_* | DUT breaks its own rules |

## Tests

| # | Test | Goal | Config (factory override) | Pass criteria |
| --- | --- | --- | --- | --- |
| 1 | cache_smoke_test | environment works | cache_cfg_quiet, 30 ops | all checks clean |
| 2 | cache_directed_test | T1–T9 from the plain TB | cache_cfg | data correct + exact refill/writeback counts; hit latency = 2; error flags |
| 3 | cache_rand_test | broad random stress | cache_cfg, 2000 ops, flush every 500 | all checks clean |
| 4 | cache_bp_test | backpressure both sides | cache_cfg_bp (25% ready, 5–20 cycle latency) | all checks clean, no stability SVA |
| 5 | cache_flush_test | flush semantics | cache_cfg | 2nd flush and 2nd flush+inv do nothing; memory matches |
| 6 | cache_flush_race_test | flush while a CPU request waits | cache_cfg, 8 random flushes in parallel | all checks clean; cov `cpu_waiting` hit |
| 7 | cache_err_test | refill + writeback errors | cache_cfg_err (5% / 5%) | error flags right, unknown lines skipped, no hangs |

## Directed steps (cache_directed_test)

| Step | Action | Expected refills / writebacks |
| --- | --- | --- |
| T1 | cold load, then same-line loads | 1/0, then 0/0 |
| T2 | store hits: word, byte, upper half; read back | 0/0 |
| T3 | store miss (write-allocate), read line back | 1/0, then 0/0 |
| T4 | fill set 3, touch A0, new line, re-load A1, A4, A2 | 4/0, 0/0, 1/0, 1/0, 0/0, 1/0 (true LRU) |
| T5 | 4 dirty lines in set 4, new line, old line back | 4/0, 1/1, 1/1 |
| T6 | load hit with rsp_ready always 1 | latency = 2 cycles |
| T7 | forced refill error on load miss / store miss | err = 1, nothing installed, store not applied |
| T8 | flush, flush again, load | ≥1 writeback, then 0/0, then hit |
| T9 | dirty a line, flush+invalidate, reload | 0/1, then misses |

## Coverage goals (cache_cov)

- load/store × hit / clean miss / dirty miss
- word offset 0–3; byte-enable patterns (one byte, half, word)
- CPU response backpressure: none / some / many cycles
- memory refill/writeback × ok/error; memory backpressure; latency fast/mid/slow
- flush with/without invalidate × ok/error; flush racing a waiting CPU request

## Known limits (v1)

- Memory traffic is matched to CPU accesses by time window (valid only because the DUT is
  blocking). v2 must match by line address / id.
- Hit/miss counts are only checked exactly in the directed test.
- Default DUT configuration only (DUT parameters are compile-time).

The same plan as a spreadsheet: `../../regression/testplan.csv`.
