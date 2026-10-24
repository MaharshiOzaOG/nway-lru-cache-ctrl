//==============================================================================
//  File    : mem_agent.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Container for main memory: mem_seqr + mem_drv + mem_mon.
//            (mem_model is shared through cache_cfg; mem_resp_seq is started
//             on this agent's sequencer by the base test.)
//
//  CONNECTIONS MADE HERE
//    drv.seq_item_port -> seqr.seq_item_export          (standard)
//    mon.req_ap        -> seqr.dut_req_fifo.analysis_export (reactive: requests
//                                                         reach the responder)
//
//  WATCH OUT:
//    - This is an ACTIVE agent even though it never starts traffic: it drives
//      ready/response pins. "Reactive" describes the sequence, not the agent.
//==============================================================================
class mem_agent extends uvm_agent;

  `uvm_component_utils(mem_agent)

  mem_seqr   seqr;
  mem_drv    drv;
  mem_mon    mon;
  cache_cfg  cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("MEM_AGT", "no cache_cfg in config_db")
    seqr = mem_seqr::type_id::create("seqr", this);
    drv  = mem_drv::type_id::create("drv", this);
    mon  = mem_mon::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(seqr.seq_item_export);
    mon.req_ap.connect(seqr.dut_req_fifo.analysis_export);
    seqr.cfg = cfg;
  endfunction

endclass
