// ============================================================
// cache_repl : replacement policy wrapper
// ------------------------------------------------------------
// One port list for every policy, so cache_ctrl never changes
// when the policy changes. REPL_POLICY selects the engine:
//   REPL_LRU (0) -> cache_lru  (true LRU, rank based)
//   REPL_LFU (1) -> cache_lfu  (saturating access counters)
//
// Contract with cache_ctrl:
//   - victim_way is combinational from (req_set, way_valid) and
//     is sampled by the controller in the LOOKUP cycle of a miss.
//   - hit    : 1-cycle strobe in LOOKUP on a hit   (update)
//   - refill : 1-cycle strobe in FILL  on install  (update)
// ============================================================

module cache_repl
  import cache_pkg::*;
#(
  parameter int unsigned NUM_SETS    = 64,
  parameter int unsigned N_WAYS      = 4,
  parameter int unsigned REPL_POLICY = REPL_LRU,
  parameter int unsigned LFU_CNT_W   = 4
)(
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              req_valid,
  input  logic                              hit,
  input  logic                              refill,
  input  logic [safe_clog2(NUM_SETS)-1:0]   req_set,
  input  logic [safe_clog2(N_WAYS)-1:0]     hit_way,
  input  logic [safe_clog2(N_WAYS)-1:0]     refill_way,
  input  logic [N_WAYS-1:0]                 way_valid,
  output logic [safe_clog2(N_WAYS)-1:0]     victim_way
);

  if (REPL_POLICY == REPL_LRU) begin : g_lru

    cache_lru #(
      .NUM_SETS  (NUM_SETS),
      .WAY_COUNT (N_WAYS)
    ) u_lru (
      .clk          (clk),
      .rst_n        (rst_n),
      .req_valid    (req_valid),
      .hit          (hit),
      .refill       (refill),
      .req_set      (req_set),
      .hit_way      (hit_way),
      .refill_way   (refill_way),
      .way_valid    (way_valid),
      .victim_valid (),               // controller only samples victim_way when it needs it
      .victim_way   (victim_way)
    );

  end
  else if (REPL_POLICY == REPL_LFU) begin : g_lfu

    cache_lfu #(
      .NUM_SETS (NUM_SETS),
      .N_WAYS   (N_WAYS),
      .CNT_W    (LFU_CNT_W)
    ) u_lfu (
      .clk        (clk),
      .rst_n      (rst_n),
      .req_valid  (req_valid),
      .hit        (hit),
      .refill     (refill),
      .req_set    (req_set),
      .hit_way    (hit_way),
      .refill_way (refill_way),
      .way_valid  (way_valid),
      .victim_way (victim_way)
    );

  end
  else begin : g_bad_policy

    $error("cache_repl: unknown REPL_POLICY %0d (use REPL_LRU=0 or REPL_LFU=1)", REPL_POLICY);

  end

endmodule
