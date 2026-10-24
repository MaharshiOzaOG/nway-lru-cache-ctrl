//==============================================================================
//  File    : flush_item.sv
//  Author  : Maharshi Oza  (mmoza@ncsu.edu)
//  Project : cache_ctrl UVM testbench v2.1
//------------------------------------------------------------------------------
//  WHAT    : One flush command and its result.
//              inv = 0 : write every dirty line back, keep lines cached
//              inv = 1 : write back AND invalidate every line (cache ends empty)
//
//  WHO FILLS WHAT
//    request : inv                       (sequence)
//    result  : err                       (flush_drv, from flush_err at done)
//    info    : t_start, t_done, cycles,  (flush_mon)
//              race = a CPU request was waiting when the flush started
//
//  WATCH OUT:
//    - After ANY flush (with or without invalidate) every line in memory must
//      match the reference model. The scoreboard checks this automatically
//      each time flush_mon reports a finished flush.
//==============================================================================
class flush_item extends uvm_sequence_item;

  rand bit           inv;
       bit           err;
       time          t_start;    // edge where flush_busy was first seen high
       time          t_done;     // edge of the flush_done pulse
       int unsigned  cycles;
       bit           race;       // CPU request was waiting when flush started

  `uvm_object_utils_begin(flush_item)
    `uvm_field_int(inv,     UVM_ALL_ON)
    `uvm_field_int(err,     UVM_ALL_ON)
    `uvm_field_int(t_start, UVM_ALL_ON | UVM_TIME | UVM_NOCOMPARE)
    `uvm_field_int(t_done,  UVM_ALL_ON | UVM_TIME | UVM_NOCOMPARE)
    `uvm_field_int(cycles,  UVM_ALL_ON | UVM_DEC  | UVM_NOCOMPARE)
    `uvm_field_int(race,    UVM_ALL_ON | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "flush_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("FLUSH inv=%0d err=%0d cycles=%0d race=%0d", inv, err, cycles, race);
  endfunction

endclass
