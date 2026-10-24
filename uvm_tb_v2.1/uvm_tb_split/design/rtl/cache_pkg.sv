// ============================================================
// cache_pkg
// ------------------------------------------------------------
// Shared definitions for the write-back / write-allocate cache:
//   - replacement policy selector values
//   - controller FSM state encoding (shared with the SVA module
//     and, later, with UVM monitors/coverage)
//   - safe_clog2 helper so 1-set / 1-way / 1-word configs never
//     produce zero-width vectors
// ============================================================

package cache_pkg;

  // ========================================================
  // Replacement policy selector (cache_ctrl.REPL_POLICY)
  // ========================================================

  localparam int unsigned REPL_LRU = 0;   // true LRU (rank based)
  localparam int unsigned REPL_LFU = 1;   // least frequently used (counter based)


  // ========================================================
  // Controller FSM states
  // ========================================================
  //
  //  Normal request path:
  //    IDLE -> LOOKUP -> RESP                          (hit)
  //    IDLE -> LOOKUP -> RF_REQ -> RF_RSP -> FILL -> RESP   (clean miss)
  //    IDLE -> LOOKUP -> WB_REQ -> WB_RSP ->
  //                      RF_REQ -> RF_RSP -> FILL -> RESP   (dirty miss)
  //
  //  Flush path (walks every set / way):
  //    IDLE -> FL_READ -> FL_CHECK -> (WB_REQ -> WB_RSP ->) FL_NEXT
  //         -> ... -> FL_DONE -> IDLE
  //

  typedef enum logic [3:0] {
    S_IDLE     = 4'd0,
    S_LOOKUP   = 4'd1,
    S_WB_REQ   = 4'd2,
    S_WB_RSP   = 4'd3,
    S_RF_REQ   = 4'd4,
    S_RF_RSP   = 4'd5,
    S_FILL     = 4'd6,
    S_RESP     = 4'd7,
    S_FL_READ  = 4'd8,
    S_FL_CHECK = 4'd9,
    S_FL_NEXT  = 4'd10,
    S_FL_DONE  = 4'd11
  } cache_state_t;


  // ========================================================
  // safe_clog2
  // ========================================================
  //
  // $clog2(1) = 0, which would create a zero-width index
  // (e.g. a direct-mapped cache has only 1 way). This helper
  // returns at least 1 so every index vector is legal.
  //

  function automatic int unsigned safe_clog2(input int unsigned n);
    return (n <= 1) ? 1 : $clog2(n);
  endfunction

endpackage
