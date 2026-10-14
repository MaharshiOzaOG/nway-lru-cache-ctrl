# nway-lru-cache-ctrl

An **N-way set-associative, write-back / write-allocate, blocking L1 cache controller** with **true LRU** replacement, written in SystemVerilog as a readable **3-block FSM**, plus a **self-checking testbench** with a reference model, SVA protocol checks and coverage.

This repository is the **RTL + directed/random verification** stage of a larger project. The next stage is a full **UVM testbench** for the same controller (see [Roadmap](#roadmap)).

| File | What it is |
|---|---|
| `rtl/cache_assoc_3blk.sv` | The design, module `cache_ctrl_assoc` |
| `tb/tb_cache_assoc_full.sv` | The testbench, top module `tb` |

---

## Contents

1. [Scope](#scope)
2. [Quick start](#quick-start)
3. [Parameters](#parameters)
4. [Input/output signals](#inputoutput-signals)
5. [How an address is split](#how-an-address-is-split)
6. [What the cache stores](#what-the-cache-stores)
7. [The 3-block FSM](#the-3-block-fsm)
8. [Hit and victim logic](#hit-and-victim-logic)
9. [LRU: how it is checked and when it is updated](#lru-how-it-is-checked-and-when-it-is-updated)
10. [Walkthroughs: what happens on each kind of access](#walkthroughs-what-happens-on-each-kind-of-access)
11. [The testbench](#the-testbench)
12. [Limitations](#limitations)
13. [Roadmap](#roadmap)

---

## Scope

### What this project covers

- **Organisation:** N-way set-associative cache. The number of ways, sets, words per line and data width are all parameters.
- **Write policy:** write-back (a store only updates the cache; memory is updated when the line is evicted) and write-allocate (a store miss first brings the line into the cache).
- **Replacement:** true LRU per set, with invalid ways always used before evicting anything.
- **Control:** a 4-state FSM written in the 3-block style (state register, next-state logic, output logic), with all array and register updates driven by one-cycle strobes.
- **Interfaces:** a valid/ready CPU request, a one-cycle CPU response, and a line-wide memory interface that holds its request until memory answers.
- **Verification:** a self-checking SystemVerilog testbench with a reference cache model, a truth memory, a memory transaction log, SVA protocol assertions, 16 directed corner-case tests, 5000 random operations, and a coverage report with goals.

### What it does not do (yet)

| Not supported | What that means in practice |
|---|---|
| Non-blocking operation | One miss stalls the cache. No hit-under-miss, no miss queue (MSHRs). |
| CPU response backpressure | `cpu_rsp_valid` is a one-cycle pulse. The CPU must take it; there is no `cpu_rsp_ready`. |
| Memory backpressure | Memory is assumed to accept the request and answer once with `mem_rsp_valid`. There is no `mem_req_ready`. |
| Sub-word stores | Stores always write a whole `DATA_W` word. There are no byte enables. |
| Fast miss path | After a fill the FSM re-runs `COMPARE`, which costs one extra cycle per miss. |
| Coherence | Single cache, single CPU. No snooping, no invalidation from outside. |
| Flush / invalidate commands | Dirty lines only reach memory when they are evicted. |
| SRAM macros | Tags and data are flip-flop arrays, which is fine for a small cache only. |
| Scalable LRU | True LRU stores `WAYS × log2(WAYS)` bits per set; practical up to about 8 ways. |
| UVM | The current testbench is a plain SystemVerilog testbench. UVM is the next stage. |

---

## Quick start

**EDA Playground**
- Simulator: **Questa** (the testbench uses SVA, so Icarus Verilog will not work)
- Design pane: `cache_assoc_3blk.sv`
- Testbench pane: `tb_cache_assoc_full.sv`
- Top entity: `tb`

**Questa / ModelSim command line**
```
vlog -sv rtl/cache_assoc_3blk.sv tb/tb_cache_assoc_full.sv
vsim -c tb -do "run -all; quit"
```

A good run ends with:
```
T15 hits=1953 misses=47  hit rate=97.7%  (cold misses allowed <= 48)
...
TEST PASSED
```

---

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_W` | 32 | Bits in an address |
| `DATA_W` | 32 | Bits in one CPU word |
| `LINE_WORDS` | 4 | Words in one cache line |
| `NUM_SETS` | 16 | Number of sets |
| `WAYS` | 4 | Lines per set (2 or more) |

With the defaults: one line is 4 × 32 = 128 bits (16 bytes), and the cache holds 16 sets × 4 ways = 64 lines = 1 KB of data.

Derived widths inside the design:

| Name | Formula | Default | Meaning |
|---|---|---|---|
| `LINE_W` | `DATA_W × LINE_WORDS` | 128 | Bits in one line |
| `BYTE_W` | `log2(DATA_W/8)` | 2 | Bits to pick a byte inside a word |
| `WORD_W` | `log2(LINE_WORDS)` | 2 | Bits to pick a word inside a line |
| `OFF_W` | `BYTE_W + WORD_W` | 4 | Bits to pick a byte inside a line |
| `IDX_W` | `log2(NUM_SETS)` | 4 | Bits to pick a set |
| `TAG_W` | `ADDR_W − OFF_W − IDX_W` | 24 | Bits that identify which line lives in a way |
| `WAY_W` | `log2(WAYS)` | 2 | Bits to name a way |

---

## Input/output signals

Think of the cache as a box with the **CPU on the left** and **main memory on the right**.

```
            +----------------------------+
  CPU  ---> |                            | ---> Main
 side  <--- |      cache_ctrl_assoc      | <--- memory
            |                            |
            +----------------------------+
```

### Clock and reset

| Signal | Dir | Width | In simple terms |
|---|---|---|---|
| `clk` | in | 1 | The clock. Everything updates on its rising edge. |
| `rst_n` | in | 1 | Reset, active low, asynchronous. While it is 0 the cache forgets everything (all lines invalid) and goes to `IDLE`. |

### CPU request (CPU → cache)

| Signal | Dir | Width | In simple terms |
|---|---|---|---|
| `cpu_req_valid` | in | 1 | "I have a request for you." |
| `cpu_req_ready` | out | 1 | "I can take a request now." High only in `IDLE`. A request is accepted on a clock edge where both `valid` and `ready` are high. |
| `cpu_req_we` | in | 1 | 1 = store (write), 0 = load (read). |
| `cpu_req_addr` | in | `ADDR_W` | Byte address the CPU wants. |
| `cpu_req_wdata` | in | `DATA_W` | The word to store. Ignored for loads. |

The cache copies these inputs into internal registers when it accepts a request, so the CPU is free to change them afterwards.

### CPU response (cache → CPU)

| Signal | Dir | Width | In simple terms |
|---|---|---|---|
| `cpu_rsp_valid` | out | 1 | "Your request is done." A single-cycle pulse, for loads and for stores. |
| `cpu_rsp_rdata` | out | `DATA_W` | The word that was loaded. Only meaningful when `cpu_rsp_valid` is high and the request was a load. |

### Memory request (cache → memory)

| Signal | Dir | Width | In simple terms |
|---|---|---|---|
| `mem_req_valid` | out | 1 | "Memory, I need something." Held high until memory answers. |
| `mem_req_we` | out | 1 | 1 = writeback (save a dirty line to memory), 0 = fill (read a line from memory). |
| `mem_req_addr` | out | `ADDR_W` | Start address of the line. Always line aligned (offset bits are 0). |
| `mem_req_wdata` | out | `LINE_W` | The whole line being written back. Only meaningful when `mem_req_we` is 1. |

### Memory response (memory → cache)

| Signal | Dir | Width | In simple terms |
|---|---|---|---|
| `mem_rsp_valid` | in | 1 | "Done." A one-cycle pulse. For a writeback it means the line is saved; for a fill it means the data is on `mem_rsp_rdata`. |
| `mem_rsp_rdata` | in | `LINE_W` | The whole line that was read. Only meaningful during a fill when `mem_rsp_valid` is high. |

Memory signals are a whole line wide because the cache always moves one complete line at a time: it fills a whole line on a miss and writes back a whole line on eviction.

---

## How an address is split

```
 31                     8 7      4 3    2 1    0
+------------------------+--------+------+------+
|          tag           | index  | word | byte |
|        24 bits         | 4 bits |2 bits|2 bits|
+------------------------+--------+------+------+
```

| Field | Used for |
|---|---|
| `index` | Which set to look in. |
| `tag` | Compared with the tag stored in every way of that set to find a hit. |
| `word` | Which word of the line to read or write. |
| `byte` | Ignored. The cache reads and writes whole words, so addresses `…08`, `…09`, `…0A` and `…0B` all return the same word. |

The offset (`word` + `byte`) counts **bytes**, not bits: `OFF_W = log2(line size in bytes)`.

---

## What the cache stores

For every set `s` and way `w`:

| Array | Width | Reset? | Meaning |
|---|---|---|---|
| `tag_q[s][w]` | `TAG_W` | no | Which address is in this way. |
| `data_q[s][w]` | `LINE_W` | no | The line itself. |
| `valid_q[s][w]` | 1 | yes, to 0 | This way holds a real line. |
| `dirty_q[s][w]` | 1 | yes, to 0 | This line was changed by a store and memory is out of date. |
| `age_q[s][w]` | `WAY_W` | yes, to `w` | LRU rank: 0 = most recently used, `WAYS−1` = least recently used. |

Tags and data are not reset because `valid_q = 0` already says they are meaningless.

The captured request is also stored, because a miss takes many cycles and the CPU pins are only guaranteed during the accept cycle:

| Register | Meaning |
|---|---|
| `req_we_q`, `req_addr_q`, `req_wdata_q` | Copy of the accepted request. |
| `req_tag`, `req_idx`, `req_woff` | Slices of `req_addr_q` (wires, not registers). |

---

## The 3-block FSM

### Why 3 blocks

The controller is split so that each question has exactly one place in the code to look:

| Question | Where to look |
|---|---|
| What state am I in? | **Block 1**, the state register. `state_q` changes nowhere else. |
| Where do I go next? | **Block 2**, next-state logic (`always_comb`). |
| What do I drive in this state? | **Block 3**, output logic (`always_comb`). Every output defaults to 0, so each state only lists what it does. |
| What actually changes in storage? | **Block 4**, datapath flops. They only obey the strobes from block 3. |

The FSM never writes the arrays directly. Block 3 raises a **strobe** ("do this now") for one cycle, and block 4 performs the update at the next clock edge. Combinational logic decides *whether and what*; the clock edge commits it.

```
                inputs, hit, victim_dirty, mem_rsp_valid
                          |
                          v
  +---------+     +--------------+     +---------------+     +-----------------+
  | Block 1 |---->|   Block 2    |     |    Block 3    |---->|     Block 4     |
  | state_q |<----| next state   |     | outputs +     |     | datapath flops  |
  +---------+     | (state_d)    |     | strobes       |     | (arrays, LRU,   |
       |          +--------------+     +---------------+     |  request regs)  |
       +------------------------------------^                +-----------------+
```

### States

| State | Meaning |
|---|---|
| `IDLE` | Waiting for a CPU request. The only state where `cpu_req_ready` is high. |
| `COMPARE` | Look up the captured address. On a hit, answer the CPU and finish. On a miss, decide whether a writeback is needed. |
| `WRITE_BACK` | Send the dirty victim line to memory and wait until memory says it is saved. |
| `ALLOCATE` | Read the requested line from memory and wait for it. When it arrives, install it into the victim way. |

### Transitions (block 2)

```
            cpu_req_valid
   IDLE ---------------------> COMPARE
    ^                            |
    |  hit                       | miss
    +----------------------------+------------------------------+
                                 |                              |
                     victim dirty|                victim clean  |
                                 v                  or invalid  |
                            WRITE_BACK                          |
                                 | mem_rsp_valid                |
                                 v                              v
                             ALLOCATE <-------------------------+
                                 | mem_rsp_valid
                                 v
                             COMPARE   (now a hit)
```

The `COMPARE` decision is a nested priority:

```systemverilog
COMPARE : if (hit)                state_d = IDLE;        // 1st: is it here?
          else if (victim_dirty)  state_d = WRITE_BACK;  // 2nd: must I save the old line?
          else                    state_d = ALLOCATE;    // 3rd: just fetch the new one
```

`WRITE_BACK` and `ALLOCATE` both wait on `if (mem_rsp_valid)`. That is a **stall**: until memory answers, `state_d = state_q` and the FSM stays put, holding its memory request. Leaving earlier would drop the writeback before it is saved, or fill the cache before the data has arrived.

After `ALLOCATE` the FSM goes back to `COMPARE` instead of straight to `IDLE`. The new line is now present, so this second compare is a hit and uses exactly the same hit path: a load returns its data, and a store writes its word and sets dirty. That is how a store miss turns into a store hit without separate logic.

### Outputs and strobes per state (block 3)

| State | Ports driven | Strobes raised |
|---|---|---|
| `IDLE` | `cpu_req_ready = 1` | `capture_req = cpu_req_valid` |
| `COMPARE`, hit, load | `cpu_rsp_valid = 1` | `lru_touch = 1`, `touch_way = hit_way` |
| `COMPARE`, hit, store | `cpu_rsp_valid = 1` | `lru_touch`, `touch_way = hit_way`, `write_word = 1`, `set_dirty = 1` |
| `COMPARE`, miss | (nothing) | (nothing) |
| `WRITE_BACK` | `mem_req_valid = 1`, `mem_req_we = 1`, `mem_req_addr = {old tag of victim, idx, 0}` | (nothing) |
| `ALLOCATE` | `mem_req_valid = 1`, `mem_req_we = 0`, `mem_req_addr = {req_tag, idx, 0}` | when `mem_rsp_valid`: `fill_line = 1`, `lru_touch = 1`, `touch_way = victim_way` |

Two outputs are plain data wires, valid whenever they are used:
- `cpu_rsp_rdata = data_q[req_idx][hit_way]`, word `req_woff`
- `mem_req_wdata = data_q[req_idx][victim_way]`

`cpu_rsp_valid` depends on `hit` as well as the state, so it is a Mealy-style output. The rest depend only on the state, apart from the fill strobes, which also wait for `mem_rsp_valid`.

### Strobes and what block 4 does with them

| Strobe | Raised in | Block 4 action at the next clock edge |
|---|---|---|
| `capture_req` | `IDLE` with `cpu_req_valid` | Copy `cpu_req_we/addr/wdata` into `req_we_q/addr_q/wdata_q`. |
| `write_word` | `COMPARE`, store hit | Write `req_wdata_q` into word `req_woff` of `data_q[idx][hit_way]`. |
| `set_dirty` | `COMPARE`, store hit | `dirty_q[idx][hit_way] = 1`. |
| `fill_line` | `ALLOCATE` with `mem_rsp_valid` | `data_q[idx][victim_way] = mem_rsp_rdata`, `tag_q = req_tag`, `valid = 1`, `dirty = 0`. |
| `lru_touch` + `touch_way` | `COMPARE` hit, `ALLOCATE` fill | Make `touch_way` the most recently used (see LRU below). |

Block 4 is split by reset needs:
- **4a** request registers (reset)
- **4b** `valid_q`, `dirty_q`, `age_q` (reset)
- **4c** `tag_q`, `data_q` (no reset)

### Internal signals at a glance

| Signal | Kind | Meaning |
|---|---|---|
| `state_q` / `state_d` | reg / comb | Current state / next state. |
| `hit` | comb | The captured tag is valid in some way of the set. |
| `hit_way` | comb | Which way hit. |
| `victim_way` | comb | Which way will be replaced on a miss. |
| `victim_dirty` | comb | The victim is valid and dirty, so a writeback is needed. |
| `found_inv` | comb | The set has at least one invalid way. |
| `capture_req`, `write_word`, `set_dirty`, `fill_line`, `lru_touch`, `touch_way` | comb | Strobes from block 3 to block 4. |

---

## Hit and victim logic

Both are combinational helpers that the FSM reads. They look only at the set selected by `req_idx`.

### Hit: is the line here, and in which way?

```systemverilog
hit = 0;  hit_way = 0;
for (w = 0; w < WAYS; w++)
  if (valid_q[idx][w] && tag_q[idx][w] == req_tag) begin
    hit = 1;  hit_way = w;
  end
```

All ways are compared in parallel in hardware. `valid` is checked first because the tag of an invalid way is garbage. At most one way can match, because a line is never installed twice.

### Victim: on a miss, which way gets replaced?

A two-step priority:

```systemverilog
// step 1: any empty way?  take the FIRST one
found_inv = 0;  victim_way = 0;
for (w = 0; w < WAYS; w++)
  if (!valid_q[idx][w] && !found_inv) begin
    found_inv = 1;  victim_way = w;
  end

// step 2: only if the set is full, take the least recently used way
if (!found_inv)
  for (w = 0; w < WAYS; w++)
    if (age_q[idx][w] == WAYS-1) victim_way = w;

victim_dirty = valid_q[idx][victim_way] && dirty_q[idx][victim_way];
```

- **Step 1** gives free slots to new lines without evicting anything. The `!found_inv` check makes sure the first invalid way wins and later ones cannot overwrite it.
- **Step 2** runs only when every way is valid. Exactly one way has age `WAYS−1`, and that is the victim.
- **`victim_dirty`** tells the FSM whether it must go through `WRITE_BACK`. An invalid victim is never dirty, so empty slots skip the writeback.

`victim_way` stays the same through `WRITE_BACK` and `ALLOCATE`, because `valid_q` and `age_q` for that set do not change until the fill. So the way that was written back is exactly the way that gets filled.

---

## LRU: how it is checked and when it is updated

### The idea

Each way in a set holds a rank in `age_q`:

- `0` = most recently used
- `WAYS−1` = least recently used, the next victim

The ranks in a set are always a permutation of `0 … WAYS−1`: no duplicates and no gaps.

### How it is checked (read)

Only in step 2 of the victim logic: "which way currently has rank `WAYS−1`?" That is a simple equality compare per way, done in parallel.

### When it is updated

`age_q` is state that must survive from cycle to cycle, so it lives in flip-flops and is updated in block 4 at a clock edge. The decision to update is combinational, in block 3:

| Event | State | `touch_way` |
|---|---|---|
| A hit (load or store) | `COMPARE` | `hit_way` |
| A fill arrives from memory | `ALLOCATE` with `mem_rsp_valid` | `victim_way` |

A miss itself does not touch the LRU. The fill does.

### How it is updated

When way `t` is touched:

1. Every way whose rank is **smaller** (more recent) than `t`'s rank gets older by 1.
2. Way `t` becomes rank 0.

```systemverilog
if (lru_touch) begin
  for (w = 0; w < WAYS; w++)
    if (age_q[idx][w] < age_q[idx][touch_way])
      age_q[idx][w] <= age_q[idx][w] + 1;
  age_q[idx][touch_way] <= 0;
end
```

Ways that were already older than `t` keep their rank, so the permutation is preserved.

### Worked example (4 ways)

Ranks shown as `[way0 way1 way2 way3]`:

| Step | Event | Ranks after | Next victim |
|---|---|---|---|
| reset | | `[0 1 2 3]` | (invalid ways first) |
| fill way 0 | touch 0 (rank 0) | `[0 1 2 3]` | |
| fill way 1 | touch 1 (rank 1) | `[1 0 2 3]` | |
| fill way 2 | touch 2 (rank 2) | `[2 1 0 3]` | |
| fill way 3 | touch 3 (rank 3) | `[3 2 1 0]` | way 0 |
| hit way 0 | touch 0 (rank 3) | `[0 3 2 1]` | way 1 |
| miss, fill way 1 | touch 1 (rank 3) | `[1 0 3 2]` | way 2 |
| hit way 0 | touch 0 (rank 1) | `[0 1 3 2]` | way 2 |

The last row shows that touching a way only ages the ways that were more recent than it (way 1 here); way 2 and way 3 keep their ranks.

### Two details worth knowing

- **Reset values matter.** Ranks reset to `0, 1, 2, 3`, not all zeros. All zeros would mean no way has rank `WAYS−1` and the ranks would not be a permutation, so the victim logic could pick wrongly.
- **The double touch on a miss is harmless.** A miss touches the filled way in `ALLOCATE`, then the re-compare hits the same way and touches it again. It is already rank 0, so no way has a smaller rank, nobody ages, and the second touch changes nothing.

---

## Walkthroughs: what happens on each kind of access

Cycle counts below are "cycles after the request is accepted until `cpu_rsp_valid`" and use the testbench memory model, where memory takes `L` cycles.

| Access | Path | Extra cycles |
|---|---|---|
| Load hit | `IDLE → COMPARE(hit) → IDLE` | 0 (answer in the next cycle) |
| Store hit | same, plus `write_word` and `set_dirty`. No memory traffic. | 0 |
| Clean miss (load or store) | `COMPARE → ALLOCATE → COMPARE(hit) → IDLE` | `L + 3` (6 when `L = 3`) |
| Dirty miss | `COMPARE → WRITE_BACK → ALLOCATE → COMPARE(hit) → IDLE` | `2L + 5` (11 when `L = 3`) |

**Store miss, step by step (write-allocate):**
1. `IDLE`: request captured, `req_we_q = 1`.
2. `COMPARE`: miss. If the victim is dirty, go to `WRITE_BACK`; otherwise go to `ALLOCATE`.
3. `WRITE_BACK` (if needed): old line sent to memory at the old line's address; wait for `mem_rsp_valid`.
4. `ALLOCATE`: whole new line read from memory; on `mem_rsp_valid` it is installed, marked valid and clean, and its LRU rank becomes 0.
5. `COMPARE` again: now a hit. Because `req_we_q = 1`, the store word is written and the line is marked dirty. `cpu_rsp_valid` pulses.

The whole line is fetched before the word is written so that the other words in the line hold correct data.

---

## The testbench

`tb_cache_assoc_full.sv` (top module `tb`) is fully self-checking: every access is predicted, checked and counted, and the run ends with `TEST PASSED` or `TEST FAILED (n errors)`.

### Structure

```
                 +-------------------+
   tests T0-T15  |  access() task    |  predict -> drive -> wait -> check
   ------------> |                   |
                 +---------+---------+
                           |
          +----------------+-----------------+
          v                v                 v
  reference cache    truth memory       CPU driver
  model (LRU lists)  (ref_mem + bmem)   (valid/ready)
                                             |
                                             v
                                      +-------------+       +----------------+
                                      |    DUT      |<----->|  memory model  |
                                      | cache_ctrl_ |       |  (latency L,   |
                                      |   assoc     |       |   logs every   |
                                      +-------------+       |   request)     |
                                             ^              +----------------+
                                             |
                               SVA + procedural protocol checks
```

### What is checked on every access

| Check | How |
|---|---|
| Hit or miss | A **reference cache model** keeps, per set, a list of `{tag, dirty}` from oldest to newest. Before each access it predicts hit or miss, whether the victim is dirty, and which line is evicted. A predicted hit must answer in the very next cycle; a predicted miss must not. |
| Memory traffic | The memory model logs every request. A hit must cause none. A clean miss must cause exactly one fill at the right line address. A dirty miss must cause a writeback of the right victim line, with the right data, followed by the fill. |
| Read data | A **truth memory** holds the value every word should have. Every load is compared against it. |
| Writeback data | The expected victim line is rebuilt from the truth memory and compared word for word. |

### Protocol checks (every cycle)

| Check | Kind |
|---|---|
| No X on `cpu_req_ready`, `cpu_rsp_valid`, `mem_req_valid` | SVA |
| `cpu_rsp_valid` is a one-cycle pulse | SVA |
| No memory request while `cpu_req_ready` is high | SVA |
| Memory request and address held stable until `mem_rsp_valid` | SVA |
| Writeback data held stable until `mem_rsp_valid` | SVA |
| Memory address is line aligned | SVA |
| No X in writeback data or in `cpu_rsp_rdata` when used | SVA |
| No response without a request; not ready while a request is outstanding | procedural |

### Memory model

- Latency is set per test (1 to 20 cycles, or random 1 to 8).
- `mem_rsp_valid` is a one-cycle pulse.
- `mem_rsp_rdata` is driven to **X** whenever it is not valid, so the cache sampling it at the wrong time shows up as X data and fails.
- The backing memory is sparse, so any 32-bit address works.

### Tests

| Test | Corner case | What must happen |
|---|---|---|
| T0 | Reset | No memory request or response during reset; ready afterwards; inputs ignored |
| T1 | Cold miss in set 0 | Miss with one fill |
| T2 | Other words, last word, unaligned byte offsets | All hits; byte bits ignored |
| T3 | Fill all ways of one set | 4 misses with no eviction, then 4 hits |
| T4 | LRU order | The touched line survives; the oldest is evicted |
| T5 | Store hits | No memory traffic; last write wins; every word writable |
| T6 | Store miss (write-allocate) | Stored word plus the rest of the line from memory |
| T7 | All-dirty set | Every eviction writes back the right line and data; data comes back later |
| T8 | Clean eviction | No writeback |
| T9 | Mixed dirty and clean | Only dirty victims written back |
| T10 | LRU thrash with `WAYS+1` tags | Every access misses |
| T11 | Tag all 1s, highest set, last word, `FFFFFFFF` | Correct hits and data at the address extremes |
| T12 | Memory latency 1 and 20 | Correct behaviour at both extremes, including dirty misses |
| T13 | Reset in the middle of a miss | Everything invalid afterwards; unsaved dirty data is lost |
| T15 | Working set that fits (`WAYS−1` tags per set) | Only cold misses; hit rate at least 90% |
| T14 | 5000 random operations | Random latency, CPU inputs scrambled while idle, requests held valid while busy |

### Coverage

The run prints hits and misses for loads and stores, free fills, clean evictions, dirty writebacks, response latency range, hits and fills per way, and cycles per FSM state. Each of these has a goal (for example, every way must be hit and filled at least once). A missed goal counts as an error.

### Results

On Questa 2025.2:

```
T15 hits=1953 misses=47  hit rate=97.7%  (cold misses allowed <= 48)
read  hits=2596  misses=2194
store hits=1246  misses=1064
fills into free way=102  clean evictions=1769  dirty writebacks=1387
TEST PASSED
```

The directed and random tests are miss-heavy on purpose, to stress eviction, writeback and LRU. T15 shows the cache with realistic locality.

---

## Limitations

These follow from the scope above and are the main design trade-offs:

- **Blocking:** while a miss is being handled, the cache accepts nothing else.
- **Re-compare cycle:** every miss passes through `COMPARE` twice.
- **No backpressure:** neither the CPU response nor the memory interface can stall.
- **Whole-word stores only.**
- **Flop-based storage and true LRU:** fine for small, low-associativity caches; not for large ones.
- **Testbench peeks inside the DUT:** the coverage counters read `dut.state_q`, `dut.hit_way` and `dut.victim_way`, so renaming those signals requires updating the testbench.

---

## Roadmap

### Next stage: UVM testbench

The current testbench already contains the pieces a UVM environment needs; the plan is to move them into UVM components:

| Current testbench piece | UVM equivalent |
|---|---|
| CPU driver tasks | CPU agent: sequencer, driver, monitor |
| Memory model | Memory agent (reactive slave) with configurable latency |
| Reference cache model + truth memory | Scoreboard with a predictor |
| Directed tests T0–T15 | Sequences and tests |
| Random test | Constrained-random sequences |
| Coverage counters | `covergroup`s: hit/miss × load/store, writeback, way, LRU rank, latency |
| SVA checks | Interface assertions, attached with `bind` |

### Design extensions

- `cpu_rsp_ready` and `mem_req_ready` backpressure
- Byte enables for sub-word stores
- Remove the re-compare cycle (respond directly from the fill)
- Tree pseudo-LRU for 8 or more ways
- Non-blocking operation with a small miss queue
- Flush and invalidate commands
