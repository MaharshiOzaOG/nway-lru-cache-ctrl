//==============================================================================
//  File    : cache_directed_test.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : T1..T9 from the old plain testbench (cold miss, store hits, store miss,
//            LRU order, dirty eviction, hit latency, read errors, flush,
//            flush+invalidate) with exact refill/writeback counts.
//  CONFIG  : cache_cfg      (the default: no override needed)
//  START   : always from reset (own simulation): cache empty, memory = initial
//            pattern, scoreboard empty.
//  RUN     : +UVM_TESTNAME=cache_directed_test   (+RUN_ID=<tag> to name its result files)
//==============================================================================
class cache_directed_test extends cache_base_test;

  `uvm_component_utils(cache_directed_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_scenario();
    cache_directed_vseq v = cache_directed_vseq::type_id::create("v");
    v.start(env.vseqr);
  endtask

endclass
