`timescale 1ns/1ps
//=============================================================================
//  FULL self-checking testbench for cache_ctrl_assoc   (top module: tb)
//  Works with cache_assoc.sv OR cache_assoc_3blk.sv (paste only ONE of them).
//
//  HOW IT CHECKS (every single access, automatically)
//  --------------------------------------------------
//   1. REFERENCE CACHE MODEL  (mdl)  : per-set LRU list of {tag, dirty}.
//      Before each access it PREDICTS:  hit or miss?  writeback? of which line?
//   2. TRUTH MEMORY  (ref_mem + bmem): the value every word SHOULD have.
//   3. MEMORY LOG    (mlog)          : every request the DUT really sent.
//   After each access the TB compares:
//      - hit/miss            (a hit must answer in the very next cycle)
//      - memory traffic      (exact count, order, addresses, writeback data)
//      - read data           (against truth memory)
//   4. PROTOCOL CHECKERS (SVA + procedural) run every cycle.
//   5. COVERAGE summary at the end: every way hit, every way evicted, etc.
//
//  CORNER CASES COVERED (one task each, see "TEST LIST" at the bottom)
//   T0  reset: outputs idle, inputs ignored during reset
//   T1  cold miss, lowest set, word 0
//   T2  hit on other words, LAST word, unaligned byte offsets (byte bits ignored)
//   T3  fill every way of a set with no eviction, then hit every way
//   T4  exact LRU order, and "touch changes the victim"
//   T5  store hit: no memory traffic, same word twice, every word of a line
//   T6  store MISS (write-allocate): rest of the line must come from memory
//   T7  all-dirty set: every eviction writes back the right line + data
//   T8  clean eviction: NO writeback
//   T9  mixed dirty/clean in one set: only dirty victims written back
//   T10 LRU thrash: WAYS+1 tags round-robin -> 100% misses
//   T11 address extremes: tag = all 1s, highest set, last word
//   T12 memory latency extremes: 1 cycle and 20 cycles
//   T13 reset in the middle of a miss: everything invalid afterwards
//   T14 random traffic: random latency, CPU bus noise while idle,
//       request held valid while the cache is busy
//   T15 working set that fits (WAYS-1 tags per set): only cold misses,
//       hit rate must be >= 90%   (runs before T14)
//=============================================================================
module tb;

  //---------------------------------------------------------------------------
  // Parameters (must match what you pass to the DUT)
  //---------------------------------------------------------------------------
  localparam int ADDR_W     = 32;
  localparam int DATA_W     = 32;
  localparam int LINE_WORDS = 4;
  localparam int NUM_SETS   = 16;
  localparam int WAYS       = 4;

  localparam int LINE_W = DATA_W * LINE_WORDS;
  localparam int BYTE_W = $clog2(DATA_W/8);
  localparam int WORD_W = $clog2(LINE_WORDS);
  localparam int OFF_W  = BYTE_W + WORD_W;
  localparam int IDX_W  = $clog2(NUM_SETS);
  localparam int TAG_W  = ADDR_W - OFF_W - IDX_W;

  typedef logic [ADDR_W-1:0] addr_t;
  typedef logic [DATA_W-1:0] data_t;
  typedef logic [LINE_W-1:0] line_t;

  //---------------------------------------------------------------------------
  // Clock / reset / DUT
  //---------------------------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic   cpu_req_valid = 0;
  logic   cpu_req_ready;
  logic   cpu_req_we    = 0;
  addr_t  cpu_req_addr  = '0;
  data_t  cpu_req_wdata = '0;
  logic   cpu_rsp_valid;
  data_t  cpu_rsp_rdata;
  logic   mem_req_valid;
  logic   mem_req_we;
  addr_t  mem_req_addr;
  line_t  mem_req_wdata;
  logic   mem_rsp_valid;
  line_t  mem_rsp_rdata;

  cache_ctrl_assoc #(
    .ADDR_W(ADDR_W), .DATA_W(DATA_W), .LINE_WORDS(LINE_WORDS),
    .NUM_SETS(NUM_SETS), .WAYS(WAYS)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .cpu_req_valid(cpu_req_valid), .cpu_req_ready(cpu_req_ready),
    .cpu_req_we(cpu_req_we), .cpu_req_addr(cpu_req_addr), .cpu_req_wdata(cpu_req_wdata),
    .cpu_rsp_valid(cpu_rsp_valid), .cpu_rsp_rdata(cpu_rsp_rdata),
    .mem_req_valid(mem_req_valid), .mem_req_we(mem_req_we),
    .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
    .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata)
  );

  //---------------------------------------------------------------------------
  // Bookkeeping
  //---------------------------------------------------------------------------
  int  errors  = 0;
  bit  verbose = 1;          // print every directed access

  function automatic void check(bit cond, string msg);
    if (!cond) begin
      errors++;
      $display("[%0t] FAIL: %s", $time, msg);
      if (errors > 30) begin
        $display("Too many errors, stopping.");
        $finish;
      end
    end
  endfunction

  //---------------------------------------------------------------------------
  // Address helpers
  //---------------------------------------------------------------------------
  function automatic addr_t line_addr(addr_t a);   // zero the offset
    return {a[ADDR_W-1:OFF_W], {OFF_W{1'b0}}};
  endfunction

  function automatic addr_t word_addr(addr_t a);   // zero the byte bits
    return {a[ADDR_W-1:BYTE_W], {BYTE_W{1'b0}}};
  endfunction

  // build an address from (tag, set, word)
  function automatic addr_t A(longint unsigned tag, int set, int word);
    return {TAG_W'(tag), IDX_W'(set), WORD_W'(word), {BYTE_W{1'b0}}};
  endfunction

  //---------------------------------------------------------------------------
  // Backing memory (sparse: any 32-bit address works) + truth model
  //---------------------------------------------------------------------------
  line_t bmem    [addr_t];     // key = line address   (what memory REALLY holds)
  data_t ref_mem [addr_t];     // key = word address   (what CPU last wrote)

  function automatic data_t pattern(addr_t wa);     // initial content of a word
    return data_t'(wa) ^ data_t'(32'h5EED_0000);
  endfunction

  function automatic line_t mem_line_read(addr_t la);
    line_t l;
    if (bmem.exists(la)) return bmem[la];
    for (int w = 0; w < LINE_WORDS; w++)
      l[w*DATA_W +: DATA_W] = pattern(la + addr_t'(w*(DATA_W/8)));
    return l;
  endfunction

  // the value a word SHOULD have right now
  function automatic data_t truth_read(addr_t a);
    line_t l;
    int    w;
    if (ref_mem.exists(word_addr(a))) return ref_mem[word_addr(a)];
    l = mem_line_read(line_addr(a));
    w = a[BYTE_W +: WORD_W];
    return l[w*DATA_W +: DATA_W];
  endfunction

  function automatic line_t truth_line(addr_t la);
    line_t l;
    for (int w = 0; w < LINE_WORDS; w++)
      l[w*DATA_W +: DATA_W] = truth_read(la + addr_t'(w*(DATA_W/8)));
    return l;
  endfunction

  //---------------------------------------------------------------------------
  // Memory model: latency lat_min..lat_max, one-cycle mem_rsp_valid pulse.
  // mem_rsp_rdata is X whenever it is not valid (catches sampling bugs).
  // Every accepted request is logged in mlog for the scoreboard.
  //---------------------------------------------------------------------------
  typedef struct { bit we; addr_t addr; line_t data; } mtx_t;
  mtx_t mlog[$];

  int    lat_min = 3, lat_max = 3;
  logic  busy;
  int    cnt;
  logic  l_we;
  addr_t l_addr;
  line_t l_wdata;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; cnt <= 0;
      mem_rsp_valid <= 1'b0; mem_rsp_rdata <= 'x;
      l_we <= 1'b0; l_addr <= '0; l_wdata <= '0;
    end else begin
      mem_rsp_valid <= 1'b0;
      mem_rsp_rdata <= 'x;
      if (busy) begin
        if (cnt <= 1) begin
          busy          <= 1'b0;
          mem_rsp_valid <= 1'b1;
          if (l_we) bmem[l_addr] = l_wdata;                // commit writeback
          else      mem_rsp_rdata <= mem_line_read(l_addr); // return the line
        end else
          cnt <= cnt - 1;
      end
      else if (mem_req_valid && !mem_rsp_valid) begin
        busy    <= 1'b1;
        cnt     <= $urandom_range(lat_min, lat_max);
        l_we    <= mem_req_we;
        l_addr  <= mem_req_addr;
        l_wdata <= mem_req_wdata;
        mlog.push_back('{mem_req_we, mem_req_addr, mem_req_wdata});
      end
    end
  end

  //---------------------------------------------------------------------------
  // Reference cache model: per set, a list of lines, OLDEST first.
  //   hit  -> move line to the back (most recent), set dirty on a store
  //   miss -> if set full: pop the front (LRU) = victim; push the new line
  //---------------------------------------------------------------------------
  typedef struct { logic [TAG_W-1:0] tag; bit dirty; } mline_t;
  mline_t mdl [NUM_SETS][$];

  function automatic void mdl_access(input addr_t a, input bit we,
                                     output bit hit, output bit evict,
                                     output bit wb, output addr_t wb_la);
    int               s;
    logic [TAG_W-1:0] tag;
    mline_t           e;
    s     = a[OFF_W +: IDX_W];
    tag   = a[ADDR_W-1 -: TAG_W];
    hit   = 0; evict = 0; wb = 0; wb_la = '0;

    for (int i = 0; i < mdl[s].size(); i++)
      if (mdl[s][i].tag == tag) begin
        e = mdl[s][i];
        mdl[s].delete(i);
        if (we) e.dirty = 1;
        mdl[s].push_back(e);
        hit = 1;
        return;
      end

    if (mdl[s].size() == WAYS) begin            // set full -> evict LRU
      e     = mdl[s].pop_front();
      evict = 1;
      if (e.dirty) begin
        wb    = 1;
        wb_la = {e.tag, IDX_W'(s), {OFF_W{1'b0}}};
      end
    end
    e.tag = tag; e.dirty = we;                   // store miss -> dirty after fill
    mdl[s].push_back(e);
  endfunction

  function automatic void mdl_reset();
    for (int s = 0; s < NUM_SETS; s++) mdl[s].delete();
  endfunction

  //---------------------------------------------------------------------------
  // Coverage counters
  //---------------------------------------------------------------------------
  int n_rd_hit, n_wr_hit, n_rd_miss, n_wr_miss;
  int n_wb, n_clean_evict, n_fill_free;
  int vic_cov [WAYS];       // fills per victim way
  int hit_cov [WAYS];       // hits per way
  int st_cov  [4];          // cycles per FSM state
  int lat_seen_min = 1000, lat_seen_max = 0;

  // peeks inside the DUT (names exist in both cache_assoc*.sv versions)
  always @(posedge clk) if (rst_n) begin
    st_cov[int'(dut.state_q)]++;
    if (int'(dut.state_q) == 3 && mem_rsp_valid) vic_cov[dut.victim_way]++;  // ALLOCATE fill
    if (int'(dut.state_q) == 1 && dut.hit)       hit_cov[dut.hit_way]++;     // COMPARE hit
  end

  //---------------------------------------------------------------------------
  // PROTOCOL CHECKERS
  //---------------------------------------------------------------------------
  // SVA
  a_no_x: assert property (@(posedge clk) disable iff (!rst_n)
            !$isunknown({cpu_req_ready, cpu_rsp_valid, mem_req_valid}))
          else begin errors++; $error("X on a control output"); end

  a_rsp_pulse: assert property (@(posedge clk) disable iff (!rst_n)
            cpu_rsp_valid |=> !cpu_rsp_valid)
          else begin errors++; $error("cpu_rsp_valid high for more than 1 cycle"); end

  a_ready_vs_mem: assert property (@(posedge clk) disable iff (!rst_n)
            !(cpu_req_ready && mem_req_valid))
          else begin errors++; $error("memory request while cpu_req_ready"); end

  a_mem_hold: assert property (@(posedge clk) disable iff (!rst_n)
            (mem_req_valid && !mem_rsp_valid) |=>
            (mem_req_valid && $stable(mem_req_we) && $stable(mem_req_addr)))
          else begin errors++; $error("memory request dropped/changed before mem_rsp_valid"); end

  a_wb_data_hold: assert property (@(posedge clk) disable iff (!rst_n)
            (mem_req_valid && mem_req_we && !mem_rsp_valid) |=> $stable(mem_req_wdata))
          else begin errors++; $error("writeback data changed before mem_rsp_valid"); end

  a_line_aligned: assert property (@(posedge clk) disable iff (!rst_n)
            mem_req_valid |-> (mem_req_addr[OFF_W-1:0] == '0))
          else begin errors++; $error("memory address not line aligned"); end

  a_wb_no_x: assert property (@(posedge clk) disable iff (!rst_n)
            (mem_req_valid && mem_req_we) |-> !$isunknown(mem_req_wdata))
          else begin errors++; $error("X in writeback data"); end

  a_rdata_no_x: assert property (@(posedge clk) disable iff (!rst_n)
            cpu_rsp_valid |-> !$isunknown(cpu_rsp_rdata))
          else begin errors++; $error("X in cpu_rsp_rdata"); end

  // procedural: request/response pairing
  bit outstanding;
  always @(posedge clk) begin
    if (!rst_n) outstanding = 0;
    else begin
      check(!(cpu_rsp_valid && !outstanding), "cpu_rsp_valid without a request");
      check(!(cpu_req_ready && outstanding),  "cpu_req_ready while a request is still outstanding");
      if (cpu_rsp_valid)                  outstanding = 0;
      if (cpu_req_valid && cpu_req_ready) outstanding = 1;
    end
  end

  //---------------------------------------------------------------------------
  // CPU bus noise: while cpu_req_valid is LOW, scramble the other CPU inputs.
  // The DUT must only look at them in the cycle it accepts a request.
  //---------------------------------------------------------------------------
  bit noise_en = 0;
  always @(negedge clk)
    if (noise_en && !cpu_req_valid) begin
      cpu_req_we    = $urandom;
      cpu_req_addr  = $urandom;
      cpu_req_wdata = $urandom;
    end

  //---------------------------------------------------------------------------
  // THE ACCESS TASK: predict -> drive -> wait -> check everything
  //   Called at a negedge. Drives valid immediately, even if the cache is
  //   still busy (valid held until ready = real valid/ready protocol).
  //---------------------------------------------------------------------------
  task automatic access(input bit we, input addr_t a, input data_t wd, input string name);
    bit    e_hit, e_evict, e_wb;
    addr_t e_wb_la;
    line_t e_wb_data;
    data_t e_rd, got;
    int    lat, n_exp, k;

    // 1. predict
    mlog.delete();
    mdl_access(a, we, e_hit, e_evict, e_wb, e_wb_la);
    if (e_wb) e_wb_data = truth_line(e_wb_la);
    e_rd = truth_read(a);

    // 2. drive (hold valid until accepted)
    cpu_req_valid = 1'b1;
    cpu_req_we    = we;
    cpu_req_addr  = a;
    cpu_req_wdata = wd;
    while (!cpu_req_ready) @(negedge clk);
    @(negedge clk);                      // accepted at the posedge in between
    cpu_req_valid = 1'b0;

    // 3. wait for the response
    lat = 0;
    while (!cpu_rsp_valid) begin
      @(negedge clk);
      lat++;
      if (lat > 1000) begin
        $display("[%0t] FATAL: no response for %s addr=%h", $time, name, a);
        $finish;
      end
    end
    got = cpu_rsp_rdata;
    if (we) ref_mem[word_addr(a)] = wd;   // update truth

    // 4. check hit/miss + timing
    if (e_hit) check(lat == 0, $sformatf("%s addr=%h: expected HIT (1-cycle answer), took %0d extra cycles", name, a, lat));
    else       check(lat >  0, $sformatf("%s addr=%h: expected MISS but answered like a hit", name, a));

    // 5. check memory traffic: [writeback?] then fill read
    n_exp = e_hit ? 0 : (e_wb ? 2 : 1);
    check(mlog.size() == n_exp,
          $sformatf("%s addr=%h: expected %0d memory requests, saw %0d", name, a, n_exp, mlog.size()));
    if (mlog.size() == n_exp && !e_hit) begin
      k = 0;
      if (e_wb) begin
        check(mlog[0].we === 1'b1, $sformatf("%s: first request should be a WRITEBACK", name));
        check(mlog[0].addr === e_wb_la,
              $sformatf("%s: writeback addr %h, expected victim %h", name, mlog[0].addr, e_wb_la));
        check(mlog[0].data === e_wb_data,
              $sformatf("%s: writeback data wrong for line %h", name, e_wb_la));
        k = 1;
      end
      check(mlog[k].we === 1'b0, $sformatf("%s: expected a FILL read", name));
      check(mlog[k].addr === line_addr(a),
            $sformatf("%s: fill addr %h, expected %h", name, mlog[k].addr, line_addr(a)));
    end

    // 6. check read data
    if (!we)
      check(got === e_rd, $sformatf("%s READ %h: got %h expected %h", name, a, got, e_rd));

    // 7. coverage
    if (e_hit) begin if (we) n_wr_hit++; else n_rd_hit++; end
    else begin
      if (we) n_wr_miss++; else n_rd_miss++;
      if (e_wb)                n_wb++;
      else if (e_evict)        n_clean_evict++;
      else                     n_fill_free++;
    end
    if (lat < lat_seen_min) lat_seen_min = lat;
    if (lat > lat_seen_max) lat_seen_max = lat;

    if (verbose)
      $display("[%0t] %s | %s %h %s%s lat=%0d %s", $time, name, we ? "WR" : "RD", a,
               e_hit ? "HIT " : "MISS", e_wb ? "+WB" : "   ", lat,
               we ? $sformatf("wdata=%h", wd) : $sformatf("rdata=%h", got));
  endtask

  task automatic rd(input addr_t a, input string name = "");
    access(1'b0, a, '0, name);
  endtask

  task automatic wr(input addr_t a, input data_t d, input string name = "");
    access(1'b1, a, d, name);
  endtask

  task automatic idle(input int n);
    repeat (n) @(negedge clk);
  endtask

  function automatic void section(string s);
    $display("\n==== %s ====", s);
  endfunction

  //===========================================================================
  // TESTS
  //===========================================================================
  // T0: reset behaviour
  task automatic t0_reset();
    section("T0 reset: outputs idle, inputs ignored");
    rst_n = 0;
    cpu_req_valid = 1; cpu_req_we = 1; cpu_req_addr = 32'hDEAD_BEE0; cpu_req_wdata = 32'hBAD0_BAD0;
    repeat (3) begin
      @(negedge clk);
      check(!mem_req_valid, "mem_req_valid during reset");
      check(!cpu_rsp_valid, "cpu_rsp_valid during reset");
    end
    cpu_req_valid = 0;
    @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    check(cpu_req_ready === 1'b1, "cpu_req_ready not high after reset");
    check(!mem_req_valid,         "mem_req_valid high after reset");
    check(!cpu_rsp_valid,         "cpu_rsp_valid high after reset");
  endtask

  task automatic t1_cold_miss();
    section("T1 cold miss (set 0, word 0)");
    rd(A(0,0,0), "T1 cold miss");
  endtask

  task automatic t2_hits_words_bytes();
    section("T2 hits on other words, last word, unaligned bytes");
    rd(A(0,0,1), "T2 word1");
    rd(A(0,0,LINE_WORDS-1), "T2 last word");
    for (int b = 1; b < DATA_W/8; b++)
      rd(A(0,0,2) + addr_t'(b), $sformatf("T2 byte offset %0d", b));
  endtask

  task automatic t3_fill_all_ways();
    section("T3 fill every way of set 1, then hit every way");
    for (int t = 0; t < WAYS; t++) rd(A(t,1,0), "T3 fill");
    for (int t = 0; t < WAYS; t++) rd(A(t,1,1), "T3 hit");
  endtask

  task automatic t4_lru_order();
    section("T4 exact LRU order");
    for (int t = 0; t < WAYS; t++) rd(A(t,2,0), "T4 fill");     // LRU: t0 (oldest)
    rd(A(0,2,1),    "T4 touch t0");                            // LRU: t1
    rd(A(WAYS,2,0), "T4 new tag evicts t1");
    rd(A(1,2,0),    "T4 t1 must MISS");                         // evicts t2
    rd(A(0,2,0),    "T4 t0 must HIT");
    rd(A(2,2,0),    "T4 t2 must MISS");
  endtask

  task automatic t5_store_hits();
    section("T5 store hits: no traffic, overwrite, every word");
    rd(A(0,6,0), "T5 load line");
    wr(A(0,6,1), 32'h1111_1111, "T5 store hit");
    wr(A(0,6,1), 32'h2222_2222, "T5 same word again");
    rd(A(0,6,1), "T5 last write wins");
    for (int w = 0; w < LINE_WORDS; w++) wr(A(0,6,w), 32'hC0DE_0000 + w, "T5 every word");
    for (int w = 0; w < LINE_WORDS; w++) rd(A(0,6,w), "T5 read back");
  endtask

  task automatic t6_store_miss();
    section("T6 store miss = write-allocate");
    wr(A(3,7,2), 32'hFEED_FACE, "T6 store miss");
    for (int w = 0; w < LINE_WORDS; w++) rd(A(3,7,w), "T6 rest of line from mem");
  endtask

  task automatic t7_all_dirty();
    section("T7 all-dirty set: every eviction writes back");
    for (int t = 0; t < WAYS; t++) wr(A(t,8,t % LINE_WORDS), 32'hD000_0000 + t, "T7 dirty fill");
    for (int t = WAYS; t < 2*WAYS; t++) rd(A(t,8,0), "T7 evict dirty");
    check(n_wb >= WAYS, "T7 expected at least WAYS writebacks");
    for (int t = 0; t < WAYS; t++) rd(A(t,8,t % LINE_WORDS), "T7 data survived in mem");
  endtask

  task automatic t8_clean_evict();
    section("T8 clean eviction: no writeback");
    for (int t = 0; t < WAYS; t++) rd(A(t,9,0), "T8 clean fill");
    rd(A(WAYS,9,0), "T8 evict clean (no WB)");
  endtask

  task automatic t9_mixed();
    section("T9 mixed dirty/clean in one set");
    for (int t = 0; t < WAYS; t++)
      if (t % 2) wr(A(t,10,0), 32'hAB00_0000 + t, "T9 dirty");
      else       rd(A(t,10,0), "T9 clean");
    for (int t = WAYS; t < 2*WAYS; t++) rd(A(t,10,0), "T9 evict (WB only odd)");
  endtask

  task automatic t10_thrash();
    int miss_before;
    section("T10 LRU thrash: WAYS+1 tags round-robin");
    miss_before = n_rd_miss;
    for (int r = 0; r < 3; r++)
      for (int t = 0; t <= WAYS; t++) rd(A(t,11,0), "T10 thrash");
    check(n_rd_miss - miss_before == 3*(WAYS+1), "T10 every thrash access should miss");
  endtask

  task automatic t11_extremes();
    longint unsigned tmax;
    section("T11 address extremes");
    tmax = (64'd1 << TAG_W) - 1;
    rd(A(tmax, NUM_SETS-1, LINE_WORDS-1), "T11 tag=all1 set=max word=last");
    wr(A(tmax, NUM_SETS-1, LINE_WORDS-1), 32'hFFFF_0001, "T11 store top address");
    rd(A(0,    NUM_SETS-1, LINE_WORDS-1), "T11 tag 0 same set");
    rd(A(tmax, NUM_SETS-1, LINE_WORDS-1), "T11 tag all1 still HIT");
    rd(32'hFFFF_FFFF,                     "T11 addr FFFFFFFF");
  endtask

  task automatic t12_latency();
    section("T12 memory latency 1 and 20");
    lat_min = 1;  lat_max = 1;
    for (int t = 0; t < WAYS+1; t++) wr(A(t,12,0), 32'h1A70_0000 + t, "T12 lat=1");
    rd(A(0,12,0), "T12 lat=1 dirty conflict");
    lat_min = 20; lat_max = 20;
    for (int t = 0; t < WAYS+1; t++) wr(A(t,13,1), 32'h2070_0000 + t, "T12 lat=20");
    rd(A(0,13,1), "T12 lat=20 dirty conflict");     // t0 was evicted by t4 -> MISS+WB
    lat_min = 3;  lat_max = 3;
  endtask

  task automatic t13_reset_mid_miss();
    section("T13 reset in the middle of a miss");
    wr(A(5,14,0), 32'h5555_AAAA, "T13 dirty line (will be LOST)");
    // start a miss by hand, then hit reset while waiting for memory
    cpu_req_valid = 1; cpu_req_we = 0; cpu_req_addr = A(6,14,0); cpu_req_wdata = '0;
    while (!cpu_req_ready) @(negedge clk);
    @(negedge clk);
    cpu_req_valid = 0;
    while (!mem_req_valid) @(negedge clk);
    @(negedge clk);
    rst_n = 0;
    @(negedge clk);
    check(!mem_req_valid && !cpu_rsp_valid, "T13 outputs not idle in reset");
    @(negedge clk);
    rst_n = 1;
    // after reset: cache empty, dirty data lost -> truth = backing memory
    mdl_reset();
    ref_mem.delete();
    mlog.delete();
    @(negedge clk);
    rd(A(5,14,0), "T13 old dirty data gone (MISS)");
    rd(A(0,0,0),  "T13 everything invalid (MISS)");
  endtask

  // T15: realistic locality. Each set is used by only WS_TAGS (< WAYS) tags,
  // so the whole working set fits in the cache. After the first touch of each
  // line (cold misses) every access should HIT.
  task automatic t15_working_set(input int n);
    int    WS_TAGS = (WAYS > 1) ? WAYS - 1 : 1;
    int    h0, m0, hits, misses, max_cold;
    real   rate;
    addr_t a;
    section($sformatf("T15 working set: %0d tags/set x %0d sets (%0d lines, fits in cache), %0d ops",
                      WS_TAGS, NUM_SETS, WS_TAGS*NUM_SETS, n));
    verbose = 0;
    h0 = n_rd_hit  + n_wr_hit;
    m0 = n_rd_miss + n_wr_miss;
    for (int i = 0; i < n; i++) begin
      a = A($urandom_range(0, WS_TAGS-1), $urandom_range(0, NUM_SETS-1),
            $urandom_range(0, LINE_WORDS-1));
      if ($urandom_range(0, 9) < 3) wr(a, $urandom, "WS");   // 30% stores
      else                          rd(a, "WS");
    end
    verbose  = 1;
    hits     = n_rd_hit  + n_wr_hit  - h0;
    misses   = n_rd_miss + n_wr_miss - m0;
    max_cold = WS_TAGS * NUM_SETS;                // each line can miss once at most
    rate     = 100.0 * hits / n;
    $display("T15 hits=%0d misses=%0d  hit rate=%0.1f%%  (cold misses allowed <= %0d)",
             hits, misses, rate, max_cold);
    check(misses <= max_cold, "T15 more misses than cold misses: working set should stay resident");
    check(rate >= 90.0,       "T15 hit rate below 90% for a working set that fits");
  endtask

  task automatic t14_random(input int n);
    addr_t a;
    int    r;
    section($sformatf("T14 random traffic (%0d ops, latency 1..8, bus noise)", n));
    verbose  = 0;
    noise_en = 1;
    lat_min  = 1; lat_max = 8;
    for (int i = 0; i < n; i++) begin
      r = $urandom_range(0, 99);
      if (r < 85)        // hot: few tags per set -> lots of hits AND evictions
        a = {TAG_W'($urandom_range(0, WAYS+2)), IDX_W'($urandom_range(0, NUM_SETS-1)),
             WORD_W'($urandom_range(0, LINE_WORDS-1)), BYTE_W'($urandom_range(0, DATA_W/8-1))};
      else
        a = $urandom;    // anywhere in the 4 GB space
      if ($urandom_range(0, 2) == 0) wr(a, $urandom, "RND");
      else                           rd(a, "RND");
      if ($urandom_range(0, 9) == 0) idle($urandom_range(1, 3));   // sometimes idle gaps
    end
    noise_en = 0;
    verbose  = 1;
    lat_min  = 3; lat_max = 3;
  endtask

  //===========================================================================
  // TEST LIST
  //===========================================================================
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb);

    @(negedge clk);
    t0_reset();
    t1_cold_miss();
    t2_hits_words_bytes();
    t3_fill_all_ways();
    t4_lru_order();
    t5_store_hits();
    t6_store_miss();
    t7_all_dirty();
    t8_clean_evict();
    t9_mixed();
    t10_thrash();
    t11_extremes();
    t12_latency();
    t13_reset_mid_miss();
    t15_working_set(2000);     // realistic locality -> high hit rate
    t14_random(5000);          // stress -> lots of misses on purpose
    idle(5);

    //-------------------------------------------------------------------------
    // Coverage report + goals
    //-------------------------------------------------------------------------
    $display("\n==== COVERAGE ====");
    $display("read  hits=%0d  misses=%0d", n_rd_hit, n_rd_miss);
    $display("store hits=%0d  misses=%0d", n_wr_hit, n_wr_miss);
    $display("fills into free way=%0d  clean evictions=%0d  dirty writebacks=%0d",
             n_fill_free, n_clean_evict, n_wb);
    $display("response latency seen: %0d .. %0d cycles after accept", lat_seen_min, lat_seen_max);
    for (int w = 0; w < WAYS; w++)
      $display("way %0d : hits=%0d  fills=%0d", w, hit_cov[w], vic_cov[w]);
    $display("cycles  IDLE=%0d COMPARE=%0d WRITE_BACK=%0d ALLOCATE=%0d",
             st_cov[0], st_cov[1], st_cov[2], st_cov[3]);

    check(n_rd_hit > 0 && n_rd_miss > 0 && n_wr_hit > 0 && n_wr_miss > 0, "COVER: all 4 hit/miss x rd/wr kinds");
    check(n_fill_free > 0 && n_clean_evict > 0 && n_wb > 0,                "COVER: free fill, clean evict, writeback");
    for (int w = 0; w < WAYS; w++) begin
      check(hit_cov[w] > 0, $sformatf("COVER: way %0d never hit", w));
      check(vic_cov[w] > 0, $sformatf("COVER: way %0d never filled", w));
    end
    for (int s = 0; s < 4; s++) check(st_cov[s] > 0, $sformatf("COVER: state %0d never visited", s));

    $display("--------------------------------------------------");
    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED  (%0d errors)", errors);
    $finish;
  end

  // watchdog
  initial begin
    #200_000_000;
    $display("FATAL: global timeout");
    $finish;
  end

endmodule