# nway-lru-cache-ctrl
Parameterised N-way set-associative write-back/write-allocate cache controller with true LRU in SystemVerilog. Self-checking testbench with reference model, SVA checks and coverage.

# nway-lru-cache-ctrl

Parameterised **N-way set-associative, write-back / write-allocate, blocking L1 cache controller** with **true LRU** replacement, written in SystemVerilog. It comes with a self-checking testbench that has a reference model, SVA protocol checks and a coverage summary.

A direct-mapped version of the same controller is included as the starting point.

## Features

- Parameterised: address width, data width, words per line, number of sets, number of ways
- Write-back and write-allocate; only dirty victims are written back
- True LRU: per-set rank per way (0 = most recent, `WAYS-1` = least recent)
- Victim choice: first invalid way, otherwise the LRU way
- Four-state FSM: `IDLE → COMPARE → (WRITE_BACK →) ALLOCATE → COMPARE`
- Readable 3-block FSM style: state register, next-state logic, output logic, with datapath flops driven by one-cycle strobes
- Valid/ready CPU request interface, one-cycle response pulse, line-wide memory interface

## Address split

```
addr = [ tag | index | word | byte ]
```

| Field | Width |
|---|---|
| byte | `$clog2(DATA_W/8)` |
| word | `$clog2(LINE_WORDS)` |
| index | `$clog2(NUM_SETS)` |
| tag | the rest |

## FSM

```
IDLE --cpu_req_valid--> COMPARE --hit--> IDLE
                          | miss & victim dirty  -> WRITE_BACK --mem_rsp_valid--> ALLOCATE
                          | miss & victim clean  -------------------------------> ALLOCATE
ALLOCATE --mem_rsp_valid--> COMPARE      (re-check: now a hit, so a store miss becomes a store hit)
```

- A hit answers in one cycle (`cpu_rsp_valid` the cycle after the request is accepted).
- A miss waits for memory. A dirty miss pays memory latency twice: writeback, then fill.
- The memory request is held stable until `mem_rsp_valid`.

## Parameters

| Parameter | `cache_ctrl_assoc` default | Meaning |
|---|---|---|
| `ADDR_W` | 32 | address bits |
| `DATA_W` | 32 | CPU word bits |
| `LINE_WORDS` | 4 | words per cache line |
| `NUM_SETS` | 16 | number of sets |
| `WAYS` | 4 | ways per set (2 or more) |

The direct-mapped `cache_ctrl_interview` has no `WAYS` parameter and defaults to `NUM_SETS = 64`.

## Ports

| Group | Signals |
|---|---|
| Clock/reset | `clk`, `rst_n` (async, active low) |
| CPU request | `cpu_req_valid`, `cpu_req_ready`, `cpu_req_we`, `cpu_req_addr`, `cpu_req_wdata` |
| CPU response | `cpu_rsp_valid` (1-cycle pulse), `cpu_rsp_rdata` |
| Memory request | `mem_req_valid`, `mem_req_we` (1 = writeback), `mem_req_addr` (line aligned), `mem_req_wdata` (whole line) |
| Memory response | `mem_rsp_valid`, `mem_rsp_rdata` (whole line) |

`mem_req_wdata` and `mem_rsp_rdata` are `LINE_WORDS*DATA_W` bits wide because memory always moves one full line.

## Repository layout

```
rtl/
  cache_assoc_3blk.sv      N-way + LRU controller, module cache_ctrl_assoc   <- main design
  design_3blk.sv           direct-mapped controller, module cache_ctrl_interview
tb/
  tb_cache_assoc_full.sv   full self-checking testbench (top module: tb)
old/                       earlier single-block versions, kept for reference
  cache_assoc.sv
  design.sv
  tb_cache_assoc.sv
  testbench.sv
```

> Compile only **one** file per module name. `cache_assoc.sv` and `cache_assoc_3blk.sv` both define `cache_ctrl_assoc`, and `design.sv` and `design_3blk.sv` both define `cache_ctrl_interview`.

