//==============================================================================
//  File    : mem_item.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : One memory transaction = one WHOLE cache line.
//              we = 1 : writeback (the cache pushes a dirty line out)
//              we = 0 : refill    (the cache asks for a missing line)
//
//  WHO FILLS WHAT
//    request  (copied from the DUT pins by mem_mon) : we, addr, wdata
//    response (chosen by mem_resp_seq)              : rdata, err, latency
//    info     (measured by mem_mon)                 : t_req, t_rsp,
//                                                     req_bp_cycles, lat_cycles
//
//  WHY THIS IS DIFFERENT:
//    In a normal (active) agent the SEQUENCE invents the request. Here the DUT
//    makes the request and the sequence only decides the ANSWER. So the same
//    class carries "what the DUT asked" plus "how memory replies".
//
//  WATCH OUT:
//    - latency is in clock cycles, counted from the cycle after the request
//      handshake. It models DRAM access time + the beats of a burst.
//    - On an error the response data is junk on purpose (0xBAD...), and for a
//      write nothing is stored in mem_model.
//==============================================================================
class mem_item extends uvm_sequence_item;

  // ---------------- request (from the DUT) ----------------------------------
       bit           we;
       addr_t        addr;          // line aligned
       line_t        wdata;         // full line (writeback only)

  // ---------------- response (from mem_resp_seq) ---------------------------
       line_t        rdata;         // full line (refill only)
  rand bit           err;
  rand int unsigned  latency;       // extra cycles before the response

  // ---------------- info (from mem_mon) -------------------------------------
       time          t_req;         // time of the request handshake edge
       time          t_rsp;         // time of the response handshake edge
       int unsigned  req_bp_cycles; // cycles the DUT waited for mem_req_ready
       int unsigned  lat_cycles;    // request -> response, in cycles

  constraint c_lat { latency <= 64; }

  `uvm_object_utils_begin(mem_item)
    `uvm_field_int(we,            UVM_ALL_ON)
    `uvm_field_int(addr,          UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(wdata,         UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(rdata,         UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(err,           UVM_ALL_ON)
    `uvm_field_int(latency,       UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(t_req,         UVM_ALL_ON | UVM_TIME | UVM_NOCOMPARE)
    `uvm_field_int(t_rsp,         UVM_ALL_ON | UVM_TIME | UVM_NOCOMPARE)
    `uvm_field_int(req_bp_cycles, UVM_ALL_ON | UVM_DEC  | UVM_NOCOMPARE)
    `uvm_field_int(lat_cycles,    UVM_ALL_ON | UVM_DEC  | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "mem_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("%s addr=%h err=%0d lat=%0d",
                     we ? "WRITEBACK" : "REFILL", addr, err, lat_cycles);
  endfunction

endclass
