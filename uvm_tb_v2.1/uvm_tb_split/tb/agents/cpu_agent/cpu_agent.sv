//==============================================================================
//  File    : cpu_agent.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Container for the CPU side: cpu_seqr + cpu_drv + cpu_mon.
//            Builds them and connects  driver.seq_item_port -> sequencer.
//            The monitor's ports are connected one level up, in cache_env.
//
//  WATCH OUT:
//    - Always ACTIVE here (it plays the CPU). Standard pattern otherwise.
//==============================================================================
class cpu_agent extends uvm_agent;

  `uvm_component_utils(cpu_agent)

  cpu_seqr   seqr;
  cpu_drv    drv;
  cpu_mon    mon;
  cache_cfg  cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(cache_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CPU_AGT", "no cache_cfg in config_db")
    seqr = cpu_seqr::type_id::create("seqr", this);
    drv  = cpu_drv::type_id::create("drv",  this);
    mon  = cpu_mon::type_id::create("mon",  this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(seqr.seq_item_export);
    seqr.cfg = cfg;
  endfunction

endclass
