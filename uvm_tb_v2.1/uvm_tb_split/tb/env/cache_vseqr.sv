//==============================================================================
//  File    : cache_vseqr.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : Virtual sequencer. It drives no pins and has no items; it only
//            holds HANDLES so one virtual sequence can coordinate everything:
//              cpu_sqr   -> start CPU sequences
//              flush_sqr -> start flushes
//              mem_sqr   -> (not used by scenarios; the responder runs alone)
//              cfg       -> change knobs between scenarios
//              sb        -> read scoreboard counters (directed checks)
//            cache_env fills these handles in connect_phase.
//
//  OTHER WAY: virtual sequences that find sequencers through config_db or
//  through the test's handles. The virtual-sequencer way is the common one.
//==============================================================================
class cache_vseqr extends uvm_sequencer;

  `uvm_component_utils(cache_vseqr)

  cpu_seqr          cpu_sqr;
  flush_seqr        flush_sqr;
  mem_seqr          mem_sqr;
  cache_cfg         cfg;
  cache_scoreboard  sb;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

endclass
