//==============================================================================
//  File    : flush_agent.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Container for flush_seqr + flush_drv + flush_mon.
//
//  WHY A SEPARATE AGENT (and not a FLUSH kind of cpu_item):
//    - A flush can then be started while cpu_drv is still holding a request,
//      so the "flush vs waiting CPU request" race really gets tested.
//    - cpu_item stays clean (no fields that mean nothing for a flush).
//    OTHER WAY: one CPU agent with item.kind = LOAD/STORE/FLUSH. Fewer files,
//    but one driver can never overlap a flush with a waiting request.
//
//  WATCH OUT:
//    - It shares cache_cpu_if with the CPU agent (the flush pins are part of
//      the CPU interface). Its driver only uses vif.flush_cb.
//==============================================================================
class flush_agent extends uvm_agent;

  `uvm_component_utils(flush_agent)

  flush_seqr  seqr;
  flush_drv   drv;
  flush_mon   mon;
  cache_cfg   cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("FLUSH_AGT", "no cache_cfg in config_db")
    seqr = flush_seqr::type_id::create("seqr", this);
    drv  = flush_drv::type_id::create("drv", this);
    mon  = flush_mon::type_id::create("mon", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(seqr.seq_item_export);
    seqr.cfg = cfg;
  endfunction

endclass
