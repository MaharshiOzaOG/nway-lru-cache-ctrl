//==============================================================================
//  File    : flush_seqr.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Standard sequencer for flush_item. Nothing special.
//==============================================================================
class flush_seqr extends uvm_sequencer #(flush_item);

  `uvm_component_utils(flush_seqr)

  cache_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass
