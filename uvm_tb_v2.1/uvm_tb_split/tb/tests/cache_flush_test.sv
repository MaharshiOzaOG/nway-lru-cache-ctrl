//==============================================================================
//  File    : cache_flush_test.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Flush, flush again (must have nothing to do), flush + invalidate,
//            flush + invalidate again (cache empty), then refills.
//  CONFIG  : cache_cfg      (the default: no override needed)
//  START   : always from reset (own simulation): cache empty, memory = initial
//            pattern, scoreboard empty.
//  RUN     : +UVM_TESTNAME=cache_flush_test   (+RUN_ID=<tag> to name its result files)
//==============================================================================
class cache_flush_test extends cache_base_test;

  `uvm_component_utils(cache_flush_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_scenario();
    cache_flush_vseq v = cache_flush_vseq::type_id::create("v");
    v.start(env.vseqr);
  endtask

endclass
