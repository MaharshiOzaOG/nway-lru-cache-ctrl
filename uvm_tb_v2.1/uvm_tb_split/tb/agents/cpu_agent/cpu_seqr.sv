//==============================================================================
//  File    : cpu_seqr.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Standard sequencer for cpu_item. Passes items from CPU sequences
//            to cpu_drv, and passes responses back.
//            Holds a cfg handle so sequences can read the knobs
//            (p_sequencer.cfg).
//
//  WATCH OUT:
//    - Every response the driver put()s lands in this sequencer's response
//      queue. A sequence MUST collect it (get_response), or the queue fills up
//      and UVM reports an overflow error. cpu_base_seq::do_op() does this for
//      you. (v2 will switch to a response handler instead.)
//==============================================================================
class cpu_seqr extends uvm_sequencer #(cpu_item);

  `uvm_component_utils(cpu_seqr)

  cache_cfg cfg;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass
