//==============================================================================
//  File    : cache_bp_test.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Heavy backpressure on BOTH sides (cpu_rsp_ready and mem_req_ready low
//            most of the time) and slow memory. Checks nothing breaks when
//            everybody has to wait (stability SVA must stay quiet).
//  CONFIG  : cache_cfg_bp   (factory type override of cache_cfg, see build_phase)
//  START   : always from reset (own simulation): cache empty, memory = initial
//            pattern, scoreboard empty.
//  RUN     : +UVM_TESTNAME=cache_bp_test   (+RUN_ID=<tag> to name its result files)
//==============================================================================
class cache_bp_test extends cache_base_test;

  `uvm_component_utils(cache_bp_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Factory override: register it BEFORE super.build_phase(), because the base
  // test creates cfg there with cache_cfg::type_id::create().
  function void build_phase(uvm_phase phase);
    cache_cfg::type_id::set_type_override(cache_cfg_bp::get_type());
    super.build_phase(phase);
  endfunction

  task run_scenario();
    cache_rand_vseq v = cache_rand_vseq::type_id::create("v");
    v.n_ops = 500; v.flush_every = 250;
    v.start(env.vseqr);
  endtask

endclass