## How to run

**Questa / ModelSim**
```
vlog -sv rtl/cache_assoc_3blk.sv tb/tb_cache_assoc_full.sv
vsim -c tb -do "run -all; quit"
```

**EDA Playground**
- Simulator: Questa (the testbench uses SVA, so Icarus will not work)
- Design pane: `cache_assoc_3blk.sv`
- Testbench pane: `tb_cache_assoc_full.sv`
- Top entity: `tb`

A good run ends with:
```
TEST PASSED
```

## Verification

The testbench checks every access automatically:

- **Reference model:** a per-set LRU list of tags and dirty bits predicts hit or miss, whether a writeback is due, and which line is the victim.
- **Truth memory:** every CPU read is compared with the value that word should hold.
- **Memory log:** every request the cache sends is checked for count, order, address and writeback data.
- **Timing:** a hit must answer in the next cycle, and a miss must not.
- **SVA and procedural checks, every cycle:** no X on control outputs, one-cycle `cpu_rsp_valid`, memory request held stable until the response, writeback data held stable, line-aligned memory addresses, no response without a request, no memory request while `cpu_req_ready` is high.
- **Memory model:** random latency, one-cycle response pulse, and `mem_rsp_rdata` driven to X when not valid so that sampling at the wrong time is caught.

### Directed tests

| Test | Corner case |
|---|---|
| T0 | Reset: outputs idle, inputs ignored during reset |
| T1 | Cold miss |
| T2 | Hits on other words, last word, unaligned byte offsets (byte bits ignored) |
| T3 | Fill every way of a set with no eviction, then hit every way |
| T4 | Exact LRU order; a touch changes the victim |
| T5 | Store hit: no memory traffic, same word twice, every word of a line |
| T6 | Store miss (write-allocate): rest of the line comes from memory |
| T7 | All-dirty set: every eviction writes back the right line and data |
| T8 | Clean eviction: no writeback |
| T9 | Mixed dirty/clean set: only dirty victims are written back |
| T10 | LRU thrash: `WAYS+1` tags round-robin, every access misses |
| T11 | Address extremes: tag all 1s, highest set, last word, `FFFFFFFF` |
| T12 | Memory latency of 1 and 20 cycles |
| T13 | Reset in the middle of a miss: everything invalid afterwards |
| T14 | 5000 random operations with random latency, scrambled CPU inputs while idle, request held valid while busy |
| T15 | Working set that fits (`WAYS-1` tags per set): only cold misses, hit rate must be 90% or more |

### Coverage

At the end the testbench prints hits and misses for reads and stores, free fills, clean evictions, dirty writebacks, hits and fills per way, and cycles per FSM state. A goal that was never reached counts as a failure.

### Results

On Questa 2025.2: **0 errors, `TEST PASSED`**. The working-set test (T15) reaches a hit rate of about **97.7%**. The directed and random tests are miss-heavy on purpose, to stress eviction, writeback and LRU.

## Design notes and known limits

- **Blocking:** one miss stalls everything. There is no hit-under-miss and no MSHRs.
- **Re-compare:** every miss passes through `COMPARE` twice, so a miss costs one extra cycle. Filling and responding in the same step would remove it.
- **No response backpressure:** `cpu_rsp_valid` is a one-cycle pulse and the CPU is assumed to take it. There is no `cpu_rsp_ready`.
- **No memory backpressure:** memory is assumed to answer when `mem_rsp_valid` pulses.
- **Storage is flops, not SRAM:** this is fine for a small cache and not for a large one.
- **Word writes only:** there are no byte-strobes, so sub-word stores are not supported.

## Possible next steps

- Port the testbench to UVM (agent, scoreboard and coverage)
- Add `cpu_rsp_ready` and memory backpressure
- Add byte-strobes for sub-word stores
- Replace true LRU with tree pseudo-LRU for higher associativity
- Fill and respond in one step to remove the re-compare cycle
