//==============================================================================
//  File    : cache_rand_test.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : 2000 random loads/stores on a conflict-heavy address pool, with a flush
//            (and full memory compare) every 500 accesses.
//  CONFIG  : cache_cfg      (the default: no override needed)
//  START   : always from reset (own simulation): cache empty, memory = initial
//            pattern, scoreboard empty.
//  RUN     : +UVM_TESTNAME=cache_rand_test   (+RUN_ID=<tag> to name its result files)
//==============================================================================
class cache_rand_test extends cache_base_test;

  `uvm_component_utils(cache_rand_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_scenario();
    cache_rand_vseq v = cache_rand_vseq::type_id::create("v");
    v.n_ops = 2000; v.flush_every = 500;
    v.start(env.vseqr);
  endtask

endclass
