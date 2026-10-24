// ============================================================
// cache_lfu : LFU replacement with saturating counters
// ------------------------------------------------------------
// Your original module. Changes:
//   1. Reset loop uses non-blocking (<=) assignments. Blocking
//      (=) inside always_ff is a lint error and can cause
//      simulation/synthesis mismatch.
//   2. Index widths use safe_clog2; victim_way assignment uses a
//      cast so N_WAYS = 1 is legal.
//
// Note: ties (equal counts) pick the lowest-index way, because
// the compare is strict (<).
// ============================================================

module cache_lfu
  import cache_pkg::*;
#(
  parameter int unsigned NUM_SETS = 64,
  parameter int unsigned N_WAYS   = 4,
  parameter int unsigned CNT_W    = 4
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

  localparam int unsigned      WAY_W   = safe_clog2(N_WAYS);
  localparam logic [CNT_W-1:0] MAX_CNT = {CNT_W{1'b1}};

  // freq[set][way] = access count of that line
  logic [CNT_W-1:0] freq [NUM_SETS][N_WAYS];


  // ========================================================
  // Victim selection
  // ========================================================

  always_comb begin

    logic             found_invalid;
    logic [CNT_W-1:0] min_freq;

    victim_way    = '0;
    found_invalid = 1'b0;
    min_freq      = MAX_CNT;

    // Priority 1: lowest-index invalid way
    for (int w = 0; w < N_WAYS; w++) begin
      if (!way_valid[w] && !found_invalid) begin
        victim_way    = WAY_W'(w);
        found_invalid = 1'b1;
      end
    end

    // Priority 2: way with the lowest count
    if (!found_invalid) begin
      for (int w = 0; w < N_WAYS; w++) begin
        if (freq[req_set][w] < min_freq) begin
          min_freq   = freq[req_set][w];
          victim_way = WAY_W'(w);
        end
      end
      // After the loop victim_way holds the least frequently
      // used way (way 0 if every count is saturated).
    end

  end


  // ========================================================
  // Counter update
  // ========================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      for (int i = 0; i < NUM_SETS; i++) begin
        for (int j = 0; j < N_WAYS; j++) begin
          freq[i][j] <= '0;                       // FIX #1: was '='
        end
      end

    end
    else if (req_valid) begin

      // Hit: count one more use (saturating)
      if (hit && (freq[req_set][hit_way] < MAX_CNT))
        freq[req_set][hit_way] <= freq[req_set][hit_way] + 1'b1;

      // Refill: a freshly installed line starts at 1
      if (refill)
        freq[req_set][refill_way] <= CNT_W'(1);

    end

  end

endmodule
