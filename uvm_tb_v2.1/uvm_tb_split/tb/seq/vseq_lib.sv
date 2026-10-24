//==============================================================================
//  File    : vseq_lib.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Virtual sequences = the scenarios. They run on cache_vseqr and
//            start real sequences on the CPU / flush sequencers.
//
//    cache_base_vseq        helpers: ld(), st(), do_flush(), rand_ops(),
//                           wait_cycles(), mark() + expect_traffic()
//    cache_smoke_vseq       a few random accesses, quiet timing
//    cache_directed_vseq    T1..T9 from the old plain testbench, with EXACT
//                           refill/writeback counts checked
//    cache_rand_vseq        random traffic, a flush every `flush_every` ops
//    cache_flush_vseq       flush, flush again (nothing left), flush+invalidate
//    cache_flush_race_vseq  random traffic AND flushes at random moments, in
//                           parallel (a flush arriving while a request waits)
//    (v2.1: the old cache_master_vseq is gone. Every scenario is its own test,
//     started from reset, with its config chosen by a factory override.)
//
//  HOW THE SCOREBOARD IS USED HERE
//    Data is always checked by the scoreboard. Directed steps additionally
//    check how many refills/writebacks a step caused, by reading the
//    scoreboard counters before (mark) and after (expect_traffic).
//    Every flush makes the scoreboard compare all of memory automatically.
//
//  WATCH OUT:
//    - Exact traffic counts are only valid when no other traffic runs at the
//      same time (true in the directed scenario) and the cache starts cold for
//      the sets used (the directed scenario begins with flush + invalidate).
//==============================================================================

//------------------------------------------------------------------------------
class cache_base_vseq extends uvm_sequence;

  `uvm_object_utils(cache_base_vseq)
  `uvm_declare_p_sequencer(cache_vseqr)

  int unsigned rd0, wr0;     // scoreboard counters at mark()

  function new(string name = "cache_base_vseq");
    super.new(name);
  endfunction

  // one load
  task ld(addr_t a, output cpu_item r);
    cpu_op_seq s = cpu_op_seq::type_id::create("ld");
    s.op_we   = 1'b0;
    s.op_addr = a;
    s.start(p_sequencer.cpu_sqr, this);
    r = s.rsp_item;
  endtask

  // one store
  task st(addr_t a, data_t d, strb_t strb, output cpu_item r);
    cpu_op_seq s = cpu_op_seq::type_id::create("st");
    s.op_we    = 1'b1;
    s.op_addr  = a;
    s.op_wdata = d;
    s.op_wstrb = strb;
    s.start(p_sequencer.cpu_sqr, this);
    r = s.rsp_item;
  endtask

  // one flush; returns flush_err
  task do_flush(bit inv, output bit err);
    flush_seq s = flush_seq::type_id::create("flush");
    s.inv = inv;
    s.start(p_sequencer.flush_sqr, this);
    err = s.err;
  endtask

  // n random accesses from the cfg address pool
  task rand_ops(int unsigned n);
    cpu_rand_seq s = cpu_rand_seq::type_id::create("rand");
    s.n_ops = n;
    s.start(p_sequencer.cpu_sqr, this);
  endtask

  task wait_cycles(int unsigned n);
    repeat (n) @(p_sequencer.cfg.cpu_vif.mon_cb);               // DELAY: n clock cycles
  endtask

  // remember the scoreboard's memory counters
  function void mark();
    rd0 = p_sequencer.sb.n_mem_rd;
    wr0 = p_sequencer.sb.n_mem_wr;
  endfunction

  // memory traffic since mark() must be exactly exp_rd refills / exp_wr writebacks
  function void expect_traffic(string step, int unsigned exp_rd, int unsigned exp_wr);
    int unsigned rd, wr;
    rd = p_sequencer.sb.n_mem_rd - rd0;
    wr = p_sequencer.sb.n_mem_wr - wr0;
    if (rd != exp_rd || wr != exp_wr)
      `uvm_error("DIRECTED", $sformatf("%s: %0d refill(s) / %0d writeback(s), expected %0d / %0d",
                                       step, rd, wr, exp_rd, exp_wr))
    else
      `uvm_info("DIRECTED", $sformatf("ok  %s  (refills=%0d writebacks=%0d)", step, rd, wr), UVM_LOW)
  endfunction

  function void expect_bit(string step, bit got, bit exp);
    if (got !== exp)
      `uvm_error("DIRECTED", $sformatf("%s: got %0d, expected %0d", step, got, exp))
  endfunction

endclass


//------------------------------------------------------------------------------
class cache_smoke_vseq extends cache_base_vseq;
  `uvm_object_utils(cache_smoke_vseq)
  function new(string name = "cache_smoke_vseq"); super.new(name); endfunction

  task body();
    rand_ops(30);
  endtask
