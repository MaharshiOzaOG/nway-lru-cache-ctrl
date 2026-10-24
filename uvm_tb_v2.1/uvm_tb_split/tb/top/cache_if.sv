`timescale 1ns/1ps
//==============================================================================
//  File    : cache_if.sv           (cache_cpu_if + cache_mem_if)
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : The two bundles of wires between the testbench and the DUT.
//              cache_cpu_if : CPU request/response + flush control
//              cache_mem_if : line-level memory request/response
//            tb_top connects these wires to the DUT ports; the UVM classes get
//            a handle to them (a "virtual interface") through cache_cfg.
//
//  CLOCKING BLOCKS  (the single most important idea for TB timing)
//  -----------------------------------------------------------------
//    A clocking block says WHEN the testbench samples and WHEN it drives,
//    relative to the clock edge, so the TB and the DUT never race.
//
//            ~1 step before edge          edge              +1ns after edge
//      ---------|--------------------------|--------------------|----------
//            INPUTS sampled here       DUT flops update     TB OUTPUTS change
//            (#1step = value just      on this edge         here (#1)
//             before the edge)
//
//    - "input #1step"  : cb.sig gives the value the DUT saw AT the edge.
//                        So "cb.req_valid && cb.req_ready" read right after
//                        @(cb) is exactly "the handshake happened on this edge".
//    - "output #1"     : "cb.sig <= v" executed right after @(cb) changes the
//                        wire 1ns after the edge. The DUT sees it at the NEXT
//                        edge, like a flop output. No race with the DUT.
//    - Always do "@(cb);" BEFORE driving.  A drive executed between edges is
//      applied at the next edge + 1ns, so your own handshake loop would look
//      at that edge one cycle too early.
//
//  WHY THREE CLOCKING BLOCKS IN cache_cpu_if
//    drv_cb   : used only by cpu_drv   (drives request + rsp_ready)
//    flush_cb : used only by flush_drv (drives flush_req / flush_inv)
//    mon_cb   : used by cpu_mon and flush_mon (samples everything, drives nothing)
//    Two drivers share one interface, so each gets its own clocking block and
//    can only touch its own signals. The flush agent is separate on purpose
//    (so a flush can arrive while a CPU request is waiting).
//
//  WATCH OUT:
//    - TB-driven signals have initial values (= 0), so nothing is X when reset
//      ends, even before a driver has run.
//    - Not parameterized: widths come from cache_tb_defs_pkg (see that file).
//    - OTHER WAY: protocol assertions could live here too, so they travel with
//      the interface. For now all assertions stay in design/sva (bound to DUT).
//==============================================================================


//------------------------------------------------------------------------------
// CPU side + flush
//------------------------------------------------------------------------------
interface cache_cpu_if (input logic clk, input logic rst_n);

  import cache_tb_defs_pkg::*;

  // Request  (TB -> DUT, except ready)
  logic                 req_valid = 1'b0;
  logic                 req_ready;
  logic [ID_W-1:0]      req_id    = '0;
  logic                 req_we    = 1'b0;
  logic [ADDR_W-1:0]    req_addr  = '0;
  logic [DATA_W-1:0]    req_wdata = '0;
  logic [STRB_W-1:0]    req_wstrb = '0;

  // Response (DUT -> TB, except ready)
  logic                 rsp_valid;
  logic                 rsp_ready = 1'b0;
  logic [ID_W-1:0]      rsp_id;
  logic                 rsp_we;
  logic [DATA_W-1:0]    rsp_rdata;
  logic                 rsp_err;

  // Flush (TB -> DUT: req/inv;  DUT -> TB: busy/done/err)
  logic                 flush_req = 1'b0;
  logic                 flush_inv = 1'b0;
  logic                 flush_busy;
  logic                 flush_done;
  logic                 flush_err;

  // cpu_drv: drives the request channel and rsp_ready
  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output req_valid, req_id, req_we, req_addr, req_wdata, req_wstrb;
    output rsp_ready;
    input  req_ready;
    input  rsp_valid, rsp_id, rsp_we, rsp_rdata, rsp_err;
  endclocking

  // flush_drv: drives flush_req / flush_inv only
  clocking flush_cb @(posedge clk);
    default input #1step output #1;
    output flush_req, flush_inv;
    input  flush_busy, flush_done, flush_err;
  endclocking

  // monitors: sample everything, drive nothing
  clocking mon_cb @(posedge clk);
    default input #1step;
    input req_valid, req_ready, req_id, req_we, req_addr, req_wdata, req_wstrb;
    input rsp_valid, rsp_ready, rsp_id, rsp_we, rsp_rdata, rsp_err;
    input flush_req, flush_inv, flush_busy, flush_done, flush_err;
  endclocking

endinterface


//------------------------------------------------------------------------------
// Memory side (whole lines)
//------------------------------------------------------------------------------
interface cache_mem_if (input logic clk, input logic rst_n);

  import cache_tb_defs_pkg::*;

  // Request  (DUT -> TB, except ready)
  logic                 req_valid;
  logic                 req_ready = 1'b0;
  logic                 req_we;
  logic [ADDR_W-1:0]    req_addr;
  logic [LINE_W-1:0]    req_wdata;

  // Response (TB -> DUT, except ready)
  logic                 rsp_valid = 1'b0;
  logic                 rsp_ready;
  logic [LINE_W-1:0]    rsp_rdata = '0;
  logic                 rsp_err   = 1'b0;

  // mem_drv: plays main memory
  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output req_ready;
    output rsp_valid, rsp_rdata, rsp_err;
    input  req_valid, req_we, req_addr, req_wdata;
    input  rsp_ready;
  endclocking

  // mem_mon: samples everything
  clocking mon_cb @(posedge clk);
    default input #1step;
    input req_valid, req_ready, req_we, req_addr, req_wdata;
    input rsp_valid, rsp_ready, rsp_rdata, rsp_err;
  endclocking

endinterface
