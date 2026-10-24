//==============================================================================
//  File    : mem_model.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : The CONTENTS of main memory (the "DRAM"). Just storage, no timing.
//            Timing (latency, backpressure) is mem_drv's job.
//
//  STORAGE : sparse byte array   mem[byte address] = byte
//            A byte that was never written returns init_byte(addr)
//            (same function the reference model uses, see cache_tb_defs).
//
//  USED BY
//    mem_resp_seq     : read_line() for refills, write_line() for writebacks
//    cache_scoreboard : backdoor peek of every byte after a flush, to compare
//                       memory against the reference model
//
//  WHY A uvm_object AND NOT INSIDE THE AGENT:
//    The scoreboard (in the env) must read it too. One shared object, handed
//    out through cache_cfg, means both see the same memory.
//    OTHER WAY: keep it inside mem_agent and give the scoreboard a handle via
//    the env. Same thing, a bit more wiring.
//==============================================================================
class mem_model extends uvm_object;

  `uvm_object_utils(mem_model)

  // Only bytes that were written are stored.
  byte unsigned mem [addr_t];

  function new(string name = "mem_model");
    super.new(name);
  endfunction

  function byte unsigned read_byte(addr_t a);
    return mem.exists(a) ? mem[a] : init_byte(a);
  endfunction

  function void write_byte(addr_t a, byte unsigned b);
    mem[a] = b;
  endfunction

  // Whole line. Byte i of the line sits in bits [8*i +: 8] (same as the DUT).
  function line_t read_line(addr_t line_addr);
    line_t l;
    for (int i = 0; i < DUT_LINE_BYTES; i++)
      l[8*i +: 8] = read_byte(line_addr + i);
    return l;
  endfunction

  function void write_line(addr_t line_addr, line_t l);
    for (int i = 0; i < DUT_LINE_BYTES; i++)
      write_byte(line_addr + i, l[8*i +: 8]);
  endfunction

endclass
