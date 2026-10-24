//==============================================================================
//  File    : cache_cfg.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Every RUNTIME setting of the testbench, in one object, plus the
//            handles everyone needs (virtual interfaces, memory model).
//            The base test creates ONE cache_cfg and shares it through
//            uvm_config_db; every component and sequence reads the SAME
//            object, so changing a knob takes effect immediately everywhere.
//
//  KNOBS (all read live, every time they are used)
//    CPU side   : cpu_rsp_ready_pct  % of cycles cpu_rsp_ready = 1
//                 cpu_gap_max        idle cycles (0..max) before each request
//                 max_outstanding    requests in flight (1 now; N for v2)
//                 rsp_timeout        cycles before "no response" is an error
//    Memory side: mem_req_ready_pct  % of cycles mem_req_ready = 1
//                 mem_lat_min/max    response latency range in cycles
//                 mem_rd_err_pct     % of refills answered with an error
//                 mem_wr_err_pct     % of writebacks answered with an error
//                 force_rd_err/force_wr_err : next N reads/writes WILL error
//                                    (used by directed tests)
//    Traffic    : pool_tag_base, pool_n_tags, pool_set_base, pool_n_sets,
//                 store_pct          (where random addresses come from)
//
//  CONFIG VARIANTS = FACTORY OVERRIDES  (v2.1)
//    cache_cfg itself holds the DEFAULT timing (70% ready, latency 0..6).
//    Subclasses at the bottom of this file only change default values:
//        cache_cfg_quiet : no backpressure, no latency   (smoke test)
//        cache_cfg_bp    : heavy backpressure, slow memory
//        cache_cfg_err   : default timing + 5% memory errors
//    A test picks one BEFORE super.build_phase():
//        cache_cfg::type_id::set_type_override(cache_cfg_bp::get_type());
//    and the base test's  cache_cfg::type_id::create("cfg")  then returns a
//    cache_cfg_bp. Nobody else needs to know: they all hold a cache_cfg handle.
//
//    OTHER WAY (v2): one class + an apply_preset("bp") function. That allowed
//    switching settings in the middle of a run (the old master test), which a
//    factory override cannot do: it only acts when the object is created.
//
//  WATCH OUT:
//    - DUT parameters (sets, ways, line size) are NOT here: they are fixed at
//      compile time (cache_tb_defs_pkg). Only testbench behaviour changes live.
//    - Keep pct knobs > 0 for ready signals, or the DUT waits forever.
//==============================================================================
class cache_cfg extends uvm_object;

  `uvm_object_utils(cache_cfg)

  // ---------------- handles ----------------------------------------------------
  virtual cache_cpu_if  cpu_vif;
  virtual cache_mem_if  mem_vif;
  mem_model             mem;

  // ---------------- CPU side -----------------------------------------------
  int unsigned cpu_rsp_ready_pct = 70;
  int unsigned cpu_gap_max       = 2;
  int unsigned max_outstanding   = 1;      // v1 DUT is blocking
  int unsigned rsp_timeout       = 5000;

  // ---------------- memory side ---------------------------------------------
  int unsigned mem_req_ready_pct = 70;
  int unsigned mem_lat_min       = 0;
  int unsigned mem_lat_max       = 6;
  int unsigned mem_rd_err_pct    = 0;
  int unsigned mem_wr_err_pct    = 0;
  int unsigned force_rd_err      = 0;
  int unsigned force_wr_err      = 0;

  // ---------------- random address pool -------------------------------------
  // Many tags on few sets -> lots of conflict misses and dirty evictions.
  int unsigned pool_tag_base = 40;
  int unsigned pool_n_tags   = 2 * DUT_N_WAYS + 2;
  int unsigned pool_set_base = 0;
  int unsigned pool_n_sets   = 4;
  int unsigned store_pct     = 50;


  function new(string name = "cache_cfg");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf({"cfg=%s  cpu_rsp_ready=%0d%% gap<=%0d max_out=%0d | ",
                      "mem_ready=%0d%% lat=%0d..%0d rd_err=%0d%% wr_err=%0d%% | ",
                      "pool tags %0d+%0d sets %0d+%0d store=%0d%%"},
                     get_type_name(), cpu_rsp_ready_pct, cpu_gap_max, max_outstanding,
                     mem_req_ready_pct, mem_lat_min, mem_lat_max, mem_rd_err_pct,
                     mem_wr_err_pct, pool_tag_base, pool_n_tags, pool_set_base,
                     pool_n_sets, store_pct);
  endfunction

endclass


//------------------------------------------------------------------------------
//  Config variants. Each one ONLY changes default values in new().
//  Selected per test with a factory TYPE override (see the tests).
//------------------------------------------------------------------------------
class cache_cfg_quiet extends cache_cfg;            // no backpressure, no latency
  `uvm_object_utils(cache_cfg_quiet)
  function new(string name = "cache_cfg_quiet");
    super.new(name);
    cpu_rsp_ready_pct = 100;  cpu_gap_max = 0;
    mem_req_ready_pct = 100;  mem_lat_min = 0;  mem_lat_max = 0;
  endfunction
endclass

class cache_cfg_bp extends cache_cfg;               // heavy backpressure, slow memory
  `uvm_object_utils(cache_cfg_bp)
  function new(string name = "cache_cfg_bp");
    super.new(name);
    cpu_rsp_ready_pct = 25;   cpu_gap_max = 5;
    mem_req_ready_pct = 25;   mem_lat_min = 5;  mem_lat_max = 20;
  endfunction
endclass

class cache_cfg_err extends cache_cfg;              // default timing + memory errors
  `uvm_object_utils(cache_cfg_err)
  function new(string name = "cache_cfg_err");
    super.new(name);
    mem_rd_err_pct = 5;
    mem_wr_err_pct = 5;
  endfunction
endclass
