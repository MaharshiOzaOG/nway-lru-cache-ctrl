// ============================================================
// cache_ctrl : parameterized write-back / write-allocate
//              set-associative data cache controller
// ------------------------------------------------------------
//
//   CPU side  : valid/ready request + valid/ready response
//               (one word per access, byte strobes for stores)
//   Mem side  : valid/ready request + valid/ready response
//               (ONE WHOLE CACHE LINE per transaction)
//
// Transaction boundaries (kept simple on purpose so an AXI4
// master adapter can be dropped in later):
//   - Blocking: one CPU request in flight at a time.
//   - One outstanding memory request at a time.
//   - Every memory transaction is a full, line-aligned line:
//       read  (mem_req_we = 0) -> refill     -> AXI AR + R burst
//       write (mem_req_we = 1) -> writeback  -> AXI AW + W burst + B
//     Writes also get a response (like AXI B), so the controller
//     always knows when memory has the data.
//   - Splitting a line into beats is the adapter's job, not the
//     controller's.
//
// Storage:
//   - Tag and data arrays are synchronous SRAMs (1-cycle read).
//   - Valid bits are flops (reset to 0), dirty bits live in
//     cache_dirty, replacement state in cache_repl.
//
// Timing (no backpressure):
//   hit  : request in cycle 0, response valid in cycle 2
//   miss : hit timing + writeback (if dirty) + refill + 1 FILL cycle
//
// Address split (byte address, defaults shown):
//
//    31                    10 9            4 3        2 1      0
//   +------------------------+--------------+----------+--------+
//   |          TAG           |     SET      | WORD OFF | BYTE   |
//   |    TAG_W = 22 bits     | SET_BITS = 6 |  2 bits  | 2 bits |
//   +------------------------+--------------+----------+--------+
//                                           |<-- OFFSET_BITS -->|
//
// ============================================================

module cache_ctrl
  import cache_pkg::*;
