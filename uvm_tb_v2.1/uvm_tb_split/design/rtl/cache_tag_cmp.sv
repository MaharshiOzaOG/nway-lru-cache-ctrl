// ============================================================
// cache_tag_cmp : tag comparison and hit/miss detection
// ------------------------------------------------------------
// Your original module. Changes:
//   - hit_way width uses safe_clog2 so N_WAYS = 1
//     (direct-mapped) is legal.
//   - hit_way assignment uses a cast instead of a part-select
//     of the loop variable (w[$clog2(N_WAYS)-1:0] becomes
//     w[-1:0] when N_WAYS = 1).
// ============================================================

module cache_tag_cmp
  import cache_pkg::*;
#(
  parameter int unsigned TAG_W  = 22,
  parameter int unsigned N_WAYS = 4
)(
  input  logic [TAG_W-1:0]               req_tag,
  input  logic [TAG_W-1:0]               way_tag [N_WAYS],
  input  logic [N_WAYS-1:0]              way_valid,
  output logic [N_WAYS-1:0]              way_match,
  output logic                           hit,
  output logic                           miss,
  output logic [safe_clog2(N_WAYS)-1:0]  hit_way,
  output logic                           multi_hit_error
);

  localparam int unsigned WAY_W = safe_clog2(N_WAYS);

  always_comb begin

    // A way matches only if it is valid AND its tag is equal
    for (int w = 0; w < N_WAYS; w++) begin
      way_match[w] = way_valid[w] && (way_tag[w] == req_tag);
    end

    hit             = |way_match;
    miss            = !hit;

    // x & (x-1) clears the lowest set bit; anything left over
    // means two or more ways matched -> corrupted tag state.
    multi_hit_error = |(way_match & (way_match - 1'b1));

    hit_way         = '0;

    // Lowest-index match wins.
    for (int w = 0; w < N_WAYS; w++) begin
      if (way_match[w]) begin
        hit_way = WAY_W'(w);    // index of the matching way
        break;
      end
    end

  end

endmodule
