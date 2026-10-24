// ============================================================
// cache_ctrl_sva : protocol and design assertions
// ------------------------------------------------------------
// Bound into every cache_ctrl instance (see bind at the bottom),
// so the RTL stays clean and the checker can be turned off by
// leaving this file out of the compile.
//
// Naming:
//   ENV_*  : rules the environment (your UVM driver / memory
//            responder) must follow. If these fire, the TB is
//            wrong, not the DUT.
//   DUT_*  : rules the cache must follow.
//   COV_*  : scenarios you want to see covered.
// ============================================================

module cache_ctrl_sva
  import cache_pkg::*;
#(
  parameter int unsigned ADDR_W     = 32,
  parameter int unsigned DATA_W     = 32,
  parameter int unsigned LINE_BYTES = 16,
  parameter int unsigned ID_W       = 4
)(
  input logic                     clk,
  input logic                     rst_n,

  input logic                     cpu_req_valid,
  input logic                     cpu_req_ready,
  input logic [ID_W-1:0]          cpu_req_id,
  input logic                     cpu_req_we,
  input logic [ADDR_W-1:0]        cpu_req_addr,
  input logic [DATA_W-1:0]        cpu_req_wdata,
  input logic [DATA_W/8-1:0]      cpu_req_wstrb,

  input logic                     cpu_rsp_valid,
  input logic                     cpu_rsp_ready,
  input logic [ID_W-1:0]          cpu_rsp_id,
  input logic                     cpu_rsp_we,
  input logic [DATA_W-1:0]        cpu_rsp_rdata,
  input logic                     cpu_rsp_err,

  input logic                     flush_req,
  input logic                     flush_busy,
  input logic                     flush_done,

  input logic                     mem_req_valid,
  input logic                     mem_req_ready,
  input logic                     mem_req_we,
  input logic [ADDR_W-1:0]        mem_req_addr,
  input logic [LINE_BYTES*8-1:0]  mem_req_wdata,

  input logic                     mem_rsp_valid,
  input logic                     mem_rsp_ready,
  input logic [LINE_BYTES*8-1:0]  mem_rsp_rdata,
  input logic                     mem_rsp_err,

  // Internal signals
  input cache_state_t             state_q,
  input logic                     lk_hit,
  input logic                     lk_multi_hit,
  input logic                     flush_mode_q
);

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);


  // ========================================================
  // Handshake helpers
  // ========================================================

  logic cpu_req_fire, cpu_rsp_fire, mem_req_fire, mem_rsp_fire;

  assign cpu_req_fire = cpu_req_valid && cpu_req_ready;
  assign cpu_rsp_fire = cpu_rsp_valid && cpu_rsp_ready;
  assign mem_req_fire = mem_req_valid && mem_req_ready;
  assign mem_rsp_fire = mem_rsp_valid && mem_rsp_ready;


  // ========================================================
  // Outstanding-transaction trackers
  // ========================================================

  logic            cpu_outstanding;
  logic            mem_outstanding;
  logic            mem_out_we;
  logic [ID_W-1:0] exp_id;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_outstanding <= 1'b0;
      mem_outstanding <= 1'b0;
      mem_out_we      <= 1'b0;
      exp_id          <= '0;
    end else begin
      if (cpu_req_fire) begin
        cpu_outstanding <= 1'b1;
        exp_id          <= cpu_req_id;
      end
      else if (cpu_rsp_fire) begin
        cpu_outstanding <= 1'b0;
      end

      if (mem_req_fire) begin
        mem_outstanding <= 1'b1;
        mem_out_we      <= mem_req_we;
      end
      else if (mem_rsp_fire) begin
        mem_outstanding <= 1'b0;
      end
    end
  end


  // ========================================================
  // ENV: valid/ready stability (AXI-style rules)
  // ========================================================

  ENV_cpu_req_stable: assert property (
    cpu_req_valid && !cpu_req_ready |=>
      cpu_req_valid && $stable({cpu_req_id, cpu_req_we, cpu_req_addr, cpu_req_wdata, cpu_req_wstrb})
  ) else $error("ENV: CPU request changed or dropped before it was accepted");

  ENV_mem_rsp_stable: assert property (
    mem_rsp_valid && !mem_rsp_ready |=>
      mem_rsp_valid && $stable({mem_rsp_rdata, mem_rsp_err})
  ) else $error("ENV: memory response changed or dropped before it was accepted");

  ENV_mem_rsp_only_when_pending: assert property (
    mem_rsp_valid |-> mem_outstanding
  ) else $error("ENV: memory response with no outstanding request");

  ENV_flush_hold: assert property (
    flush_req && !flush_busy && !cpu_outstanding |=> flush_req || flush_busy
  ) else $error("ENV: flush_req dropped before the flush started");


  // ========================================================
  // DUT: interface behaviour
  // ========================================================

  DUT_cpu_rsp_stable: assert property (
    cpu_rsp_valid && !cpu_rsp_ready |=>
      cpu_rsp_valid && $stable({cpu_rsp_id, cpu_rsp_we, cpu_rsp_rdata, cpu_rsp_err})
  ) else $error("DUT: CPU response changed or dropped before it was accepted");

  DUT_mem_req_stable: assert property (
    mem_req_valid && !mem_req_ready |=>
      mem_req_valid && $stable({mem_req_we, mem_req_addr, mem_req_wdata})
  ) else $error("DUT: memory request changed or dropped before it was accepted");

  DUT_one_cpu_outstanding: assert property (
    cpu_req_fire |-> !cpu_outstanding
  ) else $error("DUT: accepted a second CPU request while one is in flight");

  DUT_rsp_has_req: assert property (
    cpu_rsp_valid |-> cpu_outstanding
  ) else $error("DUT: CPU response with no request in flight");

  DUT_rsp_id_match: assert property (
    cpu_rsp_valid |-> (cpu_rsp_id == exp_id)
  ) else $error("DUT: response ID does not match the request ID");

  DUT_one_mem_outstanding: assert property (
    mem_req_valid |-> !mem_outstanding
  ) else $error("DUT: issued a memory request while one is outstanding");

  DUT_mem_addr_line_aligned: assert property (
    mem_req_valid |-> ((mem_req_addr & ADDR_W'(LINE_BYTES - 1)) == '0)
  ) else $error("DUT: memory request address is not line aligned");

  DUT_no_cpu_accept_in_flush: assert property (
    flush_mode_q |-> !cpu_req_ready
  ) else $error("DUT: accepted a CPU request during a flush");

  DUT_flush_done_pulse: assert property (
    flush_done |=> !flush_done
  ) else $error("DUT: flush_done is longer than one cycle");


  // ========================================================
  // DUT: internal state
  // ========================================================

  DUT_state_known: assert property (
    !$isunknown(state_q)
  ) else $error("DUT: FSM state is X/Z");

  DUT_no_multi_hit: assert property (
    (state_q == S_LOOKUP) |-> !lk_multi_hit
  ) else $error("DUT: same tag valid in two ways of one set");

  DUT_ready_only_in_idle: assert property (
    cpu_req_ready |-> (state_q == S_IDLE)
  ) else $error("DUT: cpu_req_ready outside IDLE");

  DUT_wb_before_refill: assert property (
    // A dirty-miss writeback must be followed by its refill read
    (state_q == S_WB_RSP) && mem_rsp_fire && !flush_mode_q |=> (state_q == S_RF_REQ)
  ) else $error("DUT: writeback was not followed by a refill");


  // ========================================================
  // Coverage
  // ========================================================

  COV_load_hit:      cover property ((state_q == S_LOOKUP) &&  lk_hit && !cpu_rsp_we);
  COV_store_hit:     cover property ((state_q == S_LOOKUP) &&  lk_hit &&  cpu_rsp_we);
  COV_clean_miss:    cover property ((state_q == S_LOOKUP) && !lk_hit ##1 (state_q == S_RF_REQ));
  COV_dirty_miss:    cover property ((state_q == S_LOOKUP) && !lk_hit ##1 (state_q == S_WB_REQ));
  COV_store_miss:    cover property ((state_q == S_FILL) && cpu_rsp_we);
  COV_flush_wb:      cover property (flush_mode_q && (state_q == S_WB_REQ));
  COV_mem_backpres:  cover property (mem_req_valid && !mem_req_ready);
  COV_cpu_backpres:  cover property (cpu_rsp_valid && !cpu_rsp_ready);
  COV_mem_error:     cover property (mem_rsp_fire && mem_rsp_err);

endmodule


// ============================================================
// Bind into every cache_ctrl instance
// ============================================================

bind cache_ctrl cache_ctrl_sva #(
  .ADDR_W     (ADDR_W),
  .DATA_W     (DATA_W),
  .LINE_BYTES (LINE_BYTES),
  .ID_W       (ID_W)
) u_cache_ctrl_sva (.*);
