//==============================================================================
//  File    : cache_ref_model.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : The PREDICTOR. Holds what memory SHOULD contain if the cache is
//            correct. A correct cache is invisible to the CPU, so this model
//            knows nothing about sets, ways, hits or dirty bits: it is just a
//            flat byte memory that applies every successful store.
//
//  EACH BYTE IS IN ONE OF THREE STATES
//    untouched : nobody stored it      -> expected value = init_byte(addr)
//    known     : a store wrote it      -> expected value = ref_mem[addr]
//    unknown   : a WRITEBACK FAILED for its line, so memory may be stale and
//                the cache may have dropped the newest data. We cannot predict
//                it any more, so every check skips it (until a store writes it
//                again, which makes it known again).
//
//  API (called by cache_scoreboard)
//    apply_store(addr, wdata, wstrb)      store completed successfully
//    expected_word(addr, data, mask)      what a load should return; mask bit i
//                                         = 1 if byte i is predictable
//    mark_line_unknown(line_addr)         a writeback of this line failed
//    expected_byte(addr, val)             for the memory compare after a flush
//
//  WHY SEPARATE FROM THE SCOREBOARD (predictor / comparator split):
//    The scoreboard decides WHEN to check and reports; this class only answers
//    "what is the right value". Later you can swap in a richer predictor (e.g.
//    one that also models hit/miss and LRU) without touching the comparator.
//    OTHER WAY: one class doing both. Simpler at first, harder to grow.
//==============================================================================
class cache_ref_model extends uvm_object;

  `uvm_object_utils(cache_ref_model)

  byte unsigned ref_mem [addr_t];   // known bytes
  bit           unknown [addr_t];   // bytes we can no longer predict

  function new(string name = "cache_ref_model");
    super.new(name);
  endfunction

  // A store finished and really happened in the cache.
  function void apply_store(addr_t addr, data_t wdata, strb_t wstrb);
    for (int i = 0; i < STRB_W; i++) begin
      if (wstrb[i]) begin
        ref_mem[addr + i] = wdata[8*i +: 8];
        if (unknown.exists(addr + i)) unknown.delete(addr + i);
      end
    end
  endfunction

  // Expected value of one byte. Returns 0 if it is unknown (do not check).
  function bit expected_byte(addr_t a, output byte unsigned val);
    if (unknown.exists(a)) begin
      val = 8'h00;
      return 1'b0;
    end
    val = ref_mem.exists(a) ? ref_mem[a] : init_byte(a);
    return 1'b1;
  endfunction

  // Expected value of a whole word; mask[i] = 1 means byte i can be checked.
  function void expected_word(addr_t addr, output data_t data, output strb_t mask);
    byte unsigned b;
    data = '0;
    mask = '0;
    for (int i = 0; i < STRB_W; i++) begin
      mask[i]         = expected_byte(addr + i, b);
      data[8*i +: 8]  = b;
    end
  endfunction

  // A writeback of this line failed: its newest data may be lost.
  function void mark_line_unknown(addr_t line_addr);
    for (int i = 0; i < DUT_LINE_BYTES; i++)
      unknown[line_addr + i] = 1'b1;
  endfunction

  function int unsigned num_unknown();
    return unknown.num();
  endfunction

endclass
