//==============================================================================
//  File    : cache_smoke_test.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Smallest possible run: 30 random accesses, no backpressure, no latency.
//            Run it first, to check the environment works at all.
//  CONFIG  : cache_cfg_quiet   (factory type override of cache_cfg, see build_phase)
//  START   : always from reset (own simulation): cache empty, memory = initial
//            pattern, scoreboard empty.
//  RUN     : +UVM_TESTNAME=cache_smoke_test   (+RUN_ID=<tag> to name its result files)
//==============================================================================
class cache_smoke_test extends cache_base_test;

  `uvm_component_utils(cache_smoke_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Factory override: register it BEFORE super.build_phase(), because the base
  // test creates cfg there with cache_cfg::type_id::create().
  function void build_phase(uvm_phase phase);
    cache_cfg::type_id::set_type_override(cache_cfg_quiet::get_type());
    super.build_phase(phase);
  endfunction

  task run_scenario();
    cache_smoke_vseq v = cache_smoke_vseq::type_id::create("v");
    v.start(env.vseqr);
  endtask

endclass