endclass


//------------------------------------------------------------------------------
//  Directed: T1..T9 ported from the plain testbench (T10/T11 = rand + final flush)
//------------------------------------------------------------------------------
class cache_directed_vseq extends cache_base_vseq;
  `uvm_object_utils(cache_directed_vseq)
  function new(string name = "cache_directed_vseq"); super.new(name); endfunction

  task body();
    cpu_item     r;
    bit          ferr;
    int unsigned saved_pct;

    // start cold: write everything back and invalidate
    do_flush(1'b1, ferr);

    // T1 cold miss, then hits in the same line
    mark(); ld(mk_addr(1, 1, 0), r);                     expect_traffic("T1 cold load miss", 1, 0);
    mark(); ld(mk_addr(1, 1, 0), r);
            for (int w = 1; w < WPL; w++) ld(mk_addr(1, 1, w), r);
                                                         expect_traffic("T1 same line hits", 0, 0);

    // T2 store hits (word, one byte, upper half) -> no memory traffic
    mark(); st(mk_addr(1, 1, 0), 32'hCAFE_0001, 4'b1111, r);
            st(mk_addr(1, 1, 1), 32'h0000_00A5, 4'b0001, r);
            st(mk_addr(1, 1, 2), 32'h5A5A_0000, 4'b1100, r);
            for (int w = 0; w < WPL; w++) ld(mk_addr(1, 1, w), r);
                                                         expect_traffic("T2 store hits", 0, 0);

    // T3 store miss: write-allocate (one refill) and merge
    mark(); st(mk_addr(2, 2, 1), 32'h1234_5678, 4'b1111, r);
                                                         expect_traffic("T3 store miss allocates", 1, 0);
    mark(); for (int w = 0; w < WPL; w++) ld(mk_addr(2, 2, w), r);
                                                         expect_traffic("T3 merged line hits", 0, 0);

    // T4 LRU order (4 ways, set 3)
    if (DUT_N_WAYS >= 3) begin
      mark(); for (int i = 0; i < DUT_N_WAYS; i++) ld(mk_addr(10 + i, 3), r);
                                                         expect_traffic("T4 fill set", DUT_N_WAYS, 0);
      mark(); ld(mk_addr(10, 3), r);                     expect_traffic("T4 touch A0 (hit)", 0, 0);
      mark(); ld(mk_addr(10 + DUT_N_WAYS, 3), r);        expect_traffic("T4 new line evicts LRU (A1)", 1, 0);
      mark(); ld(mk_addr(11, 3), r);                     expect_traffic("T4 A1 was evicted", 1, 0);
      mark(); ld(mk_addr(10 + DUT_N_WAYS, 3), r);        expect_traffic("T4 newest line kept", 0, 0);
      mark(); ld(mk_addr(12, 3), r);                     expect_traffic("T4 A2 was evicted", 1, 0);
    end

    // T5 dirty eviction: writeback first, then refill
    mark(); for (int i = 0; i < DUT_N_WAYS; i++) st(mk_addr(20 + i, 4, 1), 32'h0BAD_F000 + i, 4'b1111, r);
                                                         expect_traffic("T5 fill set with dirty lines", DUT_N_WAYS, 0);
    mark(); ld(mk_addr(20 + DUT_N_WAYS, 4), r);          expect_traffic("T5 dirty miss: 1 writeback + 1 refill", 1, 1);
    mark(); ld(mk_addr(20, 4, 1), r);                    expect_traffic("T5 evicted line comes back", 1, 1);

    // T6 hit latency = 2 cycles (no response backpressure for this one)
    saved_pct = p_sequencer.cfg.cpu_rsp_ready_pct;
    p_sequencer.cfg.cpu_rsp_ready_pct = 100;
    ld(mk_addr(1, 1, 0), r);
    if (r.lat_cycles != 2)
      `uvm_error("DIRECTED", $sformatf("T6 hit latency %0d cycles, expected 2", r.lat_cycles))
    else
      `uvm_info("DIRECTED", "ok  T6 hit latency = 2 cycles", UVM_LOW)
    p_sequencer.cfg.cpu_rsp_ready_pct = saved_pct;

    // T7 memory read errors
    p_sequencer.cfg.force_rd_err = 1;
    mark(); ld(mk_addr(30, 5), r);                       expect_traffic("T7 load miss with refill error", 1, 0);
            expect_bit("T7 load err flag", r.err, 1'b1);
    mark(); ld(mk_addr(30, 5), r);                       expect_traffic("T7 errored line was not installed", 1, 0);
            expect_bit("T7 retry err flag", r.err, 1'b0);
    p_sequencer.cfg.force_rd_err = 1;
    mark(); st(mk_addr(31, 6), 32'hDEAD_BEEF, 4'b1111, r);
                                                         expect_traffic("T7 store miss with refill error", 1, 0);
            expect_bit("T7 store err flag", r.err, 1'b1);
    mark(); ld(mk_addr(31, 6), r);                       expect_traffic("T7 errored store not applied (miss)", 1, 0);

    // T8 flush without invalidate
    mark(); do_flush(1'b0, ferr);
    if (p_sequencer.sb.n_mem_wr == wr0)
      `uvm_error("DIRECTED", "T8 there were dirty lines but the flush wrote nothing back")
    else
      `uvm_info("DIRECTED", $sformatf("ok  T8 flush wrote back %0d line(s)", p_sequencer.sb.n_mem_wr - wr0), UVM_LOW)
    expect_bit("T8 flush err", ferr, 1'b0);
    mark(); do_flush(1'b0, ferr);                        expect_traffic("T8 second flush has nothing to do", 0, 0);
    mark(); ld(mk_addr(2, 2, 0), r);                     expect_traffic("T8 lines stay valid after clean flush", 0, 0);

    // T9 flush + invalidate
    mark(); st(mk_addr(2, 2, 0), 32'h5555_AAAA, 4'b1111, r);
            do_flush(1'b1, ferr);                        expect_traffic("T9 flush+inv writes back the 1 dirty line", 0, 1);
    mark(); ld(mk_addr(2, 2, 0), r);                     expect_traffic("T9 line invalidated (miss)", 1, 0);
    mark(); ld(mk_addr(1, 1, 0), r);                     expect_traffic("T9 line invalidated (miss)", 1, 0);
  endtask
endclass


//------------------------------------------------------------------------------
class cache_rand_vseq extends cache_base_vseq;
  `uvm_object_utils(cache_rand_vseq)

  int unsigned n_ops       = 2000;
  int unsigned flush_every = 500;

  function new(string name = "cache_rand_vseq"); super.new(name); endfunction

  task body();
    bit          ferr;
    int unsigned done;
    if (flush_every == 0) flush_every = n_ops;           // guard: 0 would loop forever
    while (done < n_ops) begin
      rand_ops((n_ops - done < flush_every) ? (n_ops - done) : flush_every);
      done += flush_every;
      do_flush($urandom_range(0, 1), ferr);              // scoreboard checks memory here
    end
  endtask
