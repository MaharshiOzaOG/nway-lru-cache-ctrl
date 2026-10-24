// ============================================================
// cache_dirty : dirty bit storage for a write-back cache
// ------------------------------------------------------------
// Your original module, adapted for the full controller:
//   - Widths derived from parameters (safe_clog2).
//   - writeback_addr is now a full line-aligned byte address
//     {tag, set, offset=0} instead of {tag, set}, so it can go
//     straight onto the memory request bus.
//   - evict_valid gates writeback_req: only a line that is both
//     VALID and DIRTY must be written back.
//   - wb_done clears the dirty bit of the evict_set/evict_way
//     line (the controller holds evict_* on the victim while the
//     writeback response is accepted).
//
// Event priority when two events hit the same line in one cycle
// (cannot happen in the blocking controller, kept for safety):
//   write_hit > refill_done > wb_done   (later assignment wins)
// ============================================================

module cache_dirty
  import cache_pkg::*;
#(
  parameter int unsigned NUM_SETS    = 64,
  parameter int unsigned N_WAYS      = 4,
  parameter int unsigned TAG_W       = 22,
  parameter int unsigned ADDR_W      = 32,
  parameter int unsigned OFFSET_BITS = 4
)(
  input  logic                              clk,
  input  logic                              rst_n,

  // Store hit: mark the line dirty
  input  logic                              write_hit,
  input  logic [safe_clog2(NUM_SETS)-1:0]   hit_set,
  input  logic [safe_clog2(N_WAYS)-1:0]     hit_way,

  // Line installed: dirty = 1 if it was a store miss (write-allocate)
  input  logic                              refill_done,
  input  logic                              write_alloc_fill,
  input  logic [safe_clog2(NUM_SETS)-1:0]   refill_set,
  input  logic [safe_clog2(N_WAYS)-1:0]     refill_way,

  // Eviction / flush candidate
  input  logic                              evict_valid,
  input  logic [safe_clog2(NUM_SETS)-1:0]   evict_set,
  input  logic [safe_clog2(N_WAYS)-1:0]     evict_way,
  input  logic [TAG_W-1:0]                  evict_tag,

  // Writeback accepted by memory: line is clean again
  input  logic                              wb_done,

  output logic                              evict_dirty,
  output logic                              writeback_req,
  output logic [ADDR_W-1:0]                 writeback_addr
);

  localparam int unsigned SET_BITS = $clog2(NUM_SETS);   // 0 when fully associative

  // dirty[set][way]
  logic [NUM_SETS-1:0][N_WAYS-1:0] dirty;


  // ========================================================
  // Outputs
  // ========================================================

  assign evict_dirty    = dirty[evict_set][evict_way];
  assign writeback_req  = evict_valid && dirty[evict_set][evict_way];

  // Rebuild the victim's byte address: {tag, set, offset = 0}
  assign writeback_addr = (ADDR_W'(evict_tag) << (SET_BITS + OFFSET_BITS))
                        | ((ADDR_W'(evict_set) & ADDR_W'(NUM_SETS - 1)) << OFFSET_BITS);


  // ========================================================
  // Dirty bit update
  // ========================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dirty <= '0;
    end else begin
      // Later assignments win when two events hit the same line,
      // so priority is: write_hit > refill_done > wb_done
      if (wb_done)
        dirty[evict_set][evict_way]   <= 1'b0;
      if (refill_done)
        dirty[refill_set][refill_way] <= write_alloc_fill;
      if (write_hit)
        dirty[hit_set][hit_way]       <= 1'b1;
    end
  end

endmodule
