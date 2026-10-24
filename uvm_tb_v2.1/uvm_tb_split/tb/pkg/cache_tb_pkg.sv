`timescale 1ns/1ps
//==============================================================================
//  File    : cache_tb_pkg.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : One package that pulls in every UVM class of the testbench, in
//            dependency order (a class must be compiled before it is used).
//            tb_top imports this package; nothing else needs to.
//
//  ORDER (and why)
//    items + models first (used by everything), then cfg (holds a mem_model),
//    then agents (sequencers before drivers/monitors that use them), then the
//    env pieces, sequences, and finally the tests.
//
//  WATCH OUT:
//    - Include paths are relative to tb/ : compile with +incdir+<path>/tb
//      (see filelist.f). The single-file version has all of these pasted in.
//    - Adding a new class = add its `include here, in the right place.
//==============================================================================
package cache_tb_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import cache_tb_defs_pkg::*;

  // ---- transactions + models ----------------------------------------------
  `include "agents/cpu_agent/cpu_item.sv"
  `include "agents/mem_agent/mem_item.sv"
  `include "agents/flush_agent/flush_item.sv"
  `include "agents/mem_agent/mem_model.sv"
  `include "env/cache_ref_model.sv"
  `include "common/cache_cfg.sv"

  // ---- CPU agent ---------------------------------------------------------
  `include "agents/cpu_agent/cpu_seqr.sv"
  `include "agents/cpu_agent/cpu_drv.sv"
  `include "agents/cpu_agent/cpu_mon.sv"
  `include "agents/cpu_agent/cpu_agent.sv"

  // ---- flush agent -------------------------------------------------------
  `include "agents/flush_agent/flush_seqr.sv"
  `include "agents/flush_agent/flush_drv.sv"
  `include "agents/flush_agent/flush_mon.sv"
  `include "agents/flush_agent/flush_agent.sv"

  // ---- memory agent ------------------------------------------------------
  `include "agents/mem_agent/mem_seqr.sv"
  `include "agents/mem_agent/mem_drv.sv"
  `include "agents/mem_agent/mem_mon.sv"
  `include "agents/mem_agent/mem_resp_seq.sv"
  `include "agents/mem_agent/mem_agent.sv"

  // ---- environment -------------------------------------------------------
  `include "env/cache_scoreboard.sv"
  `include "env/cache_cov.sv"
  `include "env/cache_vseqr.sv"
  `include "env/cache_env.sv"

  // ---- sequences ---------------------------------------------------------
  `include "seq/cpu_seq_lib.sv"
  `include "seq/flush_seq_lib.sv"
  `include "seq/vseq_lib.sv"

  // ---- tests -------------------------------------------------------------
  `include "tests/cache_base_test.sv"
  `include "tests/cache_smoke_test.sv"
  `include "tests/cache_directed_test.sv"
  `include "tests/cache_rand_test.sv"
  `include "tests/cache_bp_test.sv"
  `include "tests/cache_flush_test.sv"
  `include "tests/cache_flush_race_test.sv"
  `include "tests/cache_err_test.sv"

endpackage
