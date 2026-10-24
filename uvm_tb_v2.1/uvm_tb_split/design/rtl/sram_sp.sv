// ============================================================
// sram_sp : single-port synchronous SRAM model
// ------------------------------------------------------------
// Behaves like a real SRAM macro:
//   - Read : drive addr with en=1, we=0 in cycle N,
//            rdata is valid in cycle N+1.
//   - Write: drive addr/wdata/wbe with en=1, we=1.
//   - rdata HOLDS its value until the next read, which the
//     controller relies on (e.g. during writebacks and flush).
//   - No reset on the array (real SRAMs have none); the cache
//     valid bits live in flops and are reset instead.
//
// BE_W = number of independently writable lanes.
//   Data array : BE_W = LINE_BYTES (byte enables for stores)
//   Tag array  : BE_W = 1          (whole-entry writes)
// ============================================================

module sram_sp
  import cache_pkg::*;
#(
  parameter int unsigned DEPTH = 64,
  parameter int unsigned WIDTH = 128,
  parameter int unsigned BE_W  = 16
)(
  input  logic                          clk,
  input  logic                          en,
  input  logic                          we,
  input  logic [safe_clog2(DEPTH)-1:0]  addr,
  input  logic [WIDTH-1:0]              wdata,
  input  logic [BE_W-1:0]               wbe,
  output logic [WIDTH-1:0]              rdata
);

  // ========================================================
  // Local parameters
  // ========================================================

  localparam int unsigned LANE_W = WIDTH / BE_W;   // bits per write lane


  // ========================================================
  // Storage
  // ========================================================

  logic [WIDTH-1:0] mem [DEPTH];


  // ========================================================
  // Synchronous read / write
  // ========================================================

  always_ff @(posedge clk) begin

    if (en) begin

      if (we) begin

        // Write only the enabled lanes
        for (int b = 0; b < BE_W; b++) begin
          if (wbe[b]) begin
            mem[addr][b*LANE_W +: LANE_W] <= wdata[b*LANE_W +: LANE_W];
          end
        end

      end
      else begin

        // Registered read: data shows up next cycle
        rdata <= mem[addr];

      end

    end

  end


  // ========================================================
  // Parameter checks
  // ========================================================

  if ((WIDTH % BE_W) != 0) begin : g_chk_lane
    $error("sram_sp: WIDTH (%0d) must be a multiple of BE_W (%0d)", WIDTH, BE_W);
  end

endmodule
