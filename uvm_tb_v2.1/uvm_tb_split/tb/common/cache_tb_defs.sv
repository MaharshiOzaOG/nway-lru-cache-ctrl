`timescale 1ns/1ps
//==============================================================================
//  File    : cache_tb_defs.sv            (package cache_tb_defs_pkg)
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Every constant and small helper the whole testbench shares.
//            DUT shape (widths, sets, ways), derived widths, the clock period,
//            the "what memory holds before anyone writes it" pattern, and an
//            address builder.
//
//  WHY A SEPARATE PACKAGE (not inside cache_tb_pkg):
//            The interfaces and tb_top need these numbers too, and they must
//            NOT import the UVM package. So the plain numbers live here, with
//            no UVM, and cache_tb_pkg imports this package.
//
//  WATCH OUT:
//    - To test another cache shape, change the DUT_* values HERE. tb_top passes
//      them to the DUT, so DUT and TB can never disagree.
//    - The interfaces are NOT parameterized on purpose (they use these
//      constants). Parameterized virtual interfaces are painful in UVM
//      (every class that holds one must carry the parameters too).
//    - init_byte() is used by BOTH mem_model (what memory returns) and
//      cache_ref_model (what the CPU should read). They must agree, which is
//      why it is defined once, here.
//==============================================================================
package cache_tb_defs_pkg;

  // ---------------- DUT shape (must match what tb_top passes to cache_ctrl) --
  localparam int unsigned DUT_ADDR_W     = 32;
  localparam int unsigned DUT_DATA_W     = 32;
  localparam int unsigned DUT_LINE_BYTES = 16;
  localparam int unsigned DUT_NUM_SETS   = 64;
  localparam int unsigned DUT_N_WAYS     = 4;
  localparam int unsigned DUT_ID_W       = 4;

  // ---------------- short names used everywhere in the TB ------------------
  localparam int unsigned ADDR_W   = DUT_ADDR_W;
  localparam int unsigned DATA_W   = DUT_DATA_W;
  localparam int unsigned ID_W     = DUT_ID_W;
  localparam int unsigned STRB_W   = DATA_W / 8;                 // bytes per word
  localparam int unsigned LINE_W   = DUT_LINE_BYTES * 8;         // bits per line
  localparam int unsigned WPL      = DUT_LINE_BYTES / STRB_W;    // words per line
  localparam int unsigned BYTE_W   = $clog2(STRB_W);             // byte-in-word bits
  localparam int unsigned OFF_W    = $clog2(DUT_LINE_BYTES);     // byte-in-line bits
  localparam int unsigned SET_W    = $clog2(DUT_NUM_SETS);       // set index bits

  // ---------------- clock ----------------------------------------------------
  // Used by tb_top to make the clock, and by the TB to turn time into cycles.
  // Every file is compiled under `timescale 1ns/1ps, so "10ns" means the same
  // thing everywhere.
  localparam time CLK_PERIOD = 10ns;

  // ---------------- types ----------------------------------------------------
  typedef bit [ADDR_W-1:0]  addr_t;
  typedef bit [DATA_W-1:0]  data_t;
  typedef bit [STRB_W-1:0]  strb_t;
  typedef bit [LINE_W-1:0]  line_t;
  typedef bit [ID_W-1:0]    id_t;

  // How the scoreboard classifies a CPU access (from the memory traffic it saw)
  typedef enum {OUT_HIT, OUT_CLEAN_MISS, OUT_DIRTY_MISS} outcome_e;

  // ---------------- helpers --------------------------------------------------

  // What main memory holds at a byte address that nobody has written yet.
  // Any fixed function works; this one gives different bytes for nearby
  // addresses so a wrong-word bug shows up as wrong data.
  function automatic byte unsigned init_byte(addr_t a);
    return byte'(a[7:0] ^ a[15:8] ^ a[23:16] ^ a[31:24] ^ 8'h5A) + byte'(a[3:0]);
  endfunction

  // Build a byte address from (tag, set, word).  Same layout as the DUT:
  //   [ tag | set (SET_W) | word (OFF_W-BYTE_W) | byte (BYTE_W) ]
  function automatic addr_t mk_addr(int unsigned tag, int unsigned set, int unsigned word = 0);
    addr_t a;
    a = (addr_t'(tag) << (SET_W + OFF_W))
      | (addr_t'(set % DUT_NUM_SETS) << OFF_W)
      | (addr_t'(word % WPL) << BYTE_W);
    return a;
  endfunction

  // Line-aligned base address of any byte address.
  function automatic addr_t line_base(addr_t a);
    return a & ~addr_t'(DUT_LINE_BYTES - 1);
  endfunction

  // "_<RUN_ID>" if +RUN_ID=<tag> was given, else "".  Used in the names of the
  // per-run result files (summary_*.txt, cov_*.csv) so repeated runs of the
  // same test do not overwrite each other.
  function automatic string run_suffix();
    string id;
    if ($value$plusargs("RUN_ID=%s", id)) return {"_", id};
    return "";
  endfunction

endpackage
