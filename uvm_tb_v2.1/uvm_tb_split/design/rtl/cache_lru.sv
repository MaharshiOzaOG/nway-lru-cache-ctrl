// ============================================================
// N-Way Set-Associative Cache True LRU Controller
// ------------------------------------------------------------
// Your original cache_lru4, generalized to any WAY_COUNT.
// Changes:
//   1. accessed_rank is now a combinational signal. It used to
//      be a blocking (=) assignment inside always_ff, which is a
//      lint error and can mismatch between simulation and
//      synthesis.
//   2. Index widths use safe_clog2 so WAY_COUNT = 1 or
//      NUM_SETS = 1 is legal.
// ============================================================

module cache_lru
  import cache_pkg::*;
#(

    parameter int unsigned NUM_SETS  = 64,
    parameter int unsigned WAY_COUNT = 4

)(

    input  logic                               clk,
    input  logic                               rst_n,

    input  logic                               req_valid,
    input  logic                               hit,
    input  logic                               refill,       // new block installed -> promote to MRU

    input  logic [safe_clog2(NUM_SETS)-1:0]    req_set,
    input  logic [safe_clog2(WAY_COUNT)-1:0]   hit_way,
    input  logic [safe_clog2(WAY_COUNT)-1:0]   refill_way,   // way the refilled line is written into

    input  logic [WAY_COUNT-1:0]               way_valid,    // valid bit for each way

    output logic                               victim_valid,
    output logic [safe_clog2(WAY_COUNT)-1:0]   victim_way

);

    // ========================================================
    // Local parameters
    // ========================================================

    localparam int unsigned WAY_WIDTH = safe_clog2(WAY_COUNT);


    // ========================================================
    // LRU state
    // ========================================================
    //
    // Each way has a rank:
    //
    //   Rank 0             = Least Recently Used
    //   ...
    //   Rank WAY_COUNT - 1 = Most Recently Used
    //
    // The ranks of one set always form a permutation of
    // 0 .. WAY_COUNT-1.
    //
    // Example:
    //   lru_rank[5][0] = rank of Way 0 in Set 5
    //

    logic [WAY_WIDTH-1:0] lru_rank [NUM_SETS-1:0][WAY_COUNT-1:0];


    // ========================================================
    // Temporary variables
    // ========================================================

    logic                 invalid_found;

    logic [WAY_WIDTH-1:0] accessed_way;
    logic [WAY_WIDTH-1:0] accessed_rank;


    // ========================================================
    // Determine which way was accessed
    // ========================================================
    //
    // Refill has priority if hit and refill are both asserted.
    //

    always_comb begin

        accessed_way = '0;

        if (refill) begin
            accessed_way = refill_way;
        end
        else if (hit) begin
            accessed_way = hit_way;
        end

    end


    // ========================================================
    // Current rank of the accessed way  (FIX #1)
    // ========================================================
    //
    // This is the position from which the accessed way will be
    // moved to MRU. Computed combinationally, outside always_ff.
    //

    assign accessed_rank = lru_rank[req_set][accessed_way];


    // ========================================================
    // Victim selection
    // ========================================================

    always_comb begin

        // Default values
        victim_valid  = 1'b0;
        victim_way    = '0;

        invalid_found = 1'b0;

        if (req_valid) begin

            victim_valid = 1'b1;

            // ------------------------------------------------
            // Priority 1: lowest-index invalid way
            // ------------------------------------------------

            for (int way = 0; way < WAY_COUNT; way++) begin

                if ((way_valid[way] == 1'b0) &&
                    (invalid_found == 1'b0)) begin

                    victim_way    = WAY_WIDTH'(way);
                    invalid_found = 1'b1;

                end

            end

            // ------------------------------------------------
            // Priority 2: the way whose rank is zero (LRU)
            // ------------------------------------------------

            if (invalid_found == 1'b0) begin

                for (int way = 0; way < WAY_COUNT; way++) begin

                    if (lru_rank[req_set][way] == '0) begin
                        victim_way = WAY_WIDTH'(way);
                    end

                end

            end

        end

    end


    // ========================================================
    // LRU state update
    // ========================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            // Deterministic order after reset:
            //   Way 0 = Rank 0 = LRU ... Way N-1 = Rank N-1 = MRU

            for (int set_number = 0; set_number < NUM_SETS; set_number++) begin
                for (int way = 0; way < WAY_COUNT; way++) begin
                    lru_rank[set_number][way] <= WAY_WIDTH'(way);
                end
            end

        end

        else if (req_valid && (hit || refill)) begin

            // Update all ways in only the requested set.

            for (int way = 0; way < WAY_COUNT; way++) begin

                if (way == accessed_way) begin

                    // The accessed way becomes MRU.
                    lru_rank[req_set][way] <= WAY_WIDTH'(WAY_COUNT - 1);

                end
                else if (lru_rank[req_set][way] > accessed_rank) begin

                    // Ways newer than the accessed way move one
                    // position toward the LRU side.
                    lru_rank[req_set][way] <= lru_rank[req_set][way] - 1'b1;

                end
                else begin

                    // Ways older than the accessed way keep
                    // their current ranks.
                    lru_rank[req_set][way] <= lru_rank[req_set][way];

                end

            end

        end

    end

endmodule
