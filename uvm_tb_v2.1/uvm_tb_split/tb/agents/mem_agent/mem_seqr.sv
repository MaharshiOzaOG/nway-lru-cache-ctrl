//==============================================================================
//  File    : mem_seqr.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Sequencer for the memory responder, PLUS a FIFO of the requests
//            the DUT has made and that still need an answer.
//
//              mem_mon.req_ap --> dut_req_fifo (here) --> mem_resp_seq.get()
//
//  WHY THIS IS DIFFERENT (the "reactive slave" pattern)
//    A normal sequence decides on its own what to send. A memory cannot: it
//    must WAIT for the DUT to ask. So the monitor pushes every accepted DUT
//    request into this FIFO, and the responder sequence blocks on
//    dut_req_fifo.get() until there is something to answer.
//    uvm_tlm_analysis_fifo = an analysis "export" on one side (the monitor
//    write()s into it, never blocks) and a blocking get() on the other side.
//
//    OTHER WAYS you may see:
//      - a uvm_event + shared queue between monitor and sequence;
//      - the driver itself waits for the request on the pins and calls back
//        into the sequence (more coupling, harder to reuse).
//    The FIFO version is the textbook-standard one for reactive agents.
//
//  WATCH OUT (bug found on first run):
//    Do NOT name this FIFO "req_fifo". uvm_sequencer already creates a child
//    component called "req_fifo" internally (its own m_req_fifo), and two
//    children with the same name -> UVM_FATAL [CLDEXT] at time 0.
//==============================================================================
class mem_seqr extends uvm_sequencer #(mem_item);

  `uvm_component_utils(mem_seqr)

  uvm_tlm_analysis_fifo #(mem_item) dut_req_fifo;
  cache_cfg                         cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    dut_req_fifo = new("dut_req_fifo", this);
  endfunction

endclass
