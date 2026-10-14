`timescale 1ns/1ps
//=============================================================================
//  N-way set-associative, write-back / write-allocate, blocking L1 cache
//  with true LRU.   READABLE 3-BLOCK FSM VERSION
//  (same behaviour + same ports as cache_assoc.sv)
//
//  addr = [ tag | index | word | byte ]
//
//  READ THE FILE TOP TO BOTTOM:
//    BLOCK 1  state register        state_q <= state_d
//    BLOCK 2  next-state logic      state_q + inputs  ->  state_d
//    BLOCK 3  output logic          state_q + inputs  ->  ports + "strobes"
//    BLOCK 4  datapath flops        strobes  ->  update arrays / registers / LRU
//
//  Strobes (raised for ONE cycle by block 3):
//    capture_req  write_word  set_dirty  fill_line  lru_touch (+ touch_way)
//
//  Associativity extras (search "WAY"):
//    hit_way     which way matched the tag
//    victim_way  first invalid way, else the least-recently-used way
//    age_q       per-way LRU rank: 0 = most recent ... WAYS-1 = LRU
//=============================================================================
module cache_ctrl_assoc #(
  parameter int ADDR_W     = 32,
  parameter int DATA_W     = 32,
  parameter int LINE_WORDS = 4,
  parameter int NUM_SETS   = 16,
  parameter int WAYS       = 4      // >= 2
)(
  input  logic                          clk,
  input  logic                          rst_n,

  // CPU request
  input  logic                          cpu_req_valid,
  output logic                          cpu_req_ready,
  input  logic                          cpu_req_we,
  input  logic [ADDR_W-1:0]             cpu_req_addr,
  input  logic [DATA_W-1:0]             cpu_req_wdata,

  // CPU response
  output logic                          cpu_rsp_valid,
  output logic [DATA_W-1:0]             cpu_rsp_rdata,

  // Memory request (whole line)
  output logic                          mem_req_valid,
  output logic                          mem_req_we,
  output logic [ADDR_W-1:0]             mem_req_addr,
  output logic [LINE_WORDS*DATA_W-1:0]  mem_req_wdata,

  // Memory response
  input  logic                          mem_rsp_valid,
  input  logic [LINE_WORDS*DATA_W-1:0]  mem_rsp_rdata
);

  //=========================================================================
  // Widths
  //=========================================================================
  localparam int LINE_W = DATA_W * LINE_WORDS;
  localparam int BYTE_W = $clog2(DATA_W/8);
  localparam int WORD_W = $clog2(LINE_WORDS);
  localparam int OFF_W  = BYTE_W + WORD_W;
  localparam int IDX_W  = $clog2(NUM_SETS);
  localparam int TAG_W  = ADDR_W - OFF_W - IDX_W;
  localparam int WAY_W  = $clog2(WAYS);

  //=========================================================================
  // Storage (every array has a [way] dimension)
  //=========================================================================
  logic [TAG_W-1:0]  tag_q   [0:NUM_SETS-1][0:WAYS-1];
  logic [LINE_W-1:0] data_q  [0:NUM_SETS-1][0:WAYS-1];
  logic [WAYS-1:0]   valid_q [0:NUM_SETS-1];            // bit per way
  logic [WAYS-1:0]   dirty_q [0:NUM_SETS-1];            // bit per way
  logic [WAY_W-1:0]  age_q   [0:NUM_SETS-1][0:WAYS-1];  // LRU rank per way

  //=========================================================================
  // Captured request + address split
  //=========================================================================
  logic                req_we_q;
  logic [ADDR_W-1:0]   req_addr_q;
  logic [DATA_W-1:0]   req_wdata_q;

  logic [TAG_W-1:0]    req_tag;
  logic [IDX_W-1:0]    req_idx;
  logic [WORD_W-1:0]   req_woff;

  assign req_tag  = req_addr_q[ADDR_W-1 -: TAG_W];
  assign req_idx  = req_addr_q[OFF_W +: IDX_W];
  assign req_woff = req_addr_q[BYTE_W +: WORD_W];

  //=========================================================================
  // Hit / victim helpers  (pure combinational, the FSM looks at these)
  //=========================================================================
  logic             hit;
  logic [WAY_W-1:0] hit_way;

  always_comb begin                       // any way matches?
    hit     = 1'b0;
    hit_way = '0;
    for (int w = 0; w < WAYS; w++)
      if (valid_q[req_idx][w] && (tag_q[req_idx][w] == req_tag)) begin
        hit     = 1'b1;
        hit_way = WAY_W'(w);
      end
  end

  logic             found_inv;
  logic [WAY_W-1:0] victim_way;
  logic             victim_dirty;

  always_comb begin                       // invalid way first, else LRU way
    found_inv  = 1'b0;
    victim_way = '0;
    for (int w = 0; w < WAYS; w++)
      if (!valid_q[req_idx][w] && !found_inv) begin
        found_inv  = 1'b1;
        victim_way = WAY_W'(w);
      end
    if (!found_inv)
      for (int w = 0; w < WAYS; w++)
        if (age_q[req_idx][w] == WAY_W'(WAYS-1))
          victim_way = WAY_W'(w);
  end

  assign victim_dirty = valid_q[req_idx][victim_way] && dirty_q[req_idx][victim_way];

  //=========================================================================
  // FSM signals
  //=========================================================================
  typedef enum logic [1:0] {IDLE, COMPARE, WRITE_BACK, ALLOCATE} state_t;
  state_t state_q, state_d;

  // strobes: one-cycle commands from the FSM to the datapath
  logic             capture_req;   // latch cpu_req_* into req_*_q
  logic             write_word;    // write req_wdata_q into one word of hit_way
  logic             set_dirty;     // mark hit_way dirty
  logic             fill_line;     // install memory line into victim_way
  logic             lru_touch;     // make touch_way the most recently used
  logic [WAY_W-1:0] touch_way;

  //=========================================================================
  // BLOCK 1 : STATE REGISTER  (the only place state_q changes)
  //=========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_q <= IDLE;
    else        state_q <= state_d;
  end

  //=========================================================================
  // BLOCK 2 : NEXT-STATE LOGIC   (state_q + inputs -> state_d)
  //=========================================================================
  always_comb begin
    state_d = state_q;                                   // default: stay
    case (state_q)
      IDLE       : if (cpu_req_valid)  state_d = COMPARE;
      COMPARE    : if (hit)            state_d = IDLE;
                   else if (victim_dirty) state_d = WRITE_BACK;
                   else                   state_d = ALLOCATE;
      WRITE_BACK : if (mem_rsp_valid)  state_d = ALLOCATE;
      ALLOCATE   : if (mem_rsp_valid)  state_d = COMPARE;
      default    :                     state_d = IDLE;
    endcase
  end

  //=========================================================================
  // BLOCK 3 : OUTPUT LOGIC   (state_q + inputs -> ports and strobes)
  //   Every output has a default of 0, so each state only lists what it DOES.
  //=========================================================================
  always_comb begin
    // defaults
    cpu_req_ready = 1'b0;
    cpu_rsp_valid = 1'b0;
    mem_req_valid = 1'b0;
    mem_req_we    = 1'b0;
    mem_req_addr  = '0;
    capture_req   = 1'b0;
    write_word    = 1'b0;
    set_dirty     = 1'b0;
    fill_line     = 1'b0;
    lru_touch     = 1'b0;
    touch_way     = '0;

    case (state_q)
      IDLE : begin
        cpu_req_ready = 1'b1;
        capture_req   = cpu_req_valid;
      end

      COMPARE : begin
        if (hit) begin
          cpu_rsp_valid = 1'b1;
          lru_touch     = 1'b1;
          touch_way     = hit_way;
          if (req_we_q) begin          // store hit
            write_word = 1'b1;
            set_dirty  = 1'b1;
          end
        end
      end

      WRITE_BACK : begin
        mem_req_valid = 1'b1;
        mem_req_we    = 1'b1;
        mem_req_addr  = {tag_q[req_idx][victim_way], req_idx, {OFF_W{1'b0}}};  // OLD line (victim)
      end

      ALLOCATE : begin
        mem_req_valid = 1'b1;
        mem_req_addr  = {req_tag, req_idx, {OFF_W{1'b0}}};                     // NEW line
        if (mem_rsp_valid) begin
          fill_line = 1'b1;
          lru_touch = 1'b1;
          touch_way = victim_way;
        end
      end

      default : ;
    endcase
  end

  // plain data wires (not state-dependent)
  assign cpu_rsp_rdata = data_q[req_idx][hit_way][req_woff*DATA_W +: DATA_W];
  assign mem_req_wdata = data_q[req_idx][victim_way];

  //=========================================================================
  // BLOCK 4 : DATAPATH FLOPS   (obey the strobes from block 3)
  //=========================================================================
  // 4a. captured request
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_we_q    <= 1'b0;
      req_addr_q  <= '0;
      req_wdata_q <= '0;
    end
    else if (capture_req) begin
      req_we_q    <= cpu_req_we;
      req_addr_q  <= cpu_req_addr;
      req_wdata_q <= cpu_req_wdata;
    end
  end

  // 4b. valid / dirty / LRU ranks (need reset)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < NUM_SETS; s++) begin
        valid_q[s] <= '0;
        dirty_q[s] <= '0;
        for (int w = 0; w < WAYS; w++)
          age_q[s][w] <= WAY_W'(w);          // valid permutation 0..WAYS-1
      end
    end
    else begin
      if (fill_line) begin
        valid_q[req_idx][victim_way] <= 1'b1;
        dirty_q[req_idx][victim_way] <= 1'b0;
      end
      else if (set_dirty)
        dirty_q[req_idx][hit_way] <= 1'b1;

      // LRU: every way younger than the touched one ages by 1,
      //      the touched way becomes rank 0 (most recently used)
      if (lru_touch) begin
        for (int w = 0; w < WAYS; w++)
          if (age_q[req_idx][w] < age_q[req_idx][touch_way])
            age_q[req_idx][w] <= age_q[req_idx][w] + WAY_W'(1);
        age_q[req_idx][touch_way] <= '0;
      end
    end
  end

  // 4c. tag / data arrays (no reset)
  always_ff @(posedge clk) begin
    if (write_word)
      data_q[req_idx][hit_way][req_woff*DATA_W +: DATA_W] <= req_wdata_q;
    else if (fill_line) begin
      data_q[req_idx][victim_way] <= mem_rsp_rdata;
      tag_q [req_idx][victim_way] <= req_tag;
    end
  end

endmodule