endclass


//------------------------------------------------------------------------------
class cache_flush_vseq extends cache_base_vseq;
  `uvm_object_utils(cache_flush_vseq)
  function new(string name = "cache_flush_vseq"); super.new(name); endfunction

  task body();
    bit ferr;
    rand_ops(300);
    do_flush(1'b0, ferr);                                // write back everything
    mark(); do_flush(1'b0, ferr);                        expect_traffic("flush again: nothing dirty left", 0, 0);
    rand_ops(300);
    do_flush(1'b1, ferr);                                // write back + invalidate
    mark(); do_flush(1'b1, ferr);                        expect_traffic("flush+inv again: cache empty", 0, 0);
    rand_ops(100);                                       // refills after a full invalidate
  endtask
endclass


//------------------------------------------------------------------------------
//  Flushes at random moments WHILE CPU traffic runs (fork ... join)
//------------------------------------------------------------------------------
class cache_flush_race_vseq extends cache_base_vseq;
  `uvm_object_utils(cache_flush_race_vseq)

  int unsigned n_ops     = 800;
  int unsigned n_flushes = 8;

  function new(string name = "cache_flush_race_vseq"); super.new(name); endfunction

  task body();
    fork
      rand_ops(n_ops);
      begin
        bit ferr;
        repeat (n_flushes) begin
          wait_cycles($urandom_range(20, 400));          // DELAY: flush at a random moment
          do_flush($urandom_range(0, 1), ferr);
        end
      end
    join
  endtask
endclass
