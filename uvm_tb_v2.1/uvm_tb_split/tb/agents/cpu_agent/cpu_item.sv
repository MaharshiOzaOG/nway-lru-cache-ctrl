//==============================================================================
//  File    : cpu_item.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : One CPU access (a load or a store) and, once it finishes, its
//            answer. The same object travels:
//              sequence -> cpu_drv (drives it) -> back to sequence (response)
//              cpu_mon builds its own copy from the pins -> scoreboard -> cov
//
//  FIELDS
//    request  (randomized by sequences) : we, addr, wdata, wstrb
//    id       (set by cpu_drv, NOT random): unique tag per request in flight
//    response (filled after the answer) : rdata, err, rsp_we
//    info     (filled by drv/mon/sb)     : t_accept, t_rsp, lat_cycles,
//                                          rsp_bp_cycles, outcome
//
//  CONSTRAINTS
//    - addr is word aligned (the DUT ignores the low byte bits anyway).
//    - store: at least one byte enable;  load: wstrb = 0, wdata = 0.
//
//  WATCH OUT:
//    - id is assigned by the driver so it is ALWAYS unique among requests in
//      flight. Today (blocking DUT) only one is in flight; in v2 there can be
//      up to 2^ID_W, and the monitor/scoreboard match answers by id.
//    - outcome (hit / clean miss / dirty miss) is NOT known by the CPU side.
//      The scoreboard works it out from the memory traffic and fills it in
//      before the item goes to coverage.
//==============================================================================
class cpu_item extends uvm_sequence_item;

  // ---------------- request ---------------------------------------------------
  rand bit             we;        // 1 = store, 0 = load
  rand addr_t          addr;      // byte address (word aligned)
  rand data_t          wdata;     // store data
  rand strb_t          wstrb;     // store byte enables
       id_t            id;        // assigned by cpu_drv

  // ---------------- response --------------------------------------------------
       data_t          rdata;     // load data (DUT returns 0 for stores)
       bit             err;       // memory error during this access
       bit             rsp_we;    // DUT echo of we

  // ---------------- info (not driven) -------------------------------------
       time            t_accept;       // time of the request handshake edge
       time            t_rsp;          // time of the response handshake edge
       int unsigned    lat_cycles;     // accept -> response, in cycles
       int unsigned    rsp_bp_cycles;  // cycles rsp_valid waited for rsp_ready
       outcome_e       outcome;        // filled by the scoreboard

  constraint c_align { addr[BYTE_W-1:0] == '0; }
  constraint c_strb  { we  -> (wstrb != '0);
                       !we -> (wstrb == '0 && wdata == '0); }

  `uvm_object_utils_begin(cpu_item)
    `uvm_field_int (we,            UVM_ALL_ON)
    `uvm_field_int (addr,          UVM_ALL_ON | UVM_HEX)
    `uvm_field_int (wdata,         UVM_ALL_ON | UVM_HEX)
    `uvm_field_int (wstrb,         UVM_ALL_ON | UVM_BIN)
    `uvm_field_int (id,            UVM_ALL_ON)
    `uvm_field_int (rdata,         UVM_ALL_ON | UVM_HEX)
    `uvm_field_int (err,           UVM_ALL_ON)
    `uvm_field_int (rsp_we,        UVM_ALL_ON)
    `uvm_field_int (t_accept,      UVM_ALL_ON | UVM_TIME | UVM_NOCOMPARE)
    `uvm_field_int (t_rsp,         UVM_ALL_ON | UVM_TIME | UVM_NOCOMPARE)
    `uvm_field_int (lat_cycles,    UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int (rsp_bp_cycles, UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_enum(outcome_e, outcome, UVM_ALL_ON | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "cpu_item");
    super.new(name);
  endfunction

  // One-line summary, used in log messages.
  function string convert2string();
    if (we)
      return $sformatf("ST id=%0d addr=%h wdata=%h wstrb=%b err=%0d",
                       id, addr, wdata, wstrb, err);
    return $sformatf("LD id=%0d addr=%h rdata=%h err=%0d", id, addr, rdata, err);
  endfunction

endclass
