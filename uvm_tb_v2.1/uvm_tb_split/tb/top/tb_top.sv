`timescale 1ns/1ps
//==============================================================================
//  File    : tb_top.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : The only MODULE of the testbench (everything else is classes).
//              - makes the clock and reset
//              - creates the two interfaces
//              - creates the DUT (cache_ctrl) and wires it to the interfaces
//              - puts the interfaces in uvm_config_db so classes can reach them
//              - starts UVM: run_test()
//
//  HOW THE CLASSES REACH THE PINS
//      tb_top:  uvm_config_db#(virtual cache_cpu_if)::set(null, "uvm_test_top",
//                                                         "cpu_vif", cpu_if)
//      base test: ::get(...) into cfg.cpu_vif -> shared with every component.
//
//  WHICH TEST RUNS
//    run_test("cache_smoke_test") is the default. +UVM_TESTNAME=<name> on the
//    command line overrides it (UVM gives the plusarg priority).
//
//  WATCH OUT:
//    - Reset is released on a FALLING clock edge, so it never changes at the
//      same moment as a rising edge (no race with the DUT's flops).
//    - The DUT parameters come from cache_tb_defs_pkg, the same numbers the
//      classes use.
//    - Waves (dump.vcd): by default only the interface pins + DUT top level.
//      +DUMP_ALL = everything (big for long tests), +NODUMP = no waves.
//    - uvm_top.set_timeout(20ms): if anything ever hangs, UVM stops with a
//      FATAL and still prints the summary (instead of the tool killing the run).
//    - The SVA checker is bound into the DUT automatically (bind in
//      cache_ctrl_sva.sv); nothing to do here.
//==============================================================================
module tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import cache_tb_defs_pkg::*;
  import cache_tb_pkg::*;

  // ---------------- clock and reset ----------------------------------------
  logic clk   = 1'b0;
  logic rst_n = 1'b0;

  always #(CLK_PERIOD / 2) clk = ~clk;

  initial begin
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  end

  // ---------------- interfaces ---------------------------------------------
  cache_cpu_if cpu_if (.clk(clk), .rst_n(rst_n));
  cache_mem_if mem_if (.clk(clk), .rst_n(rst_n));

  // ---------------- DUT ------------------------------------------------------
  cache_ctrl #(
    .ADDR_W     (DUT_ADDR_W),
    .DATA_W     (DUT_DATA_W),
    .LINE_BYTES (DUT_LINE_BYTES),
    .NUM_SETS   (DUT_NUM_SETS),
    .N_WAYS     (DUT_N_WAYS),
    .ID_W       (DUT_ID_W)
  ) dut (
    .clk            (clk),
    .rst_n          (rst_n),

    .cpu_req_valid  (cpu_if.req_valid),
    .cpu_req_ready  (cpu_if.req_ready),
    .cpu_req_id     (cpu_if.req_id),
    .cpu_req_we     (cpu_if.req_we),
    .cpu_req_addr   (cpu_if.req_addr),
    .cpu_req_wdata  (cpu_if.req_wdata),
    .cpu_req_wstrb  (cpu_if.req_wstrb),

    .cpu_rsp_valid  (cpu_if.rsp_valid),
    .cpu_rsp_ready  (cpu_if.rsp_ready),
    .cpu_rsp_id     (cpu_if.rsp_id),
    .cpu_rsp_we     (cpu_if.rsp_we),
    .cpu_rsp_rdata  (cpu_if.rsp_rdata),
    .cpu_rsp_err    (cpu_if.rsp_err),

    .flush_req      (cpu_if.flush_req),
    .flush_inv      (cpu_if.flush_inv),
    .flush_busy     (cpu_if.flush_busy),
    .flush_done     (cpu_if.flush_done),
    .flush_err      (cpu_if.flush_err),

    .mem_req_valid  (mem_if.req_valid),
    .mem_req_ready  (mem_if.req_ready),
    .mem_req_we     (mem_if.req_we),
    .mem_req_addr   (mem_if.req_addr),
    .mem_req_wdata  (mem_if.req_wdata),

    .mem_rsp_valid  (mem_if.rsp_valid),
    .mem_rsp_ready  (mem_if.rsp_ready),
    .mem_rsp_rdata  (mem_if.rsp_rdata),
    .mem_rsp_err    (mem_if.rsp_err)
  );

  // ---------------- UVM -----------------------------------------------------
  initial begin
    uvm_config_db #(virtual cache_cpu_if)::set(null, "uvm_test_top", "cpu_vif", cpu_if);
    uvm_config_db #(virtual cache_mem_if)::set(null, "uvm_test_top", "mem_vif", mem_if);
    uvm_top.set_timeout(20ms, 1);         // a hang ends with a UVM_FATAL + summary, not a wall-clock kill
    run_test("cache_smoke_test");
  end

  // ---------------- waves -----------------------------------------------------
  initial begin
    if ($test$plusargs("NODUMP")) begin
      // no waves
    end
    else if ($test$plusargs("DUMP_ALL")) begin
      $dumpfile("dump.vcd");
      $dumpvars(0, tb_top);                // everything, incl. DUT internals (big)
    end
    else begin
      $dumpfile("dump.vcd");
      $dumpvars(0, tb_top.cpu_if);         // default: just the pins (small)
      $dumpvars(0, tb_top.mem_if);
      $dumpvars(1, tb_top.dut);            // DUT top-level signals (state_q etc.)
    end
  end

endmodule