#(
  parameter int unsigned ADDR_W      = 32,         // byte address width
  parameter int unsigned DATA_W      = 32,         // CPU word width (multiple of 8)
  parameter int unsigned LINE_BYTES  = 16,         // cache line size in bytes (power of 2)
  parameter int unsigned NUM_SETS    = 64,         // number of sets (power of 2, 1 = fully assoc.)
  parameter int unsigned N_WAYS      = 4,          // associativity (1 = direct mapped)
  parameter int unsigned REPL_POLICY = REPL_LRU,   // REPL_LRU or REPL_LFU
  parameter int unsigned LFU_CNT_W   = 4,          // LFU counter width
  parameter int unsigned ID_W        = 4           // CPU request ID width
)(
  input  logic                         clk,
  input  logic                         rst_n,

  // ---------------- CPU request ----------------
  input  logic                         cpu_req_valid,
  output logic                         cpu_req_ready,
  input  logic [ID_W-1:0]              cpu_req_id,
  input  logic                         cpu_req_we,      // 1 = store, 0 = load
  input  logic [ADDR_W-1:0]            cpu_req_addr,    // byte address
  input  logic [DATA_W-1:0]            cpu_req_wdata,
  input  logic [DATA_W/8-1:0]          cpu_req_wstrb,   // byte enables for stores

  // ---------------- CPU response ---------------
  output logic                         cpu_rsp_valid,
  input  logic                         cpu_rsp_ready,
  output logic [ID_W-1:0]              cpu_rsp_id,
  output logic                         cpu_rsp_we,      // echo: 1 = store ack, 0 = load data
  output logic [DATA_W-1:0]            cpu_rsp_rdata,   // load data (0 for stores)
  output logic                         cpu_rsp_err,     // memory error during this access

  // ---------------- Flush ----------------------
  input  logic                         flush_req,       // hold until flush_done
  input  logic                         flush_inv,       // 1 = also invalidate every line
  output logic                         flush_busy,
  output logic                         flush_done,      // 1-cycle pulse
  output logic                         flush_err,       // valid with flush_done

  // ---------------- Memory request -------------
  output logic                         mem_req_valid,
  input  logic                         mem_req_ready,
  output logic                         mem_req_we,      // 1 = line write (writeback), 0 = line read (refill)
  output logic [ADDR_W-1:0]            mem_req_addr,    // line-aligned byte address
  output logic [LINE_BYTES*8-1:0]      mem_req_wdata,   // full line for writes

  // ---------------- Memory response ------------
  input  logic                         mem_rsp_valid,
  output logic                         mem_rsp_ready,
  input  logic [LINE_BYTES*8-1:0]      mem_rsp_rdata,   // full line for reads
  input  logic                         mem_rsp_err
);

  // ========================================================
  // Local parameters (everything derived, nothing hardcoded)
  // ========================================================

  localparam int unsigned BYTES_PER_WORD = DATA_W / 8;
  localparam int unsigned LINE_W         = LINE_BYTES * 8;
  localparam int unsigned WORDS_PER_LINE = LINE_BYTES / BYTES_PER_WORD;

  localparam int unsigned BYTE_OFF_BITS  = $clog2(BYTES_PER_WORD);      // byte within word
  localparam int unsigned OFFSET_BITS    = $clog2(LINE_BYTES);          // byte within line
  localparam int unsigned SET_BITS       = $clog2(NUM_SETS);            // 0 if fully associative
  localparam int unsigned TAG_W          = ADDR_W - SET_BITS - OFFSET_BITS;

  // Index widths, never zero (see cache_pkg::safe_clog2)
  localparam int unsigned SET_W          = safe_clog2(NUM_SETS);
  localparam int unsigned WAY_W          = safe_clog2(N_WAYS);
  localparam int unsigned WOFF_W         = safe_clog2(WORDS_PER_LINE);


  // ========================================================
  // Address split helpers
  // ========================================================
  //
  // Shift-and-mask instead of part-selects, so configs where
  // a field is 0 bits wide (1 set, 1 word per line) still work.
  //

  function automatic logic [TAG_W-1:0] addr_tag(input logic [ADDR_W-1:0] a);
    return TAG_W'(a >> (OFFSET_BITS + SET_BITS));
  endfunction

  function automatic logic [SET_W-1:0] addr_set(input logic [ADDR_W-1:0] a);
    return SET_W'((a >> OFFSET_BITS) & ADDR_W'(NUM_SETS - 1));
  endfunction

  function automatic logic [WOFF_W-1:0] addr_woff(input logic [ADDR_W-1:0] a);
    return WOFF_W'((a >> BYTE_OFF_BITS) & ADDR_W'(WORDS_PER_LINE - 1));
  endfunction

  // Pick one CPU word out of a cache line
  function automatic logic [DATA_W-1:0] get_word(input logic [LINE_W-1:0] line,
                                                  input logic [WOFF_W-1:0] woff);
    return line[woff*DATA_W +: DATA_W];
  endfunction


  // ========================================================
  // FSM state
  // ========================================================

  cache_state_t state_q, state_d;


  // ========================================================
  // Captured CPU request (held for the whole transaction)
  // ========================================================

  logic [ID_W-1:0]            req_id_q;
  logic                       req_we_q;
  logic [ADDR_W-1:0]          req_addr_q;
  logic [DATA_W-1:0]          req_wdata_q;
  logic [BYTES_PER_WORD-1:0]  req_wstrb_q;

  // Fields of the captured address
  logic [TAG_W-1:0]           req_tag;
  logic [SET_W-1:0]           req_set;
  logic [WOFF_W-1:0]          req_woff;

  assign req_tag  = addr_tag (req_addr_q);
  assign req_set  = addr_set (req_addr_q);
  assign req_woff = addr_woff(req_addr_q);


  // ========================================================
  // Miss / writeback / refill bookkeeping
  // ========================================================

  logic [WAY_W-1:0]           victim_way_q;    // way being evicted / refilled
  logic [ADDR_W-1:0]          wb_addr_q;       // line address of the dirty victim
  logic [LINE_W-1:0]          victim_line_q;   // dirty victim data (writeback buffer)
  logic [LINE_W-1:0]          refill_line_q;   // line returned by memory
  logic                       wb_err_q;
  logic                       rf_err_q;

  // Registered CPU response payload
  logic [DATA_W-1:0]          rsp_rdata_q;
  logic                       rsp_err_q;


  // ========================================================
  // Flush bookkeeping
  // ========================================================

  logic                       flush_mode_q;    // 1 while a flush is running
  logic                       flush_inv_q;
  logic [SET_W-1:0]           flush_set_q;
  logic [WAY_W-1:0]           flush_way_q;
  logic                       flush_err_q;

  logic                       last_way;
  logic                       last_set;

  assign last_way = (flush_way_q == WAY_W'(N_WAYS   - 1));
  assign last_set = (flush_set_q == SET_W'(NUM_SETS - 1));


  // ========================================================
  // Valid bits (flops, reset to 0)
  // ========================================================

  logic [N_WAYS-1:0]          valid_q [NUM_SETS];


  // ========================================================
  // Set currently being worked on
  // ========================================================
  //
  // Normal requests use the captured request's set.
  // A flush walks its own set counter.
  //

  logic [SET_W-1:0]           cur_set;

  assign cur_set = flush_mode_q ? flush_set_q : req_set;


  // ========================================================
  // Tag and data SRAMs (one pair per way)
  // ========================================================

  logic [SET_W-1:0]           sram_addr;

  logic [N_WAYS-1:0]          tag_en,  tag_we;
  logic [TAG_W-1:0]           tag_wdata;
  logic [TAG_W-1:0]           tag_rdata  [N_WAYS];

  logic [N_WAYS-1:0]          data_en, data_we;
  logic [LINE_W-1:0]          data_wdata;
  logic [LINE_BYTES-1:0]      data_wbe;
  logic [LINE_W-1:0]          data_rdata [N_WAYS];

  for (genvar w = 0; w < N_WAYS; w++) begin : g_way

    sram_sp #(
      .DEPTH (NUM_SETS),
      .WIDTH (TAG_W),
      .BE_W  (1)
    ) u_tag_ram (
      .clk   (clk),
      .en    (tag_en[w]),
      .we    (tag_we[w]),
      .addr  (sram_addr),
      .wdata (tag_wdata),
      .wbe   (1'b1),
      .rdata (tag_rdata[w])
    );

    sram_sp #(
      .DEPTH (NUM_SETS),
      .WIDTH (LINE_W),
      .BE_W  (LINE_BYTES)
    ) u_data_ram (
      .clk   (clk),
      .en    (data_en[w]),
      .we    (data_we[w]),
      .addr  (sram_addr),
      .wdata (data_wdata),
      .wbe   (data_wbe),
      .rdata (data_rdata[w])
    );

  end


  // ========================================================
  // Tag compare  (valid in LOOKUP, the cycle after the read)
  // ========================================================

  logic [N_WAYS-1:0]          lk_way_match;
  logic                       lk_hit;
  logic                       lk_miss;
  logic [WAY_W-1:0]           lk_hit_way;
  logic                       lk_multi_hit;

  cache_tag_cmp #(
    .TAG_W  (TAG_W),
    .N_WAYS (N_WAYS)
  ) u_tag_cmp (
    .req_tag         (req_tag),
    .way_tag         (tag_rdata),
    .way_valid       (valid_q[req_set]),
    .way_match       (lk_way_match),
    .hit             (lk_hit),
    .miss            (lk_miss),
    .hit_way         (lk_hit_way),
    .multi_hit_error (lk_multi_hit)
  );

  // Hit qualified by state: tag compare output is only
  // meaningful in LOOKUP.
  logic                       lookup_hit;

  assign lookup_hit  = (state_q == S_LOOKUP) && lk_hit;


  // ========================================================
  // Replacement policy (LRU or LFU)
  // ========================================================

  logic [WAY_W-1:0]           victim_way_c;    // combinational victim choice
  logic                       fill_ok;         // line actually installed this cycle

  assign fill_ok = (state_q == S_FILL) && !rf_err_q;

  cache_repl #(
    .NUM_SETS    (NUM_SETS),
    .N_WAYS      (N_WAYS),
    .REPL_POLICY (REPL_POLICY),
    .LFU_CNT_W   (LFU_CNT_W)
  ) u_repl (
    .clk        (clk),
    .rst_n      (rst_n),
    .req_valid  ((state_q == S_LOOKUP) || (state_q == S_FILL)),
    .hit        (lookup_hit),
    .refill     (fill_ok),
    .req_set    (req_set),
    .hit_way    (lk_hit_way),
    .refill_way (victim_way_q),
    .way_valid  (valid_q[req_set]),
    .victim_way (victim_way_c)
  );


  // ========================================================
  // Dirty bits
  // ========================================================
  //
  // evict_way points at the line we are currently deciding
  // about:
  //   LOOKUP   : the freshly chosen victim
  //   FL_CHECK : the flush cursor
  //   FL_NEXT  : the flush cursor (to guard invalidation)
  //   others   : the captured victim (used by wb_done clear)
  //

  logic [WAY_W-1:0]           evict_way;
  logic                       evict_valid;
  logic                       evict_dirty;
  logic                       writeback_req;
  logic [ADDR_W-1:0]          writeback_addr;

  always_comb begin
    case (state_q)
      S_LOOKUP:   evict_way = victim_way_c;
      S_FL_CHECK: evict_way = flush_way_q;
      S_FL_NEXT:  evict_way = flush_way_q;
      default:    evict_way = victim_way_q;
    endcase
  end

  assign evict_valid = valid_q[cur_set][evict_way];

  cache_dirty #(
    .NUM_SETS    (NUM_SETS),
    .N_WAYS      (N_WAYS),
    .TAG_W       (TAG_W),
    .ADDR_W      (ADDR_W),
    .OFFSET_BITS (OFFSET_BITS)
  ) u_dirty (
    .clk              (clk),
    .rst_n            (rst_n),

    .write_hit        (lookup_hit && req_we_q),
    .hit_set          (req_set),
    .hit_way          (lk_hit_way),

    .refill_done      (fill_ok),
    .write_alloc_fill (req_we_q),           // store miss -> line is dirty right away
    .refill_set       (req_set),
    .refill_way       (victim_way_q),

    .evict_valid      (evict_valid),
    .evict_set        (cur_set),
    .evict_way        (evict_way),
    .evict_tag        (tag_rdata[evict_way]),

    .wb_done          ((state_q == S_WB_RSP) && mem_rsp_valid && !mem_rsp_err),

    .evict_dirty      (evict_dirty),
    .writeback_req    (writeback_req),
    .writeback_addr   (writeback_addr)
  );


  // ========================================================
  // Store data placement
  // ========================================================
  //
  // Store HIT : write one word into the line using byte enables.
  //             The word is replicated across the line and the
  //             byte enables pick the right word and bytes.
  //
  //   e.g. 16 B line, 4 B word, woff = 2, wstrb = 4'b0011
  //        data_wbe = 16'b0000_0011_0000_0000
  //
  // Store MISS: merge the store into the refilled line before it
  //             is written into the data array (write-allocate).
  //

  logic [LINE_BYTES-1:0]      store_wbe;
  logic [LINE_W-1:0]          fill_line;

  assign store_wbe = LINE_BYTES'(req_wstrb_q) << (req_woff * BYTES_PER_WORD);

  always_comb begin
    fill_line = refill_line_q;
    if (req_we_q) begin
      for (int b = 0; b < BYTES_PER_WORD; b++) begin
        if (req_wstrb_q[b]) begin
          fill_line[req_woff*DATA_W + b*8 +: 8] = req_wdata_q[b*8 +: 8];
        end
      end
    end
  end


  // ========================================================
  // SRAM control
  // ========================================================

  always_comb begin

    // Defaults: SRAMs idle
    sram_addr  = req_set;
    tag_en     = '0;
    tag_we     = '0;
    tag_wdata  = req_tag;
    data_en    = '0;
    data_we    = '0;
    data_wdata = {WORDS_PER_LINE{req_wdata_q}};
    data_wbe   = '1;

    case (state_q)

      // Read all ways of the requested set as the request is
      // accepted, so tags/data are ready in LOOKUP.
      S_IDLE: begin
        if (cpu_req_valid && cpu_req_ready) begin
          sram_addr = addr_set(cpu_req_addr);
          tag_en    = '1;
          data_en   = '1;
        end
      end

      // Store hit: write the word into the hit way.
      S_LOOKUP: begin
        if (lk_hit && req_we_q) begin
          data_en[lk_hit_way] = 1'b1;
          data_we[lk_hit_way] = 1'b1;
          data_wbe            = store_wbe;
        end
      end

      // Install the refilled (and possibly merged) line.
      S_FILL: begin
        if (!rf_err_q) begin
          tag_en [victim_way_q] = 1'b1;
          tag_we [victim_way_q] = 1'b1;
          data_en[victim_way_q] = 1'b1;
          data_we[victim_way_q] = 1'b1;
          data_wdata            = fill_line;
          data_wbe              = '1;
        end
      end

      // Flush: read all ways of the flush set.
      S_FL_READ: begin
        sram_addr = flush_set_q;
        tag_en    = '1;
        data_en   = '1;
      end

      default: ;

    endcase

  end


  // ========================================================
  // Next-state logic
  // ========================================================

  always_comb begin

    state_d = state_q;

    case (state_q)

      S_IDLE: begin
        if (flush_req)            state_d = S_FL_READ;     // flush has priority
        else if (cpu_req_valid)   state_d = S_LOOKUP;      // cpu_req_ready = 1 here
      end

      S_LOOKUP: begin
        if (lk_hit)               state_d = S_RESP;
        else if (writeback_req)   state_d = S_WB_REQ;      // victim valid and dirty
        else                      state_d = S_RF_REQ;      // victim clean or invalid
      end

      S_WB_REQ: begin
        if (mem_req_ready)        state_d = S_WB_RSP;
      end

      S_WB_RSP: begin
        if (mem_rsp_valid)        state_d = flush_mode_q ? S_FL_NEXT : S_RF_REQ;
      end

      S_RF_REQ: begin
        if (mem_req_ready)        state_d = S_RF_RSP;
      end

      S_RF_RSP: begin
        if (mem_rsp_valid)        state_d = S_FILL;
      end

      S_FILL: begin
                                  state_d = S_RESP;
      end

      S_RESP: begin
        if (cpu_rsp_ready)        state_d = S_IDLE;
      end

      S_FL_READ: begin
                                  state_d = S_FL_CHECK;
      end

      S_FL_CHECK: begin
        if (writeback_req)        state_d = S_WB_REQ;
        else                      state_d = S_FL_NEXT;
      end

      S_FL_NEXT: begin
        if (last_way && last_set) state_d = S_FL_DONE;
        else if (last_way)        state_d = S_FL_READ;     // new set -> read SRAMs again
        else                      state_d = S_FL_CHECK;    // same set, rdata still held
      end

      S_FL_DONE: begin
                                  state_d = S_IDLE;
      end

      default:                    state_d = S_IDLE;

    endcase

  end


  // ========================================================
  // Datapath registers
  // ========================================================

  always_ff @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin

      state_q       <= S_IDLE;

      req_id_q      <= '0;
      req_we_q      <= 1'b0;
      req_addr_q    <= '0;
      req_wdata_q   <= '0;
      req_wstrb_q   <= '0;

      victim_way_q  <= '0;
      wb_addr_q     <= '0;
      victim_line_q <= '0;
      refill_line_q <= '0;
      wb_err_q      <= 1'b0;
      rf_err_q      <= 1'b0;

      rsp_rdata_q   <= '0;
      rsp_err_q     <= 1'b0;

      flush_mode_q  <= 1'b0;
      flush_inv_q   <= 1'b0;
      flush_set_q   <= '0;
      flush_way_q   <= '0;
      flush_err_q   <= 1'b0;

      for (int s = 0; s < NUM_SETS; s++) begin
        valid_q[s] <= '0;
      end

    end
    else begin

      state_q <= state_d;

      case (state_q)

        // ------------------------------------------------
        // IDLE: start a flush or capture a CPU request
        // ------------------------------------------------
        S_IDLE: begin
          if (flush_req) begin
            flush_mode_q <= 1'b1;
            flush_inv_q  <= flush_inv;
            flush_set_q  <= '0;
            flush_way_q  <= '0;
            flush_err_q  <= 1'b0;
          end
          else if (cpu_req_valid) begin
            req_id_q    <= cpu_req_id;
            req_we_q    <= cpu_req_we;
            req_addr_q  <= cpu_req_addr;
            req_wdata_q <= cpu_req_wdata;
            req_wstrb_q <= cpu_req_wstrb;
            wb_err_q    <= 1'b0;
            rf_err_q    <= 1'b0;
          end
        end

        // ------------------------------------------------
        // LOOKUP: hit -> build response, miss -> grab victim
        // ------------------------------------------------
        S_LOOKUP: begin
          if (lk_hit) begin
            rsp_rdata_q <= req_we_q ? '0 : get_word(data_rdata[lk_hit_way], req_woff);
            rsp_err_q   <= 1'b0;
          end
          else begin
            victim_way_q  <= victim_way_c;
            wb_addr_q     <= writeback_addr;
            victim_line_q <= data_rdata[victim_way_c];   // writeback buffer
          end
        end

        // ------------------------------------------------
        // WB_RSP: memory acknowledged the line write
        // ------------------------------------------------
        S_WB_RSP: begin
          if (mem_rsp_valid) begin
            wb_err_q    <= mem_rsp_err;
            flush_err_q <= flush_err_q | (flush_mode_q & mem_rsp_err);
          end
        end

        // ------------------------------------------------
        // RF_RSP: capture the line from memory
        // ------------------------------------------------
        S_RF_RSP: begin
          if (mem_rsp_valid) begin
            refill_line_q <= mem_rsp_rdata;
            rf_err_q      <= mem_rsp_err;
          end
        end

        // ------------------------------------------------
        // FILL: line written into SRAM (see SRAM control),
        //       set valid, build the CPU response
        // ------------------------------------------------
        S_FILL: begin
          if (!rf_err_q) begin
            valid_q[req_set][victim_way_q] <= 1'b1;
          end
          rsp_rdata_q <= (req_we_q || rf_err_q) ? '0 : get_word(refill_line_q, req_woff);
          rsp_err_q   <= wb_err_q | rf_err_q;
        end

        // ------------------------------------------------
        // FL_CHECK: dirty line? capture it for writeback
        // ------------------------------------------------
        S_FL_CHECK: begin
          if (writeback_req) begin
            victim_way_q  <= flush_way_q;
            wb_addr_q     <= writeback_addr;
            victim_line_q <= data_rdata[flush_way_q];
          end
        end

        // ------------------------------------------------
        // FL_NEXT: optional invalidate, advance the cursor
        // ------------------------------------------------
        S_FL_NEXT: begin
          // Never invalidate a line that is still dirty
          // (its writeback failed) or its data would be lost.
          if (flush_inv_q && !evict_dirty) begin
            valid_q[flush_set_q][flush_way_q] <= 1'b0;
          end

          if (last_way) begin
            flush_way_q <= '0;
            flush_set_q <= flush_set_q + 1'b1;
          end
          else begin
            flush_way_q <= flush_way_q + 1'b1;
          end
        end

        // ------------------------------------------------
        // FL_DONE: flush finished
        // ------------------------------------------------
        S_FL_DONE: begin
          flush_mode_q <= 1'b0;
        end

        default: ;

      endcase

    end

  end


  // ========================================================
  // Interface outputs
  // ========================================================

  // CPU
  assign cpu_req_ready = (state_q == S_IDLE) && !flush_req;

  assign cpu_rsp_valid = (state_q == S_RESP);
  assign cpu_rsp_id    = req_id_q;
  assign cpu_rsp_we    = req_we_q;
  assign cpu_rsp_rdata = rsp_rdata_q;
  assign cpu_rsp_err   = rsp_err_q;

  // Flush
  assign flush_busy    = flush_mode_q;
  assign flush_done    = (state_q == S_FL_DONE);
  assign flush_err     = flush_err_q;

  // Memory: one line per transaction, one outstanding at a time
  assign mem_req_valid = (state_q == S_WB_REQ) || (state_q == S_RF_REQ);
  assign mem_req_we    = (state_q == S_WB_REQ);
  assign mem_req_addr  = (state_q == S_WB_REQ)
                         ? wb_addr_q
                         : (req_addr_q & ~ADDR_W'(LINE_BYTES - 1));   // line-aligned miss address
  assign mem_req_wdata = (state_q == S_WB_REQ) ? victim_line_q : '0;
  assign mem_rsp_ready = (state_q == S_WB_RSP) || (state_q == S_RF_RSP);


  // ========================================================
  // Parameter checks (elaboration time)
  // ========================================================

  if ((DATA_W % 8) != 0 || DATA_W == 0) begin : g_chk_data_w
    $error("cache_ctrl: DATA_W (%0d) must be a non-zero multiple of 8", DATA_W);
  end

  if ((1 << BYTE_OFF_BITS) != BYTES_PER_WORD) begin : g_chk_word_pow2
    $error("cache_ctrl: DATA_W/8 (%0d) must be a power of 2", BYTES_PER_WORD);
  end

  if ((1 << OFFSET_BITS) != LINE_BYTES || LINE_BYTES < BYTES_PER_WORD) begin : g_chk_line
    $error("cache_ctrl: LINE_BYTES (%0d) must be a power of 2 and >= DATA_W/8", LINE_BYTES);
  end

  if ((1 << SET_BITS) != NUM_SETS) begin : g_chk_sets
    $error("cache_ctrl: NUM_SETS (%0d) must be a power of 2", NUM_SETS);
  end

  if (N_WAYS < 1) begin : g_chk_ways
    $error("cache_ctrl: N_WAYS must be >= 1");
  end

  if (ADDR_W <= SET_BITS + OFFSET_BITS) begin : g_chk_tag
    $error("cache_ctrl: ADDR_W (%0d) leaves no tag bits", ADDR_W);
  end


  // ========================================================
  // Simulation trace (compile with +define+CACHE_TRACE)
  // ========================================================
  //
  // Prints the life of every transaction: address split,
  // hit/miss, victim, writeback, refill, merge, response.
  //

`ifdef CACHE_TRACE
  // synopsys translate_off
  always_ff @(posedge clk) begin
    if (rst_n) begin
      case (state_q)

        S_IDLE: begin
          if (flush_req)
            $display("[%0t] FLUSH start  invalidate=%0b", $time, flush_inv);
          else if (cpu_req_valid)
            $display("[%0t] REQ    id=%0d %s addr=0x%h -> tag=0x%h set=%0d woff=%0d | wdata=0x%h wstrb=%b",
                     $time, cpu_req_id, cpu_req_we ? "ST" : "LD", cpu_req_addr,
                     addr_tag(cpu_req_addr), addr_set(cpu_req_addr), addr_woff(cpu_req_addr),
                     cpu_req_wdata, cpu_req_wstrb);
        end

        S_LOOKUP: begin
          if (lk_hit)
            $display("[%0t] HIT    set=%0d way=%0d line=0x%h", $time,
                     req_set, lk_hit_way, data_rdata[lk_hit_way]);
          else
            $display("[%0t] MISS   set=%0d victim_way=%0d victim_valid=%0b victim_dirty=%0b victim_tag=0x%h",
                     $time, req_set, victim_way_c, evict_valid, evict_dirty, tag_rdata[victim_way_c]);
        end

        S_WB_REQ: begin
          if (mem_req_ready)
            $display("[%0t] WB     addr=0x%h line=0x%h", $time, mem_req_addr, mem_req_wdata);
        end

        S_WB_RSP: begin
          if (mem_rsp_valid)
            $display("[%0t] WB ack err=%0b", $time, mem_rsp_err);
        end

        S_RF_REQ: begin
          if (mem_req_ready)
            $display("[%0t] RF     addr=0x%h", $time, mem_req_addr);
        end

        S_RF_RSP: begin
          if (mem_rsp_valid)
            $display("[%0t] RF dat line=0x%h err=%0b", $time, mem_rsp_rdata, mem_rsp_err);
        end

        S_FILL: begin
          $display("[%0t] FILL   set=%0d way=%0d tag=0x%h line=0x%h dirty=%0b",
                   $time, req_set, victim_way_q, req_tag, fill_line, req_we_q);
        end

        S_RESP: begin
          if (cpu_rsp_ready)
            $display("[%0t] RSP    id=%0d %s rdata=0x%h err=%0b", $time,
                     cpu_rsp_id, cpu_rsp_we ? "ST" : "LD", cpu_rsp_rdata, cpu_rsp_err);
        end

        S_FL_CHECK: begin
          if (writeback_req)
            $display("[%0t] FLUSH  set=%0d way=%0d dirty -> writeback", $time, flush_set_q, flush_way_q);
        end

        S_FL_DONE: begin
          $display("[%0t] FLUSH done err=%0b", $time, flush_err_q);
        end

        default: ;

      endcase
    end
  end
  // synopsys translate_on
`endif

endmodule
